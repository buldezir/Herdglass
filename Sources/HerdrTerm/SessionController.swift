import AppKit
import Foundation
import HerdrClient
import UserNotifications

@MainActor
protocol SessionControllerDelegate: AnyObject {
    func sessionDidUpdate(_ session: SessionController)
    func sessionDidFail(_ session: SessionController, error: Error)
}

@MainActor
final class SessionController {
    enum State: Equatable {
        case disconnected
        case connecting(String)
        case connected(String)
        case reconnecting(String)
        case failed(String)

        var summary: String {
            switch self {
            case .disconnected: return "Not connected"
            case .connecting(let target): return "Connecting to \(target)…"
            case .connected(let target): return target
            case .reconnecting(let target): return "Reconnecting to \(target)…"
            case .failed(let message): return message
            }
        }

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    weak var delegate: SessionControllerDelegate?

    private(set) var target: ConnectTarget?
    private(set) var snapshot: SessionSnapshot?
    private(set) var selectedPaneId: String?
    private(set) var state: State = .disconnected
    private(set) var unreadPaneIds: Set<String> = []
    private(set) var socketPath: String?

    private var attentionOrder: [String] = []
    private var connection: RemoteConnection?
    private var rpc: HerdrRPC?
    private var events: EventSubscription?
    private var pollTimer: Timer?
    private static let reconnectInterval: TimeInterval = 2
    /// Backstop behind the event stream.
    private static let backgroundPollInterval: TimeInterval = 2
    /// Sole source of updates when the server will not subscribe us.
    private static let eventlessPollInterval: TimeInterval = 0.9
    private var retryTimer: Timer?
    private var lastReconnect: Date = .distantPast
    private var connectGeneration = 0
    /// Held here rather than captured by the worker closure: a UI callback is
    /// not `Sendable` and must not cross to a background queue.
    private var pendingConnect: ((Error?) -> Void)?

    let herdrBinary = HerdrPaths.localHerdrBinary()

    var hasAttention: Bool { !unreadPaneIds.isEmpty }

    // MARK: - Connection

    func connect(_ target: ConnectTarget, completion: ((Error?) -> Void)? = nil) {
        disconnect()
        self.target = target
        state = .connecting(target.displayName)
        delegate?.sessionDidUpdate(self)

        connectGeneration += 1
        let generation = connectGeneration
        let binary = herdrBinary
        pendingConnect = completion

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome: Result<(RemoteConnection, HerdrRPC, SessionSnapshot), Error>
            do {
                let connection = try RemoteConnection(target: target, herdrBinary: binary)
                try connection.open()
                let rpc = HerdrRPC(socketPath: connection.localSocketPath)
                outcome = .success((connection, rpc, try rpc.snapshot()))
            } catch {
                outcome = .failure(error)
            }
            DispatchQueue.main.async {
                guard let self, generation == self.connectGeneration else {
                    // A newer connect (or a disconnect) superseded this one.
                    if case .success(let (connection, _, _)) = outcome { connection.close() }
                    return
                }
                let reportOutcome = self.pendingConnect
                self.pendingConnect = nil
                switch outcome {
                case .success(let (connection, rpc, snapshot)):
                    self.finishConnect(connection: connection, rpc: rpc, snapshot: snapshot)
                    reportOutcome?(nil)
                case .failure(let error):
                    self.state = .failed(error.localizedDescription)
                    self.delegate?.sessionDidUpdate(self)
                    if reportOutcome == nil {
                        // Nobody is showing a sheet to put this error in.
                        self.delegate?.sessionDidFail(self, error: error)
                    }
                    reportOutcome?(error)
                }
            }
        }
    }

    func disconnect() {
        connectGeneration += 1
        retryTimer?.invalidate()
        retryTimer = nil
        pollTimer?.invalidate()
        pollTimer = nil
        events?.cancel()
        events = nil
        rpc = nil
        connection?.close()
        connection = nil
        snapshot = nil
        selectedPaneId = nil
        socketPath = nil
        unreadPaneIds = []
        attentionOrder = []
        state = .disconnected
    }

    func reconnect() {
        guard let target else { return }
        // Snapshot failures arrive in bursts; one attempt every couple of
        // seconds is enough to recover without hammering SSH. Defer rather than
        // drop the attempt, or a burst can leave the session stuck offline.
        let sinceLast = Date().timeIntervalSince(lastReconnect)
        guard sinceLast > Self.reconnectInterval else {
            scheduleReconnect(after: Self.reconnectInterval - sinceLast)
            return
        }
        lastReconnect = Date()
        retryTimer?.invalidate()
        retryTimer = nil
        connect(target)
    }

