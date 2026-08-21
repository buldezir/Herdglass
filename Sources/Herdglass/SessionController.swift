import Foundation
import HerdrClient

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
    /// Split trees, one per tab, each remembered with the layout signature it
    /// was fetched for. A tree outlives leaving its tab: coming back to a tab
    /// that has to guess at a single pane first, and re-split a round trip
    /// later, is exactly what reads as a reconnect.
    private var layoutTrees: [String: (key: String, tree: LayoutTree)] = [:]

    /// Split tree of the selected tab, as long as every pane in it still
    /// exists. A tree whose signature has moved on is still worth drawing while
    /// the refetch is in flight — the alternative is a single-pane guess and a
    /// visible re-split a moment later.
    var layout: LayoutTree? {
        guard let selectedTabId else { return nil }
        return usableTree(forTab: selectedTabId)
    }

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

    /// A tab this client has just asked the server for and means to land on.
    ///
    /// It cannot simply be selected: `selectTab` needs the tab to be in the
    /// snapshot and a tab that was created a moment ago is not in any snapshot
    /// yet — nor is the refresh that follows the create necessarily the next one
    /// to land, because a poll issued before it can answer first. So the
    /// intention is held until a snapshot actually carries the tab.
    private var pendingTabId: String?

    /// A pane this client has just asked the server for and means to land on:
    /// the far side of a split. Held for the same reason as `pendingTabId` — the
    /// pane does not exist in any snapshot yet, and the refresh that follows the
    /// split is not necessarily the next one to land.
    private var pendingPaneId: String?

    /// Where this host was when it was last attached, waiting for the snapshot
    /// that can turn it back into a selection. Consumed by the first
    /// `settleSelection` after a connect and dropped there whether it fitted or
    /// not — a record that outlived one snapshot would fight the user's clicks.
    private var restoring: RecentsStore.Selection?

    /// What is already written down for this host, so the common case — a
    /// snapshot every two seconds that settles onto the same three ids — does
    /// not re-encode the whole record each time.
    private var persistedSelection: RecentsStore.Selection?

    private var attentionOrder: [String] = []
    /// What each unread pane was last notified about. Herdr's own detection
    /// flaps — a pane can read `blocked`, `working`, `blocked` again inside a
    /// second while the agent redraws its prompt — and without this every flap
    /// is another banner and another sound. News is a *different* reason, not
    /// the same one again; the entry is dropped when the pane is read.
    private var notifiedReasons: [String: AgentNotifications.Reason] = [:]
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
    /// Tabs with a `layout.export` in flight, so a poll every two seconds
    /// cannot pile requests onto the same tab.
    private var layoutFetches: Set<String> = []
    /// Tab id to the signature we last prefetched it for, so a prefetch that
    /// fails is not retried on every poll.
    private var layoutPrefetches: [String: String] = [:]
    /// Held here rather than captured by the worker closure: a UI callback is
    /// not `Sendable` and must not cross to a background queue.
    private var pendingConnect: ((Error?) -> Void)?

    /// Every request this session makes, one at a time, on one thread.
    ///
    /// It has to be a queue of our own rather than `DispatchQueue.global`, and
    /// the difference only shows on a forwarded socket. Each request is a
    /// blocking round trip; events arrive faster than a round trip takes; and
    /// dispatch answers a blocked block by starting another thread. Every one of
    /// the global pool's 64 threads therefore ended up parked inside
    /// `HerdrRPC.request`, which starves everything else that needs a worker —
    /// the `pane.focus` for a space the user just picked waited behind dozens of
    /// stale snapshots, and `⌘Q` sat in AppKit's
    /// `_waitForPendingChangesToFinish` (which needs a pool thread of its own)
    /// until the backlog drained, for the best part of a minute.
    private let work = DispatchQueue(label: "herdr.session", qos: .userInitiated)
    /// A snapshot is in flight; another request would only queue behind it.
    private var snapshotInFlight = false
    /// Something asked for a snapshot while one was in flight. One more when it
    /// lands is enough however many asked — they would all read the same server.
    private var snapshotQueued = false
    private var lastSnapshotStart: Date = .distantPast
    private var coalesceTimer: Timer?
    /// Floor between snapshots, so a pane printing output — which is a
    /// `pane.updated` event per burst — cannot drive the whole window's refresh
    /// at the rate the terminal writes.
    private static let minimumSnapshotInterval: TimeInterval = 0.2

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
        coalesceTimer?.invalidate()
        coalesceTimer = nil
        snapshotInFlight = false
        snapshotQueued = false
        events?.cancel()
        events = nil
        rpc = nil
        connection?.close()
        connection = nil
        snapshot = nil
        selectedWorkspaceId = nil
        selectedTabId = nil
        selectedPaneId = nil
        pendingTabId = nil
        pendingPaneId = nil
        socketPath = nil
        // The record in defaults survives — that is what it is for — but the
        // *pending* one must not: a reconnect asks for it again from scratch.
        restoring = nil
        persistedSelection = nil
        layoutTrees = [:]
        layoutFetches = []
        layoutPrefetches = [:]
        for paneId in unreadPaneIds { AgentNotifications.withdraw(paneId: paneId) }
        unreadPaneIds = []
        attentionOrder = []
        notifiedReasons = [:]
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
        // Whatever this client was waiting to land on, this is where it is going
        // instead — a tab created a second ago must not yank the user off a row
        // they have since picked themselves.
        pendingTabId = nil
        pendingPaneId = nil
        selectedWorkspaceId = workspaceId
        if let tab = preferredTab(in: workspaceId, snapshot: snapshot) {
            selectTab(tab.tabId)
        } else {
            selectedTabId = nil
            selectedPaneId = nil
            focusRemoteWorkspace(workspaceId)
            rememberSelection()
            delegate?.sessionDidUpdate(self)
        }
    }

    /// Where picking a space lands: a tab that wants attention first, then the
    /// one Herdr has active or focused. Shared with the layout prefetch, so the
    /// tree that gets fetched ahead of time is the tab the user will land on.
    private func preferredTab(in workspaceId: String, snapshot: SessionSnapshot) -> TabInfo? {
        let tabs = snapshot.tabs(in: workspaceId)
        return tabs.first { tabWantsAttention($0.tabId) }
            ?? tabs.first { $0.tabId == snapshot.workspace(workspaceId)?.activeTabId }
            ?? tabs.first { $0.focused }
            ?? tabs.first
    }

    /// Where picking a tab lands, on the same principle.
    private func preferredPane(in tabId: String, snapshot: SessionSnapshot) -> PaneInfo? {
        let panes = snapshot.panes(in: tabId)
        return panes.first { unreadPaneIds.contains($0.paneId) }
            ?? panes.first { $0.focused }
            ?? panes.first
    }

    func selectTab(_ tabId: String) {
        guard let snapshot, let tab = snapshot.tab(tabId) else { return }
        // Whatever this client was waiting to land on, this is where it is going
        // instead — a tab created a second ago must not yank the user off a row
        // they have since picked themselves.
        pendingTabId = nil
        pendingPaneId = nil
        selectedWorkspaceId = tab.workspaceId
        selectedTabId = tabId
        if let pane = preferredPane(in: tabId, snapshot: snapshot) {
            selectPane(pane.paneId)
        } else {
            selectedPaneId = nil
            focusRemoteTab(tabId)
            rememberSelection()
            refreshLayoutIfNeeded()
            delegate?.sessionDidUpdate(self)
        }
    }

    /// Pick a pane. Also settles which tab and space are selected, so clicking
    /// a pane inside a split never leaves the sidebar pointing somewhere else.
    func selectPane(_ paneId: String) {
        guard let pane = snapshot?.pane(paneId) else { return }
        // Whatever this client was waiting to land on, this is where it is going
        // instead — a tab created a second ago must not yank the user off a row
        // they have since picked themselves.
        pendingTabId = nil
        pendingPaneId = nil
        selectedTabId = pane.tabId
        selectedWorkspaceId = pane.workspaceId
        selectedPaneId = paneId
        markVisiblePanesRead()
        focusRemotePane(paneId)
        rememberSelection()
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

    /// Split, and land on the pane that appears — which is what `focus: true`
    /// asks the server for, and what ghostty does with its own splits.
    ///
    /// Without adopting the id, `settleSelection` keeps the selection on the pane
    /// that was split (it still exists), so the new pane opened *beside* the
    /// accent border and the keyboard: the border said one pane, the split the
    /// user had just asked for was the other, and nothing was typing into
    /// either.
    func splitSelectedPane(_ direction: SplitDirection) {
        guard let paneId = selectedPaneId, let rpc else { return }
        perform({ try rpc.splitPane(paneId, direction: direction, focus: true).paneId }) { session, newPaneId in
            session.pendingPaneId = newPaneId
            session.applyPendingPaneSelection()
        }
    }

    /// Herdr decides which pane lies in a direction — it owns the geometry — and
    /// this client then has to *go* there.
    ///
    /// Adopting the answer is the whole feature, not a refinement of it:
    /// `settleSelection` only fills a selection that has gone missing, so a
    /// request that moves the server's focus and says nothing else leaves the
    /// accent border and the keyboard on the pane the user was already in. The
    /// keystroke then looks dead — and pressing it again asks the same
    /// question from the same pane. `no_neighbor` comes back as the pane it
    /// started from, which lands on itself and is the no-op it should be.
    func focusNeighbour(_ direction: PaneDirection) {
        guard let paneId = selectedPaneId, let rpc else { return }
        perform({ try rpc.focusPane(from: paneId, direction: direction).focusedPaneId }) { session, paneId in
            session.selectPane(paneId)
        }
    }

    /// Open a tab and go to it. Herdr focuses it server-side, but this client's
    /// selection is its own — without landing on it the new tab appears in the
    /// strip and the window carries on showing the old one.
    func newTab() {
        guard let workspaceId = selectedWorkspaceId, let rpc else { return }
        perform({ try rpc.createTab(workspaceId: workspaceId, focus: true).tabId }) { session, tabId in
            session.pendingTabId = tabId
            session.applyPendingTabSelection()
        }
    }

    /// Take the tab this client is waiting for as soon as a snapshot has it.
    private func applyPendingTabSelection() {
        guard let tabId = pendingTabId else { return }
        guard snapshot?.tab(tabId) != nil else { return }
        pendingTabId = nil
        selectTab(tabId)
    }

    /// Same, for the far side of a split.
    private func applyPendingPaneSelection() {
        guard let paneId = pendingPaneId else { return }
        guard snapshot?.pane(paneId) != nil else { return }
        pendingPaneId = nil
        selectPane(paneId)
    }

    func closeTab(_ tabId: String) {
        guard let rpc else { return }
        perform { try rpc.closeTab(tabId) }
    }

    /// Close one pane of a split. Nothing here has to move the selection or the
    /// split tree: the pane leaves the next snapshot, `settleSelection` picks up
    /// whatever Herdr focused instead, and the tree is refetched because its
    /// signature moved.
    func closePane(_ paneId: String) {
        guard let rpc else { return }
        perform { try rpc.closePane(paneId) }
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
        work.async { [weak self] in
            try? body()
            DispatchQueue.main.async { self?.refreshSnapshot() }
        }
    }

    /// Same, for a request whose answer the caller needs — the id of the thing
    /// the server just made. `then` runs on the main thread before the snapshot
    /// that will confirm it, and not at all if the request failed.
    private func perform<T: Sendable>(
        _ body: @escaping @Sendable () throws -> T,
        then completion: @escaping @MainActor (SessionController, T) -> Void
    ) {
        work.async { [weak self] in
            let result = try? body()
            DispatchQueue.main.async {
                guard let self else { return }
                if let result { completion(self, result) }
                self.refreshSnapshot()
            }
        }
    }

    private func focusRemotePane(_ paneId: String) {
        guard let rpc else { return }
        work.async { try? rpc.focusPane(paneId) }
    }

    private func focusRemoteTab(_ tabId: String) {
        guard let rpc else { return }
        work.async { try? rpc.focusTab(tabId) }
    }

    private func focusRemoteWorkspace(_ workspaceId: String) {
        guard let rpc else { return }
        work.async { try? rpc.focusWorkspace(workspaceId) }
    }

    // MARK: - Derived state

    var spaces: [WorkspaceInfo] { snapshot?.orderedWorkspaces ?? [] }

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

    /// What a space and a tab are called right now — recomputed from the
    /// snapshot every time, so a title follows the agent or the directory
    /// inside it without anything having to invalidate a cache.
    func title(ofSpace space: WorkspaceInfo) -> String {
        snapshot?.title(ofWorkspace: space) ?? space.label
    }

    func title(ofTab tab: TabInfo) -> String {
        snapshot?.title(ofTab: tab) ?? tab.label
    }

    /// Where a tab sits in its space — what the strip numbers and ⌘1…⌘9 mean.
    /// Never `TabInfo.number`, which has gaps.
    func position(ofTab tab: TabInfo) -> Int {
        snapshot?.position(ofTab: tab) ?? Int(tab.number)
    }

    /// Every tab in a space, shortest useful form, for the sidebar row.
    func tabSummaries(inSpace workspaceId: String) -> [String] {
        snapshot?.tabSummaries(inWorkspace: workspaceId) ?? []
    }

    func title(ofPane pane: PaneInfo) -> String {
        snapshot?.paneTitle(pane) ?? pane.displayName
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
        // Attached now, so attached at the next launch: the list of hosts to
        // dial again is written when a host comes up, never when it goes down —
        // quitting the app closes every session, and clearing the flag there
        // would forget exactly what it is for.
        RecentsStore.markAttached(connection.target)
        // Read before the first snapshot is applied, because that snapshot is
        // where it gets used: `settleSelection` prefers these ids over the
        // server's focus, so the window comes back to the space, tab and pane it
        // was on rather than to wherever Herdr was last driven from — including
        // from the TUI, or by another client.
        restoring = RecentsStore.selection(for: connection.target)
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

    /// Ask the server what it looks like now — at most one request at a time,
    /// and at most one every `minimumSnapshotInterval`.
    ///
    /// Both bounds are load bearing. Every event on the stream lands here, and a
    /// pane printing output produces events far faster than a forwarded socket
    /// can answer them: without coalescing, each one started another blocking
    /// request on another thread, and without the floor, each one drove a full
    /// window refresh. What the user saw was a window that fell behind, clicks
    /// on a space that did nothing, and a minute-long `⌘Q`.
    private func refreshSnapshot() {
        guard let rpc else { return }
        guard !snapshotInFlight else {
            snapshotQueued = true
            return
        }
        let sinceLast = Date().timeIntervalSince(lastSnapshotStart)
        guard sinceLast >= Self.minimumSnapshotInterval else {
            scheduleCoalescedSnapshot(after: Self.minimumSnapshotInterval - sinceLast)
            return
        }
        coalesceTimer?.invalidate()
        coalesceTimer = nil
        snapshotQueued = false
        snapshotInFlight = true
        lastSnapshotStart = Date()
        work.async { [weak self] in
            let result = Result { try rpc.snapshot() }
            DispatchQueue.main.async {
                // The flag is cleared by `disconnect`, so a reply from a session
                // that has since been replaced must not clear the new one's.
                guard let self, self.rpc === rpc else { return }
                self.snapshotInFlight = false
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
                if self.snapshotQueued { self.refreshSnapshot() }
            }
        }
    }

    private func scheduleCoalescedSnapshot(after delay: TimeInterval) {
        snapshotQueued = true
        guard coalesceTimer == nil else { return }
        coalesceTimer = Timer.scheduledTimer(withTimeInterval: max(delay, 0.01), repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.coalesceTimer = nil
                self?.refreshSnapshot()
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
            // Herdr's own notification: a background agent that has just
            // started asking for something. On the transition only, so a pane
            // that stays blocked does not re-notify on every poll.
            if !isInitial,
               let reason = AgentNotifications.Reason(pane.agentStatus),
               previousStatus[pane.paneId] != pane.agentStatus,
               notifiedReasons[pane.paneId] != reason {
                notifiedReasons[pane.paneId] = reason
                AgentNotifications.post(
                    paneId: pane.paneId,
                    title: snapshot.paneTitle(pane),
                    subtitle: whereabouts(of: pane),
                    reason: reason
                )
            }
        }

        // A pane can disappear while it is still unread. Read it rather than
        // just dropping it: `jumpToAttention` would otherwise start selecting
        // panes that no longer exist, and its notification would outlive it.
        let liveIds = Set(snapshot.panes.map(\.paneId))
        for paneId in unreadPaneIds.subtracting(liveIds) { markRead(paneId) }

        // A tab that closed takes its cached tree with it.
        let liveTabs = Set(snapshot.tabs.map(\.tabId))
        layoutTrees = layoutTrees.filter { liveTabs.contains($0.key) }
        layoutPrefetches = layoutPrefetches.filter { liveTabs.contains($0.key) }

        applyPendingTabSelection()
        applyPendingPaneSelection()
        rememberSelection()
        refreshLayoutIfNeeded()
        delegate?.sessionDidUpdate(self)
    }

    /// Keep space / tab / pane pointing at things that still exist, following
    /// what this host was last left on, then the server's focus, when this client
    /// has no opinion yet.
    private func settleSelection(_ snapshot: SessionSnapshot) {
        // One shot. The snapshot straight after a connect is the only one that
        // can honour a remembered selection: either those ids are in it or they
        // are gone, and a record kept past that would keep pulling the window
        // back off whatever the user has since picked.
        let restoring = self.restoring
        self.restoring = nil

        if let selectedWorkspaceId, snapshot.workspace(selectedWorkspaceId) == nil {
            self.selectedWorkspaceId = nil
            selectedTabId = nil
            selectedPaneId = nil
        }
        if selectedWorkspaceId == nil {
            let remembered = restoring?.workspaceId.flatMap { snapshot.workspace($0) }
            selectedWorkspaceId = remembered?.workspaceId
                ?? snapshot.focusedWorkspaceId
                ?? snapshot.orderedWorkspaces.first?.workspaceId
        }
        guard let workspaceId = selectedWorkspaceId else { return }

        let tabs = snapshot.tabs(in: workspaceId)
        if let selectedTabId, !tabs.contains(where: { $0.tabId == selectedTabId }) {
            self.selectedTabId = nil
            selectedPaneId = nil
        }
        if selectedTabId == nil {
            let remembered = restoring?.tabId.flatMap { id in tabs.first { $0.tabId == id } }
            let focused = snapshot.focusedTabId.flatMap { id in tabs.first { $0.tabId == id } }
            selectedTabId = (remembered ?? focused ?? tabs.first { $0.focused } ?? tabs.first)?.tabId
        }
        guard let tabId = selectedTabId else { return }

        let panes = snapshot.panes(in: tabId)
        if let selectedPaneId, !panes.contains(where: { $0.paneId == selectedPaneId }) {
            self.selectedPaneId = nil
        }
        if selectedPaneId == nil {
            let remembered = restoring?.paneId.flatMap { id in panes.first { $0.paneId == id } }
            let focused = snapshot.focusedPaneId.flatMap { id in panes.first { $0.paneId == id } }
            selectedPaneId = (remembered ?? focused ?? panes.first { $0.focused } ?? panes.first)?.paneId
        }

        // Landing somewhere the server is not already looking is this client
        // making a choice, exactly as a click is, so the server has to hear about
        // it: Herdr's focus is what `herdr pane run` and the TUI mean by "here".
        //
        // Two guards, both narrowing this to the one case it is for. Only a pane
        // we actually restored — settling onto a pane because the old one closed
        // is following the server, not overruling it. And only the host on
        // screen: restoring four hosts at launch must not move the focus on three
        // servers nobody is looking at, where somebody may well be working in the
        // TUI. `isVisible` is already set by the time a connect finishes, because
        // selecting a host is what starts the dial.
        if isVisible, let paneId = selectedPaneId, restoring?.paneId == paneId, paneId != snapshot.focusedPaneId {
            focusRemotePane(paneId)
        }
    }

    /// Write down where this host is, so attaching it again comes back here.
    ///
    /// Called from every place the selection can move — the user's own picks and
    /// the settle that follows each snapshot — because the app is quit and the
    /// window is closed without either announcing itself, so there is no later
    /// moment to do this in. A space is the least it will record: a host with
    /// nothing selected has nothing worth coming back to, and writing that would
    /// erase where it was.
    private func rememberSelection() {
        guard let target, let workspaceId = selectedWorkspaceId else { return }
        let selection = RecentsStore.Selection(
            workspaceId: workspaceId,
            tabId: selectedTabId,
            paneId: selectedPaneId
        )
        guard selection != persistedSelection else { return }
        persistedSelection = selection
        RecentsStore.rememberSelection(selection, for: target)
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

    /// The tree we can draw for a tab: the one Herdr last reported, unless a
    /// pane in it has since closed — that pane would be drawn as a leaf with no
    /// bridge behind it.
    private func usableTree(forTab tabId: String) -> LayoutTree? {
        guard let cached = layoutTrees[tabId] else { return nil }
        guard let snapshot else { return cached.tree }
        let live = Set(snapshot.panes(in: tabId).map(\.paneId))
        guard cached.tree.paneIds.allSatisfy(live.contains) else { return nil }
        return cached.tree
    }

    /// Ask for the split tree only when the snapshot says this tab's layout is
    /// not the one already cached — the tree is a second round trip, and the
    /// poll runs every two seconds. Tabs the user is one click away from are
    /// then filled in behind that, so switching has nothing to wait for.
    private func refreshLayoutIfNeeded() {
        guard isVisible, let snapshot else { return }
        if let tabId = selectedTabId {
            fetchLayout(tabId: tabId, key: layoutKey(forTab: tabId, in: snapshot), prefetch: false)
        }
        prefetchLayouts(snapshot)
    }

    private func layoutKey(forTab tabId: String, in snapshot: SessionSnapshot) -> String {
        "\(tabId)|\(snapshot.layout(forTab: tabId)?.signature ?? "none")"
    }

    /// Trees for the rest of this space, and for wherever each other space would
    /// land. Only tabs with no tree at all are fetched: one that has merely gone
    /// stale already draws immediately and refetches when it is selected, so
    /// this settles to nothing rather than repeating on every poll.
    ///
    /// One request at a time, behind the selected tab's own fetch, so the
    /// prefetch can never delay what is on screen.
    private func prefetchLayouts(_ snapshot: SessionSnapshot) {
        guard layoutFetches.isEmpty else { return }
        var tabIds: [String] = []
        if let selectedWorkspaceId {
            tabIds += snapshot.tabs(in: selectedWorkspaceId).map(\.tabId)
        }
        for workspace in snapshot.orderedWorkspaces where workspace.workspaceId != selectedWorkspaceId {
            if let tab = preferredTab(in: workspace.workspaceId, snapshot: snapshot) {
                tabIds.append(tab.tabId)
            }
        }
        for tabId in tabIds where layoutTrees[tabId] == nil {
            let key = layoutKey(forTab: tabId, in: snapshot)
            guard layoutPrefetches[tabId] != key else { continue }
            layoutPrefetches[tabId] = key
            fetchLayout(tabId: tabId, key: key, prefetch: true)
            return
        }
    }

    private func fetchLayout(tabId: String, key: String, prefetch: Bool) {
        guard let rpc, layoutTrees[tabId]?.key != key, !layoutFetches.contains(tabId) else { return }
        layoutFetches.insert(tabId)
        work.async { [weak self] in
            let tree = try? rpc.layout(tabId: tabId)
            DispatchQueue.main.async {
                guard let self, self.rpc === rpc else { return }
                self.layoutFetches.remove(tabId)
                if let tree {
                    self.layoutTrees[tabId] = (key, tree)
                    // A prefetch changes nothing the window is drawing now.
                    if tabId == self.selectedTabId { self.delegate?.sessionDidUpdate(self) }
                }
                // Take the next tab straight after this one rather than one per
                // poll: a cache that needs two seconds a tab to warm up has not
                // warmed up by the time the user switches. The chain ends
                // because every tab is marked as attempted before it is asked
                // for — including one whose fetch failed, which is what keeps a
                // failure from becoming a retry loop.
                if prefetch { self.refreshLayoutIfNeeded() }
            }
        }
    }

    /// Reading a pane also answers its notification: the banner in Notification
    /// Center means the same thing as the unread mark in the sidebar, so the two
    /// are cleared together. Guarded because every snapshot marks every settled
    /// pane read, and only a pane that really was unread has anything posted.
    private func markRead(_ paneId: String) {
        guard unreadPaneIds.remove(paneId) != nil else { return }
        attentionOrder.removeAll { $0 == paneId }
        notifiedReasons[paneId] = nil
        AgentNotifications.withdraw(paneId: paneId)
    }

    /// Where a pane is, for a notification that has to say so without the
    /// window: the host, and the space inside it.
    private func whereabouts(of pane: PaneInfo) -> String {
        [target?.displayName, snapshot?.workspace(pane.workspaceId)?.label]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
