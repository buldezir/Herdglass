import AppKit
import HerdrClient

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation,
    ConnectionsControllerDelegate {
    /// Lets the app delegate stop retaining a window that is on its way out.
    var onClose: ((MainWindowController) -> Void)?

    private let connections = ConnectionsController()
    private let sidebar = SidebarView()
    private let tabBar = TabBarView()
    private let content = SplitContainerView()
    private let splitController = SidebarSplitViewController()
    /// Behind-window blur for `background-blur`; hidden unless the config asks.
    private let blur = NSVisualEffectView()
    private var attentionItem: NSToolbarItem?
    private var splitItem: NSToolbarItem?
    private var connectSheet: ConnectSheetController?
    private var numberKeyMonitor: Any?

    convenience init(initialTarget: ConnectTarget? = nil) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.init(window: window)

        connections.delegate = self
        wireSidebar()
        wireTabBar()
        wireContent()

        window.delegate = self
        window.title = "herdr-term"
        window.subtitle = SessionController.State.disconnected.summary
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        window.contentViewController = buildSplitController()
        window.toolbar = buildToolbar()
        window.contentMinSize = NSSize(width: 720, height: 420)
        // Restore where the user last left this window before falling back to
        // the middle of the screen — unless `window-save-state = never`, which
        // asks for a window that never remembers anything.
        if GhosttyRuntime.config.saveState == .never {
            window.setContentSize(NSSize(width: 1180, height: 760))
            window.center()
        } else {
            if !window.setFrameUsingName("HerdrTermMain") {
                window.setContentSize(NSSize(width: 1180, height: 760))
                window.center()
            }
            window.setFrameAutosaveName("HerdrTermMain")
        }

        applyGhosttyConfig()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applyGhosttyConfig),
            name: GhosttyRuntime.configDidChangeNotification,
            object: nil
        )
        installNumberKeyMonitor()
        refresh()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // `--connect host` skips straight to the host; otherwise ask, unless
            // there are remembered hosts to pick from in the sidebar.
            if let initialTarget {
                self.connections.connect(initialTarget)
            } else if self.connections.connections.isEmpty {
                self.showConnectSheet()
            }
        }
    }

    // MARK: - Wiring

    private func wireSidebar() {
        sidebar.onSelectHost = { [weak self] id, source in
            guard let self else { return }
            self.connections.select(id)
            if source == .pointer { self.content.focusActivePane() }
        }
        sidebar.onSelectSpace = { [weak self] rowId, source in
            guard let self, let (connectionId, workspaceId) = Self.spaceRow(rowId) else { return }
            if self.connections.selectedConnectionId != connectionId {
                self.connections.select(connectionId)
            }
            self.select(focusTerminal: source == .pointer) { $0.selectSpace(workspaceId) }
        }
        sidebar.onAddHost = { [weak self] in self?.showConnectSheet() }
        sidebar.onReconnectHost = { [weak self] id in self?.connections.reconnect(id) }
        sidebar.onDisconnectHost = { [weak self] id in self?.connections.disconnect(id) }
        sidebar.onForgetHost = { [weak self] id in self?.confirmForget(id) }
        sidebar.onNewSpace = { [weak self] id in
            self?.connections.connection(id: id)?.session.newSpace()
        }
    }

    private func wireTabBar() {
        tabBar.onSelect = { [weak self] tabId in
            self?.select(focusTerminal: true) { $0.selectTab(tabId) }
        }
        tabBar.onClose = { [weak self] tabId in self?.confirmCloseTab(tabId) }
        tabBar.onNew = { [weak self] in self?.newTab(nil) }
    }

    private func wireContent() {
        content.onActivatePane = { [weak self] paneId in
            guard let session = self?.connections.selectedSession else { return }
            guard session.selectedPaneId != paneId else { return }
            session.selectPane(paneId)
        }
        content.onPaneDetached = { [weak self] in self?.refresh() }
        content.onSplitRatioChanged = { [weak self] path, ratio in
            self?.connections.selectedSession?.setSplitRatio(path: path, ratio: ratio)
        }
    }

    // MARK: - Layout

    private func buildSplitController() -> SidebarSplitViewController {
        let sidebarController = NSViewController()
        sidebarController.view = sidebar

        let paneController = NSViewController()
        paneController.view = buildTerminalArea()

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 460
        sidebarItem.canCollapse = true
        sidebarItem.holdingPriority = .defaultLow

        let paneItem = NSSplitViewItem(viewController: paneController)
        paneItem.minimumThickness = 400

        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(paneItem)
        return splitController
    }

    /// Tab strip on top, the tab's panes underneath.
    private func buildTerminalArea() -> NSView {
        let container = NSView()
        blur.blendingMode = .behindWindow
        blur.material = .underWindowBackground
        blur.state = .active
        blur.isHidden = true
        for view in [blur, tabBar, content] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        // The blur is pinned to raw bounds, not the safe area: it has to reach
        // under the toolbar as well, or a translucent window has a hard edge
        // across the titlebar.
        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: container.topAnchor),
            blur.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        // Safe area, not raw bounds: the window uses a full-size content view,
        // so the tab strip would otherwise sit under the toolbar.
        let guide = container.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: guide.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            content.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            content.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
        ])
        return container
    }

    // MARK: - Ghostty config

    /// The window half of the ghostty config: the keys that describe the frame
    /// around a terminal rather than the terminal itself.
    ///
    /// `macos-titlebar-style` only distinguishes `native` from everything else
    /// here. `transparent` and `tabs` both mean "let the terminal colour reach
    /// the titlebar", which is one line; `hidden` wants the titlebar gone, and
    /// this window cannot give that up — the toolbar carries the sidebar's
    /// tracking separator — so it is treated as `transparent` too.
    @objc private func applyGhosttyConfig() {
        guard let window else { return }
        let config = GhosttyRuntime.config

        window.titlebarAppearsTransparent = config.titlebarStyle != .native
        window.hasShadow = config.windowShadow
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = !config.windowButtonsVisible
        }

        // `background-opacity` and `background-blur` only mean anything if the
        // window stops being opaque; libghostty already draws the surface with
        // the alpha, and an opaque window behind it just paints it out again.
        window.isOpaque = !config.isTranslucent
        window.backgroundColor = config.titlebarStyle == .native && !config.isTranslucent
            ? .windowBackgroundColor
            : config.paneBackground
        blur.isHidden = config.backgroundBlur == 0

        applyToolbarTooltips(config)
        refresh()
    }

    /// The Split button names its shortcut, so it has to name the real one —
    /// ⌘D unless the config moved `new_split:right` somewhere else.
    private func applyToolbarTooltips(_ config: GhosttyConfig) {
        splitItem?.toolTip = "Split the active pane to the right"
            + (config.shortcut(.splitRight).map { " (\($0.display))" } ?? "")
    }

    private func buildToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "HerdrTermToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        return toolbar
    }

    // MARK: - NSToolbarDelegate

    private static let attentionItemIdentifier = NSToolbarItem.Identifier("attention")
    private static let connectItemIdentifier = NSToolbarItem.Identifier("connect")
    private static let splitItemIdentifier = NSToolbarItem.Identifier("split")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar,
            .sidebarTrackingSeparator,
            .flexibleSpace,
            Self.splitItemIdentifier,
            Self.attentionItemIdentifier,
            Self.connectItemIdentifier,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case .sidebarTrackingSeparator:
            return NSTrackingSeparatorToolbarItem(
                identifier: identifier,
                splitView: splitController.splitView,
                dividerIndex: 0
            )
        case Self.splitItemIdentifier:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Split"
            item.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: nil)
            item.target = self
            item.action = #selector(splitRight)
            splitItem = item
            applyToolbarTooltips(GhosttyRuntime.config)
            return item
        case Self.attentionItemIdentifier:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Attention"
            item.toolTip = "Jump to the pane that needs attention (⇧⌘U)"
            item.image = NSImage(systemSymbolName: "bell.badge", accessibilityDescription: nil)
            item.target = self
            item.action = #selector(jumpToAttention)
            attentionItem = item
            return item
        case Self.connectItemIdentifier:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Add Host"
            item.toolTip = "Attach another Herdr host (⌘K)"
            item.image = NSImage(systemSymbolName: "network", accessibilityDescription: nil)
            item.target = self
            item.action = #selector(showConnectSheet)
            return item
        default:
            return nil
        }
    }

    // MARK: - Keyboard

    /// Picking a tab or a space by number. Menu items cannot express either
    /// (both sets change with every snapshot), so it is a monitor — scoped to
    /// this window, and torn down with it, so a closed window can never swallow
    /// another window's keystrokes.
    ///
    /// The tab keys are whatever the ghostty config binds `goto_tab:1`…
    /// `goto_tab:9` to, ⌘1…⌘9 by default. Spaces stay on ⌃⌘1…⌃⌘9: a Herdr
    /// workspace has no ghostty counterpart, so there is no keybind to read, and
    /// a tab key that collides with it wins because tabs are checked first.
    private func installNumberKeyMonitor() {
        numberKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            // Only the four modifiers a ghostty trigger can carry: `.numericPad`
            // rides along on the keypad digits, `.function` on anything above the
            // row of numbers, and caps lock is never part of a shortcut.
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            // Out before doing any work on an ordinary keystroke: every tab and
            // space key carries at least one of ⌘/⌃/⌥, and this monitor sees
            // everything the user types into a terminal.
            guard !modifiers.intersection([.command, .control, .option]).isEmpty else { return event }
            // Unshifted, so a `shift+cmd+1` binding is looked up as "1" rather
            // than as whatever that key types with shift held — which is what
            // ghostty's own trigger for it says.
            guard
                let characters = (event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers)?
                    .lowercased(),
                let session = self.connections.selectedSession
            else { return event }
            let shortcut = GhosttyConfig.Shortcut(keyEquivalent: characters, modifiers: modifiers)

            if let number = GhosttyRuntime.config.tabShortcuts[shortcut] {
                let tabs = session.tabsInSelectedSpace
                guard let tab = tabs.first(where: { $0.number == number })
                    ?? tabs.dropFirst(Int(number) - 1).first
                else { return event }
                self.select(focusTerminal: true) { $0.selectTab(tab.tabId) }
                return nil
            }

            guard modifiers == [.command, .control],
                  let number = UInt(characters), (1...9).contains(number)
            else { return event }
            let spaces = session.spaces
            guard let space = spaces.first(where: { $0.number == number })
                ?? spaces.dropFirst(Int(number) - 1).first
            else { return event }
            self.select(focusTerminal: true) { $0.selectSpace(space.workspaceId) }
            return nil
        }
    }

    /// Every user-initiated selection goes through here, so picking a pane also
    /// clears a previous detach and (for pointer picks) hands over the keyboard.
    private func select(focusTerminal: Bool, _ body: (SessionController) -> Void) {
        guard let session = connections.selectedSession else { return }
        content.allowReattach()
        body(session)
        if focusTerminal { content.focusActivePane() }
    }

    // MARK: - Actions

    @objc func showConnectSheet() {
        guard let window, window.attachedSheet == nil else { return }
        let sheet = ConnectSheetController()
        sheet.onConnect = { [weak self] target, completion in
            self?.connections.connect(target, completion: completion)
        }
        connectSheet = sheet
        guard let sheetWindow = sheet.window else { return }
        window.beginSheet(sheetWindow) { [weak self] _ in
            self?.connectSheet = nil
            self?.content.focusActivePane()
        }
    }

    @objc func jumpToAttention() {
        // Attention can be on a host the window is not showing; go there first.
        if connections.selectedSession?.hasAttention != true,
           let other = connections.firstConnectionNeedingAttention {
            connections.select(other.id)
        }
        content.allowReattach()
        guard connections.selectedSession?.jumpToAttention() != nil else { NSSound.beep(); return }
        content.focusActivePane()
    }

    @objc func disconnect() {
        guard let id = connections.selectedConnectionId else { return }
        connections.disconnect(id)
    }

    @objc func reconnect() {
        guard let id = connections.selectedConnectionId else { return }
        connections.reconnect(id)
    }

    @objc func newTab(_ sender: Any?) {
        connections.selectedSession?.newTab()
    }

    @objc func closeTab(_ sender: Any?) {
        guard let tabId = connections.selectedSession?.selectedTabId else { return }
        confirmCloseTab(tabId)
    }

    @objc func newSpace(_ sender: Any?) {
        connections.selectedSession?.newSpace()
    }

    @objc func splitRight() {
        connections.selectedSession?.splitSelectedPane(.right)
    }

    @objc func splitDown() {
        connections.selectedSession?.splitSelectedPane(.down)
    }

    @objc func focusPaneLeft() { connections.selectedSession?.focusNeighbour(.left) }
    @objc func focusPaneRight() { connections.selectedSession?.focusNeighbour(.right) }
    @objc func focusPaneUp() { connections.selectedSession?.focusNeighbour(.up) }
    @objc func focusPaneDown() { connections.selectedSession?.focusNeighbour(.down) }

    @objc func selectNextTab() { step(tabsBy: 1) }
    @objc func selectPreviousTab() { step(tabsBy: -1) }

    private func step(tabsBy offset: Int) {
        guard let session = connections.selectedSession else { return }
        let tabs = session.tabsInSelectedSpace
        guard !tabs.isEmpty, let current = tabs.firstIndex(where: { $0.tabId == session.selectedTabId })
        else { return }
        let next = tabs[(current + offset + tabs.count) % tabs.count]
        select(focusTerminal: true) { $0.selectTab(next.tabId) }
    }

    /// Closing a tab destroys its panes on the server, so ask first when there
    /// is more than a bare shell in it — unless `confirm-close-surface` says to
    /// ask every time, or never to ask at all.
    private func confirmCloseTab(_ tabId: String) {
        guard let session = connections.selectedSession, let window else { return }
        let panes = session.panes(inTab: tabId)
        let needsAsking: Bool
        switch GhosttyRuntime.config.confirmClose {
        case .never:
            needsAsking = false
        case .always:
            needsAsking = true
        case .unlessTrivial:
            needsAsking = panes.count > 1 || panes.contains { $0.agentStatus != .unknown }
        }
        guard needsAsking else {
            session.closeTab(tabId)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Close this tab?"
        alert.informativeText = panes.count == 1
            ? "Its pane will be closed on \(session.target?.displayName ?? "the host")."
            : "Its \(panes.count) panes will be closed on \(session.target?.displayName ?? "the host")."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close Tab")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            session.closeTab(tabId)
        }
    }

    private func confirmForget(_ connectionId: String) {
        guard let connection = connections.connection(id: connectionId), let window else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(connection.target.displayName)?"
        alert.informativeText = "This detaches the host and forgets it. Nothing on the server is closed."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.connections.forget(connectionId)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let session = connections.selectedSession
        switch menuItem.action {
        case #selector(jumpToAttention):
            return connections.hasAttention
        case #selector(disconnect), #selector(reconnect):
            return connections.selectedConnectionId != nil
        case #selector(newTab(_:)), #selector(newSpace(_:)):
            return session?.state.isConnected == true
        case #selector(closeTab(_:)):
            return session?.selectedTabId != nil
        case #selector(splitRight), #selector(splitDown),
             #selector(focusPaneLeft), #selector(focusPaneRight),
             #selector(focusPaneUp), #selector(focusPaneDown):
            return session?.selectedPaneId != nil
        case #selector(selectNextTab), #selector(selectPreviousTab):
            return (session?.tabsInSelectedSpace.count ?? 0) > 1
        default:
            return true
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self, name: GhosttyRuntime.configDidChangeNotification, object: nil)
        if let numberKeyMonitor {
            NSEvent.removeMonitor(numberKeyMonitor)
            self.numberKeyMonitor = nil
        }
        // Tear the SSH masters, event threads and bridges down now rather than
        // waiting for ControlPersist to expire.
        content.teardown()
        connections.disconnectAll()
        onClose?(self)
    }

    // MARK: - ConnectionsControllerDelegate

    func connectionsDidChange(_ controller: ConnectionsController) {
        refresh()
    }

    func connections(
        _ controller: ConnectionsController,
        didFail error: Error,
        on connection: ConnectionsController.Connection
    ) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Could not connect to \(connection.target.displayName)"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Connect…")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertSecondButtonReturn { self?.showConnectSheet() }
        }
    }

    // MARK: - Rendering

    private func refresh() {
        guard let window else { return }
        let session = connections.selectedSession
        let pane = session?.selectedPane

        // `title` in the ghostty config is a fixed title for every window; with
        // nothing set, the window is named after what it is showing.
        window.title = GhosttyRuntime.config.title
            ?? pane?.displayName ?? session?.selectedSpace?.label ?? "herdr-term"
        window.subtitle = subtitle(session: session, pane: pane)
        attentionItem?.isEnabled = connections.hasAttention
        attentionItem?.image = NSImage(
            systemSymbolName: connections.hasAttention ? "bell.badge.fill" : "bell",
            accessibilityDescription: nil
        )

        sidebar.apply(buildSidebarModel())
        tabBar.apply(buildTabBarModel(session))
        applyContent(session)
    }

    private func applyContent(_ session: SessionController?) {
        guard
            let session,
            let socketPath = session.socketPath,
            let tabId = session.selectedTabId,
            !session.panes(inTab: tabId).isEmpty
        else {
            let (title, detail, symbol) = emptyState(session)
            content.showPlaceholder(title: title, detail: detail, symbol: symbol)
            return
        }
        // Before the tree lands, one pane is still better than an empty window:
        // fall back to the active pane on its own.
        let tree = session.layout?.root
            ?? session.selectedPaneId.map { LayoutNode.pane(paneId: $0, label: nil, cwd: nil) }
        content.apply(
            SplitContainerView.Model(
                tree: tree,
                panes: session.visiblePanes,
                activePaneId: session.selectedPaneId,
                unreadPaneIds: session.unreadPaneIds,
                attachment: PaneAttachment(
                    socketPath: socketPath,
                    herdrBinary: session.herdrBinary,
                    executablePath: Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
                ),
                // Panes stay warm across tabs and spaces, but not across hosts:
                // only the selected host renders, so the key is what tells the
                // container the panes it is holding belong to someone else now.
                sessionKey: connections.selectedConnectionId,
                knownPaneIds: Set((session.snapshot?.panes ?? []).map(\.paneId))
            )
        )
    }

    private func subtitle(session: SessionController?, pane: PaneInfo?) -> String {
        guard let session else {
            return connections.connections.isEmpty ? "Not connected" : "Pick a host"
        }
        var parts = [session.state.summary]
        if let space = session.selectedSpace { parts.append(space.label) }
        if let pane {
            parts.append(StatusStyle.label(pane.agentStatus))
            if let cwd = pane.foregroundCwd ?? pane.cwd, !cwd.isEmpty {
                parts.append(cwd.abbreviatingHome)
            }
        }
        return parts.joined(separator: "  ·  ")
    }

    private func emptyState(_ session: SessionController?) -> (String, String, String) {
        guard let session else {
            return connections.connections.isEmpty
                ? ("No hosts", "Press ⌘K to attach to a Herdr host.", "network")
                : ("No host selected", "Pick a host in the sidebar to attach it.", "network")
        }
        switch session.state {
        case .disconnected:
            return ("Not attached", "Pick this host in the sidebar to attach it, or press ⌘K.", "network")
        case .connecting(let target), .reconnecting(let target):
            return ("Connecting", "Talking to \(target)…", "arrow.triangle.2.circlepath")
        case .failed(let message):
            return ("Connection failed", message, "exclamationmark.triangle")
        case .connected(let target):
            if session.spaces.isEmpty {
                return ("No spaces", "\(target) has no workspaces yet. Start one with `herdr` on the host.", "rectangle.dashed")
            }
            if session.selectedTabId == nil {
                let key = GhosttyRuntime.config.shortcut(.newTab)?.display ?? "⌘T"
                return ("No tabs", "This space has no tabs. Press \(key) to open one.", "rectangle.dashed")
            }
            return ("No panes", "This tab has no panes.", "rectangle.dashed")
        }
    }

    // MARK: - Sidebar model

    /// Sidebar row ids. A space id is only unique within its host, so the host's
    /// id is part of the row's.
    private static func spaceRowId(_ connectionId: String, _ workspaceId: String) -> String {
        "\(connectionId)/\(workspaceId)"
    }

    private static func spaceRow(_ rowId: String) -> (connectionId: String, workspaceId: String)? {
        guard let slash = rowId.firstIndex(of: "/") else { return nil }
        return (String(rowId[rowId.startIndex..<slash]), String(rowId[rowId.index(after: slash)...]))
    }

    private func buildSidebarModel() -> SidebarModel {
        var model = SidebarModel()
        for connection in connections.connections {
            let session = connection.session
            let unread = session.unreadPaneIds.count
            model.hosts.append(
                SidebarModel.Row(
                    id: connection.id,
                    kind: .host,
                    title: connection.target.displayName,
                    subtitle: hostSubtitle(connection),
                    status: session.effectiveStatus,
                    unread: unread > 0,
                    badge: unread,
                    offline: session.state == .disconnected,
                    busy: session.state.isBusy,
                    symbol: connection.target.isLocal ? "desktopcomputer" : "server.rack"
                )
            )
            model.spaces[connection.id] = session.spaces.map { space in
                let count = session.unreadCount(inSpace: space.workspaceId)
                return SidebarModel.Row(
                    id: Self.spaceRowId(connection.id, space.workspaceId),
                    kind: .space,
                    title: "\(space.number)  \(space.label)",
                    subtitle: spaceSubtitle(space, session: session),
                    status: session.effectiveStatus(ofSpace: space),
                    unread: count > 0,
                    badge: count
                )
            }
        }

        if let connection = connections.selected {
            model.selectedId = connection.session.selectedWorkspaceId
                .map { Self.spaceRowId(connection.id, $0) } ?? connection.id
        }
        if model.hosts.isEmpty {
            model.emptyMessage = "No hosts yet. Add one to see its spaces here."
        }
        return model
    }

    private func hostSubtitle(_ connection: ConnectionsController.Connection) -> String {
        let session = connection.session
        switch session.state {
        case .connected:
            let spaces = session.spaces.count
            return spaces == 1 ? "1 space" : "\(spaces) spaces"
        default:
            return session.state.summary
        }
    }

    private func spaceSubtitle(_ space: WorkspaceInfo, session: SessionController) -> String {
        if let cwd = space.tokens?["cwd"], !cwd.isEmpty {
            return cwd.abbreviatingHome
        }
        let tabs = Int(space.tabCount)
        let panes = session.panes(inSpace: space.workspaceId).count
        let tabPart = tabs == 1 ? "1 tab" : "\(tabs) tabs"
        let panePart = panes == 1 ? "1 pane" : "\(panes) panes"
        return "\(tabPart)  ·  \(panePart)"
    }

    // MARK: - Tab bar model

    private func buildTabBarModel(_ session: SessionController?) -> TabBarModel {
        guard let session, session.state.isConnected else { return TabBarModel() }
        var model = TabBarModel()
        model.canCreate = session.selectedWorkspaceId != nil
        model.items = session.tabsInSelectedSpace.map { tab in
            let panes = session.panes(inTab: tab.tabId)
            return TabBarModel.Item(
                id: tab.tabId,
                number: tab.number,
                title: tabTitle(tab, panes: panes),
                status: session.effectiveStatus(ofTab: tab),
                unread: session.unreadCount(inTab: tab.tabId) > 0,
                paneCount: panes.count,
                selected: tab.tabId == session.selectedTabId
            )
        }
        return model
    }

    /// Herdr labels an unnamed tab with its own number, which says nothing next
    /// to the number already on the row; name it after what is running instead.
    private func tabTitle(_ tab: TabInfo, panes: [PaneInfo]) -> String {
        if tab.label != "\(tab.number)", !tab.label.isEmpty {
            return "\(tab.number)  \(tab.label)"
        }
        let pane = panes.first { $0.focused } ?? panes.first
        guard let pane else { return "\(tab.number)" }
        return "\(tab.number)  \(pane.displayName)"
    }
}