    private func scheduleReconnect(after delay: TimeInterval) {
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: max(delay, 0.1), repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.retryTimer = nil
                self?.reconnect()
            }
        }
    }

    // MARK: - Selection

    func selectWorkspace(_ workspaceId: String) {
        guard let snapshot else { return }
        let candidates = snapshot.panes.filter { $0.workspaceId == workspaceId }
        // Prefer something that wants attention, then the server's focus.
        let pane = candidates.first { unreadPaneIds.contains($0.paneId) }
            ?? candidates.first { $0.focused }
            ?? candidates.first
        if let pane { selectPane(pane.paneId) }
    }

    func selectPane(_ paneId: String) {
        selectedPaneId = paneId
        markRead(paneId)
        DispatchQueue.global(qos: .userInitiated).async { [rpc] in
            try? rpc?.focusPane(paneId)
        }
        delegate?.sessionDidUpdate(self)
    }

    /// Most recent pane that asked for attention, oldest-first as a fallback.
    @discardableResult
    func jumpToAttention() -> String? {
        guard let paneId = attentionOrder.last ?? unreadPaneIds.first else { return nil }
        selectPane(paneId)
        return paneId
    }

    // MARK: - Derived state

    func panes(in workspaceId: String) -> [PaneInfo] {
        snapshot?.panes.filter { $0.workspaceId == workspaceId } ?? []
    }

    var selectedPane: PaneInfo? {
        guard let selectedPaneId else { return nil }
        return snapshot?.panes.first { $0.paneId == selectedPaneId }
    }

    /// Workspace rows surface the loudest child state, so a blocked pane stays
    /// visible even while its workspace is collapsed.
    func effectiveStatus(of workspace: WorkspaceInfo) -> AgentStatus {
        let panes = panes(in: workspace.workspaceId)
        if panes.contains(where: { $0.agentStatus == .blocked }) { return .blocked }
        if panes.contains(where: { $0.agentStatus == .done && unreadPaneIds.contains($0.paneId) }) { return .done }
        if workspace.agentStatus != .unknown { return workspace.agentStatus }
        if panes.contains(where: { $0.agentStatus == .working }) { return .working }
        return workspace.agentStatus
    }

    func isUnread(paneId: String) -> Bool { unreadPaneIds.contains(paneId) }

    func isUnread(workspaceId: String) -> Bool {
        panes(in: workspaceId).contains { unreadPaneIds.contains($0.paneId) }
    }

    // MARK: - Internals

    private func finishConnect(connection: RemoteConnection, rpc: HerdrRPC, snapshot: SessionSnapshot) {
        self.connection = connection
        self.rpc = rpc
        socketPath = connection.localSocketPath
        state = .connected(connection.target.displayName)
        RecentsStore.remember(connection.target)
        applySnapshot(snapshot, isInitial: true)
        startEventWatch(rpc)
        delegate?.sessionDidUpdate(self)
    }

    /// Events drive the UI, but they cannot carry everything:
    /// `pane.agent_status_changed` is a pane-scoped subscription, so a
    /// session-wide client cannot ask for it. A slow poll backs the stream up so
    /// an agent going `blocked` can never go unnoticed — and so a server that
    /// refuses `events.subscribe` still works, just less promptly.
    private func startEventWatch(_ rpc: HerdrRPC) {
        var pollInterval = Self.backgroundPollInterval
        do {
            events = try rpc.subscribe { [weak self] in
                DispatchQueue.main.async { self?.refreshSnapshot() }
            }
        } catch {
            pollInterval = Self.eventlessPollInterval
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSnapshot() }
        }
    }

    private func refreshSnapshot() {
        guard let rpc else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try rpc.snapshot() }
            DispatchQueue.main.async {
                guard let self, self.rpc === rpc else { return }
                switch result {
                case .success(let snapshot):
                    // A poll that lands is also how we learn a wobble is over.
                    if !self.state.isConnected, let target = self.target {
                        self.state = .connected(target.displayName)
                    }
                    self.applySnapshot(snapshot, isInitial: false)
                case .failure:
                    self.state = .reconnecting(self.target?.displayName ?? "")
                    self.delegate?.sessionDidUpdate(self)
                    self.reconnect()
                }
            }
        }
    }

    private func applySnapshot(_ snapshot: SessionSnapshot, isInitial: Bool) {
        let previousStatus = Dictionary(
            (self.snapshot?.panes ?? []).map { ($0.paneId, $0.agentStatus) },
            uniquingKeysWith: { first, _ in first }
        )
        self.snapshot = snapshot

        let liveIds = Set(snapshot.panes.map(\.paneId))
        if selectedPaneId == nil || !liveIds.contains(selectedPaneId!) {
            selectedPaneId = snapshot.focusedPaneId ?? snapshot.panes.first?.paneId
        }

        for pane in snapshot.panes {
            guard pane.agentStatus.needsAttention, pane.paneId != selectedPaneId else {
                markRead(pane.paneId)
                continue
            }
            if unreadPaneIds.insert(pane.paneId).inserted {
                attentionOrder.append(pane.paneId)
            }
            if !isInitial, pane.agentStatus == .blocked, previousStatus[pane.paneId] != .blocked {
                notifyBlocked(pane)
            }
        }

        // Panes can disappear while unread; keep both trackers to live ids only
        // or `jumpToAttention` starts selecting panes that no longer exist.
        unreadPaneIds.formIntersection(liveIds)
        attentionOrder.removeAll { !unreadPaneIds.contains($0) }
        delegate?.sessionDidUpdate(self)
    }

    private func markRead(_ paneId: String) {
        unreadPaneIds.remove(paneId)
        attentionOrder.removeAll { $0 == paneId }
    }

    private func notifyBlocked(_ pane: PaneInfo) {
        guard !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = pane.displayName
        content.subtitle = target?.displayName ?? ""
        content.body = "Waiting for input"
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "blocked-\(pane.paneId)", content: content, trigger: nil)
        )
    }
}
