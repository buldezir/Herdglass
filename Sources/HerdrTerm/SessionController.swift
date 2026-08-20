import AppKit
import Foundation
import HerdrClient
import UserNotifications

@MainActor
protocol SessionControllerDelegate: AnyObject {
    func sessionDidUpdate(_ session: SessionController)
    func sessionDidFail(_ session: SessionController, error: Error)
}

/// One connection to one Herdr server, and the selection inside it: which space
/// (Herdr workspace), which tab, and which pane of that tab has the keyboard.
///
/// A window can hold several of these; `ConnectionsController` owns them.
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

        var isBusy: Bool {
            switch self {
            case .connecting, .reconnecting: return true
            default: return false
            }
        }
    }

    weak var delegate: SessionControllerDelegate?

    private(set) var target: ConnectTarget?
    private(set) var snapshot: SessionSnapshot?
    private(set) var selectedWorkspaceId: String?
    private(set) var selectedTabId: String?
    private(set) var selectedPaneId: String?
    private(set) var state: State = .disconnected
    private(set) var unreadPaneIds: Set<String> = []
    private(set) var socketPath: String?
    /// Split tree of the selected tab. Only one tab is on screen at a time, so
    /// only one tree is ever fetched.
    private(set) var layout: LayoutTree?

    /// Whether this connection is the one the window is showing. A pane the user
    /// can actually see is a pane that has been read.
    var isVisible = false {
        didSet {
            guard isVisible != oldValue else { return }
            guard isVisible else { return }
            markVisiblePanesRead()
            // The tree is only fetched for the host on screen, so becoming the
            // visible one is when this host needs its own.
            refreshLayoutIfNeeded()
        }
    }

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
    /// Which layout the cached tree belongs to, so it is re-fetched when the
    /// snapshot says the tab's splits or ratios moved and not on every poll.
    private var layoutKey: String?
    private var layoutFetchKey: String?
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
        selectedWorkspaceId = nil
        selectedTabId = nil
        selectedPaneId = nil
        socketPath = nil
        layout = nil
        layoutKey = nil
        layoutFetchKey = nil
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

    /// Pick a space. Prefers a tab that wants attention over the one Herdr has
    /// focused, so ⌘-jumping into a space lands on the thing that is asking.
    func selectSpace(_ workspaceId: String) {
        guard let snapshot else { return }
        selectedWorkspaceId = workspaceId
        let tabs = snapshot.tabs(in: workspaceId)
        let tab = tabs.first { tabWantsAttention($0.tabId) }
            ?? tabs.first { $0.tabId == snapshot.workspace(workspaceId)?.activeTabId }
            ?? tabs.first { $0.focused }
            ?? tabs.first
        if let tab {
            selectTab(tab.tabId)
        } else {
            selectedTabId = nil
            selectedPaneId = nil
            layout = nil
            focusRemoteWorkspace(workspaceId)
            delegate?.sessionDidUpdate(self)
        }
    }

    func selectTab(_ tabId: String) {
        guard let snapshot, let tab = snapshot.tab(tabId) else { return }
        selectedWorkspaceId = tab.workspaceId
        if selectedTabId != tabId {
            selectedTabId = tabId
            // A tree belonging to the tab we just left must not be drawn for
            // the new one, not even for the frame before the fetch lands.
            layout = nil
            layoutKey = nil
        }
        let panes = snapshot.panes(in: tabId)
        let pane = panes.first { unreadPaneIds.contains($0.paneId) }
            ?? panes.first { $0.focused }
            ?? panes.first
        if let pane {
            selectPane(pane.paneId)
        } else {
            selectedPaneId = nil
            focusRemoteTab(tabId)
            refreshLayoutIfNeeded()
            delegate?.sessionDidUpdate(self)
        }
    }

    /// Pick a pane. Also settles which tab and space are selected, so clicking
    /// a pane inside a split never leaves the sidebar pointing somewhere else.
    func selectPane(_ paneId: String) {
        guard let pane = snapshot?.pane(paneId) else { return }
        if selectedTabId != pane.tabId {
            selectedTabId = pane.tabId
            layout = nil
            layoutKey = nil
        }
        selectedWorkspaceId = pane.workspaceId
        selectedPaneId = paneId
        markVisiblePanesRead()
        focusRemotePane(paneId)
        refreshLayoutIfNeeded()
        delegate?.sessionDidUpdate(self)
    }

    /// Most recent pane that asked for attention, oldest-first as a fallback.
    @discardableResult
    func jumpToAttention() -> String? {
        guard let paneId = attentionOrder.last ?? unreadPaneIds.first else { return nil }
        selectPane(paneId)
        return paneId
    }

    // MARK: - Actions on the server

    func splitSelectedPane(_ direction: SplitDirection) {
        guard let paneId = selectedPaneId, let rpc else { return }
        perform { _ = try rpc.splitPane(paneId, direction: direction, focus: true) }
    }

    /// Herdr decides which pane lies in a direction — it owns the geometry.
    func focusNeighbour(_ direction: PaneDirection) {
        guard let paneId = selectedPaneId, let rpc else { return }
        perform { try rpc.focusPane(from: paneId, direction: direction) }
    }

    func newTab() {
        guard let workspaceId = selectedWorkspaceId, let rpc else { return }
        perform { _ = try rpc.createTab(workspaceId: workspaceId, focus: true) }
    }

    func closeTab(_ tabId: String) {
        guard let rpc else { return }
        perform { try rpc.closeTab(tabId) }
    }

    func newSpace() {
        guard let rpc else { return }
        perform { _ = try rpc.createWorkspace() }
    }

    /// A divider the user dragged. Pushed to the server rather than kept locally
    /// so the TUI and any other client see the same layout.
    func setSplitRatio(path: [Bool], ratio: Double) {
        guard let tabId = selectedTabId, let rpc else { return }
        perform { try rpc.setSplitRatio(tabId: tabId, path: path, ratio: ratio) }
    }

    /// Fire-and-forget request off the main thread, followed by a snapshot so
    /// the UI reflects it without waiting for the next poll.
    private func perform(_ body: @escaping @Sendable () throws -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            try? body()
            DispatchQueue.main.async { self?.refreshSnapshot() }
        }
    }

    private func focusRemotePane(_ paneId: String) {
        guard let rpc else { return }
        DispatchQueue.global(qos: .userInitiated).async { try? rpc.focusPane(paneId) }
    }

    private func focusRemoteTab(_ tabId: String) {
        guard let rpc else { return }
        DispatchQueue.global(qos: .userInitiated).async { try? rpc.focusTab(tabId) }
    }

    private func focusRemoteWorkspace(_ workspaceId: String) {
        guard let rpc else { return }
        DispatchQueue.global(qos: .userInitiated).async { try? rpc.focusWorkspace(workspaceId) }
    }

    // MARK: - Derived state

    var spaces: [WorkspaceInfo] { snapshot?.workspaces ?? [] }

    var selectedSpace: WorkspaceInfo? {
        guard let selectedWorkspaceId else { return nil }
        return snapshot?.workspace(selectedWorkspaceId)
    }

    var tabsInSelectedSpace: [TabInfo] {
        guard let selectedWorkspaceId, let snapshot else { return [] }
        return snapshot.tabs(in: selectedWorkspaceId)
    }

    var selectedPane: PaneInfo? {
        guard let selectedPaneId else { return nil }
        return snapshot?.pane(selectedPaneId)
    }

    func panes(inTab tabId: String) -> [PaneInfo] {
        snapshot?.panes(in: tabId) ?? []
    }

    func panes(inSpace workspaceId: String) -> [PaneInfo] {
        snapshot?.panes.filter { $0.workspaceId == workspaceId } ?? []
    }

    /// Panes of the selected tab in the order the split tree lays them out,
    /// falling back to the snapshot before the tree has arrived.
    var visiblePanes: [PaneInfo] {
        guard let selectedTabId else { return [] }
        let panes = self.panes(inTab: selectedTabId)
        guard let layout else { return panes }
        let byId = Dictionary(panes.map { ($0.paneId, $0) }, uniquingKeysWith: { first, _ in first })
        return layout.paneIds.compactMap { byId[$0] }
    }

    /// Space rows surface the loudest child state, so a blocked pane stays
    /// visible even while its space is collapsed.
    func effectiveStatus(ofSpace workspace: WorkspaceInfo) -> AgentStatus {
        let panes = panes(inSpace: workspace.workspaceId)
        if let loudest = loudestStatus(of: panes) { return loudest }
        if workspace.agentStatus != .unknown { return workspace.agentStatus }
        return .unknown
    }

    func effectiveStatus(ofTab tab: TabInfo) -> AgentStatus {
        let panes = panes(inTab: tab.tabId)
        if let loudest = loudestStatus(of: panes) { return loudest }
        return tab.agentStatus
    }

    /// The whole connection in one dot, for the host row.
    var effectiveStatus: AgentStatus {
        guard let snapshot else { return .unknown }
        return loudestStatus(of: snapshot.panes) ?? .unknown
    }

    private func loudestStatus(of panes: [PaneInfo]) -> AgentStatus? {
        if panes.contains(where: { $0.agentStatus == .blocked }) { return .blocked }
        if panes.contains(where: { $0.agentStatus == .done && unreadPaneIds.contains($0.paneId) }) { return .done }
        if panes.contains(where: { $0.agentStatus == .working }) { return .working }
        return nil
    }

    func isUnread(paneId: String) -> Bool { unreadPaneIds.contains(paneId) }

    func isUnread(spaceId: String) -> Bool {
        panes(inSpace: spaceId).contains { unreadPaneIds.contains($0.paneId) }
    }

    func unreadCount(inSpace spaceId: String) -> Int {
        panes(inSpace: spaceId).filter { unreadPaneIds.contains($0.paneId) }.count
    }

    func unreadCount(inTab tabId: String) -> Int {
        panes(inTab: tabId).filter { unreadPaneIds.contains($0.paneId) }.count
    }

    private func tabWantsAttention(_ tabId: String) -> Bool {
        unreadCount(inTab: tabId) > 0
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

        settleSelection(snapshot)

        for pane in snapshot.panes {
            guard pane.agentStatus.needsAttention, !isOnScreen(pane) else {
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
        let liveIds = Set(snapshot.panes.map(\.paneId))
        unreadPaneIds.formIntersection(liveIds)
        attentionOrder.removeAll { !unreadPaneIds.contains($0) }

        refreshLayoutIfNeeded()
        delegate?.sessionDidUpdate(self)
    }

    /// Keep space / tab / pane pointing at things that still exist, following
    /// the server's focus when this client has no opinion yet.
    private func settleSelection(_ snapshot: SessionSnapshot) {
        if let selectedWorkspaceId, snapshot.workspace(selectedWorkspaceId) == nil {
            self.selectedWorkspaceId = nil
            selectedTabId = nil
            selectedPaneId = nil
        }
        if selectedWorkspaceId == nil {
            selectedWorkspaceId = snapshot.focusedWorkspaceId ?? snapshot.workspaces.first?.workspaceId
        }
        guard let workspaceId = selectedWorkspaceId else { return }

        let tabs = snapshot.tabs(in: workspaceId)
        if let selectedTabId, !tabs.contains(where: { $0.tabId == selectedTabId }) {
            self.selectedTabId = nil
            selectedPaneId = nil
        }
        if selectedTabId == nil {
            let focused = snapshot.focusedTabId.flatMap { id in tabs.first { $0.tabId == id } }
            selectedTabId = (focused ?? tabs.first { $0.focused } ?? tabs.first)?.tabId
            layout = nil
            layoutKey = nil
        }
        guard let tabId = selectedTabId else { return }

        let panes = snapshot.panes(in: tabId)
        if let selectedPaneId, !panes.contains(where: { $0.paneId == selectedPaneId }) {
            self.selectedPaneId = nil
        }
        if selectedPaneId == nil {
            let focused = snapshot.focusedPaneId.flatMap { id in panes.first { $0.paneId == id } }
            selectedPaneId = (focused ?? panes.first { $0.focused } ?? panes.first)?.paneId
        }
    }

    /// A pane the user is looking at right now: in the selected tab of the
    /// connection the window is showing. Splits mean this is several panes.
    private func isOnScreen(_ pane: PaneInfo) -> Bool {
        isVisible && pane.tabId == selectedTabId
    }

    private func markVisiblePanesRead() {
        guard let selectedTabId else { return }
        for pane in panes(inTab: selectedTabId) where isOnScreen(pane) {
            markRead(pane.paneId)
        }
    }

    /// Ask for the split tree only when the snapshot says this tab's layout is
    /// not the one already drawn — the tree is a second round trip, and the poll
    /// runs every two seconds.
    private func refreshLayoutIfNeeded() {
        guard isVisible, let rpc, let tabId = selectedTabId, let snapshot else { return }
        let summary = snapshot.layout(forTab: tabId)
        let key = "\(tabId)|\(summary?.signature ?? "none")"
        guard key != layoutKey, key != layoutFetchKey else { return }
        layoutFetchKey = key

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let tree = try? rpc.layout(tabId: tabId)
            DispatchQueue.main.async {
                guard let self, self.rpc === rpc, self.selectedTabId == tabId else { return }
                self.layoutFetchKey = nil
                guard let tree else { return }
                self.layout = tree
                self.layoutKey = key
                self.delegate?.sessionDidUpdate(self)
            }
        }
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
