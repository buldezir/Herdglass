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
    /// The spaces of every attached host, over the terminal, while ⌘` or a held
    /// ⌥⌘ asks for them.
    private let switcher = SpaceSwitcher()
    private var splitItem: NSToolbarItem?
    private var connectSheet: ConnectSheetController?
    private var keyMonitor: Any?
    private var flagsMonitor: Any?

    /// `restoringHosts` belongs to a launch with nothing named on the command
    /// line: `--connect somewhere` asked for one host, and dialling the
    /// remembered ones alongside it is not what was asked for.
    convenience init(initialTarget: ConnectTarget? = nil, restoringHosts: Bool = false) {
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
        wireSwitcher()

        window.delegate = self
        window.title = "Herdglass"
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
            // Frame autosave name kept from before the Herdglass rename so an
            // existing install reopens at its remembered size and position.
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
        // The monitor reads the setting per keystroke, so this is only about the
        // hints: turning the keys on in Settings has to number the rows in front
        // of the user, not on the next snapshot.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refresh),
            name: SpaceKeys.didChangeNotification,
            object: nil
        )
        installKeyMonitors()
        refresh()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // `--connect host` skips straight to the host. With nothing
            // remembered there is nothing to show but the sheet; with hosts in
            // the sidebar, the launch window puts back the ones that were
            // attached last time and any others stay parked.
            if let initialTarget {
                self.connections.connect(initialTarget)
            } else if self.connections.connections.isEmpty {
                self.showConnectSheet()
            } else if restoringHosts {
                self.connections.restore()
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

    private func wireSwitcher() {
        // Asked at the moment the overlay opens, and not again: the list is the
        // gesture's, frozen for as long as it lasts.
        switcher.spaces = { [weak self] in self?.switcherItems() ?? [] }
        switcher.onCommit = { [weak self] item in
            self?.selectSpace((host: item.hostId, space: item.spaceId))
        }
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

    /// Tab strip on top, the tab's panes underneath, and the space switcher over
    /// both when a held key asks for it.
    private func buildTerminalArea() -> NSView {
        let container = NSView()
        blur.blendingMode = .behindWindow
        blur.material = .underWindowBackground
        blur.state = .active
        blur.isHidden = true
        for view in [blur, tabBar, content, switcher.view] as [NSView] {
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
        // The safe area, like the strip and the panes: the overlay dims what it
        // is a shortcut through, and the titlebar is not part of that.
        NSLayoutConstraint.activate([
            switcher.view.topAnchor.constraint(equalTo: guide.topAnchor),
            switcher.view.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            switcher.view.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            switcher.view.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
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
        let toolbar = NSToolbar(identifier: "HerdglassToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        return toolbar
    }

    // MARK: - NSToolbarDelegate

    private static let connectItemIdentifier = NSToolbarItem.Identifier("connect")
    private static let splitItemIdentifier = NSToolbarItem.Identifier("split")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar,
            .sidebarTrackingSeparator,
            .flexibleSpace,
            Self.splitItemIdentifier,
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

    /// The keyboard this window answers on its own, rather than through a menu
    /// item: picking a space by its row in the sidebar, and the space switcher.
    /// Neither can be a menu item — the set of spaces changes with every
    /// snapshot, and a gesture that begins on a key press and ends when a
    /// modifier comes up is not something a key equivalent can express — so both
    /// are monitors, scoped to this window and torn down with it, and a closed
    /// window can never swallow another window's keystrokes.
    ///
    /// ⌥⌘1…⌥⌘9 are off until Settings turns them on (`SpaceKeys`), which the
    /// monitor asks per keystroke rather than by installing and removing itself:
    /// there is then one answer to "is this key mine" and no window that missed
    /// the toggle.
    ///
    /// Tabs have no key of their own. They had ⌘1…⌘9, read from the config's
    /// `goto_tab` binds, and it went when the numbers did: a strip that does not
    /// number its tabs cannot tell you which one ⌘4 is, and counting them by eye
    /// to reach the fourth is slower than clicking it. ⌥⌘←/→ still walk them.
    private func installKeyMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            return self.handle(keyDown: event) ? nil : event
        }
        // The modifiers are half of this gesture: the hold that opens the
        // overlay, and the release that commits it. Never swallowed — every
        // other modifier in the app rides on the same events.
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true, self.window?.attachedSheet == nil else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            self.switcher.modifiersChanged(to: modifiers)
            return event
        }
    }

    /// True when the keystroke was this window's and the pane below must not see
    /// it. Runs on everything the user types into a terminal, so it gets out of
    /// the way early.
    private func handle(keyDown event: NSEvent) -> Bool {
        // `.numericPad` rides along on the keypad digits, `.function` on
        // anything above the row of numbers, and caps lock is never part of
        // a shortcut.
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        // A keystroke means the ⌥⌘ that is down is the front of a chord — ⌥⌘T,
        // ⌥⌘W, ⌥⌘arrows — and not a hand resting on the prefix to see the list.
        switcher.cancelHold()
        if switcher.isOpen { return handle(switcherKey: Self.unshifted(event), modifiers: modifiers) }
        // Everything below is a ⌘ chord, and asking that first is what keeps the
        // rest of this — a key translation per keystroke — off the path an
        // ordinary character takes into the terminal.
        guard modifiers.contains(.command), !modifiers.contains(.control) else { return false }
        let key = Self.unshifted(event)
        // ⌘`, and ⇧⌘` back the other way: ⌘⇥'s own shape, on the key macOS gives
        // to cycling an app's windows — which this app, having exactly one,
        // has nothing to spend it on.
        if key == "`" {
            switcher.open(advancing: modifiers.contains(.shift) ? -1 : 1, commitsOnRelease: true)
            return true
        }
        guard modifiers == SpaceKeys.modifiers, SpaceKeys.isEnabled else { return false }
        guard let position = Int(key), SpaceKeys.positions.contains(position) else { return false }
        // Rows, counted down the whole sidebar — not `WorkspaceInfo.number`,
        // which is a stable ordinal with gaps, and no longer one host's
        // folder either. Nine keys spread over every attached host reach
        // nine different spaces; nine keys per host reached one host's and
        // left the rest of the sidebar unaddressable without selecting it
        // first, which is the thing the key was supposed to save.
        guard let target = orderedSpaces.dropFirst(position - 1).first else { return false }
        selectSpace(target)
        return true
    }

    /// The key as if nothing were held down, so a digit is the digit and the
    /// grave key is the grave key whatever the chord around it.
    private static func unshifted(_ event: NSEvent) -> String {
        event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? ""
    }

    /// The keys that belong to the overlay while it is up. Every arrow steps
    /// along the one list it is showing, ⌥⌘←/→ and ⌥⌘↑/↓ alike: the tiles are
    /// the sidebar's spaces wrapped onto rows, so "next" is the next tile
    /// whichever way the hand reaches for it, and nothing may reach past the
    /// overlay to switch a tab behind it.
    ///
    /// Anything else is not the switcher's. It takes the overlay down and lets
    /// the keystroke through rather than swallowing it, so a gesture can never
    /// leave the window holding keys the user is trying to type.
    private func handle(switcherKey key: String, modifiers: NSEvent.ModifierFlags) -> Bool {
        switch key {
        case "`":
            switcher.move(by: modifiers.contains(.shift) ? -1 : 1)
        case "\u{F703}", "\u{F701}":
            switcher.move(by: 1)
        case "\u{F702}", "\u{F700}":
            switcher.move(by: -1)
        case "\u{1B}":
            switcher.cancel()
        case "\r", "\u{3}":
            switcher.commit()
        default:
            // The digits jump straight to a tile, and inside the overlay they do
            // it whether or not Settings turned ⌥⌘1…⌥⌘9 on: the tile is drawing
            // the number, and the chord is one nothing else can be using while
            // an overlay is up.
            guard let position = Int(key), SpaceKeys.positions.contains(position) else {
                switcher.cancel()
                return false
            }
            switcher.jump(to: position)
        }
        return true
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

    /// Show the pane behind a notification: the host it belongs to, the space
    /// and tab it sits in, and the keyboard. False when this window does not
    /// know the pane.
    @discardableResult
    func reveal(paneId: String) -> Bool {
        guard let connection = connections.connections.first(where: { $0.session.snapshot?.pane(paneId) != nil })
        else { return false }
        window?.makeKeyAndOrderFront(nil)
        if connections.selectedConnectionId != connection.id {
            connections.select(connection.id)
        }
        select(focusTerminal: true) { $0.selectPane(paneId) }
        return true
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

    /// ⌘W: close what is in front of the user, ghostty's `close_surface`. In a
    /// split that is the pane with the keyboard; in a tab that has only one
    /// pane, closing the pane and closing the tab are the same act, and the tab
    /// is the one worth confirming.
    @objc func closePane(_ sender: Any?) {
        guard let session = connections.selectedSession, let tabId = session.selectedTabId else { return }
        guard let paneId = session.selectedPaneId, session.panes(inTab: tabId).count > 1 else {
            confirmCloseTab(tabId)
            return
        }
        confirmClosePane(paneId)
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
        // The overlay is walking spaces, and it took every arrow while it is up.
        // Belt and braces with the monitor that swallows them: a menu item that
        // reaches its action anyway must still not switch a tab behind the card.
        guard !switcher.isOpen else {
            switcher.move(by: offset)
            return
        }
        guard let session = connections.selectedSession else { return }
        let tabs = session.tabsInSelectedSpace
        guard !tabs.isEmpty, let current = tabs.firstIndex(where: { $0.tabId == session.selectedTabId })
        else { return }
        let next = tabs[(current + offset + tabs.count) % tabs.count]
        select(focusTerminal: true) { $0.selectTab(next.tabId) }
    }

    /// The menu's way in. The key itself is the monitor's — a gesture the menu
    /// cannot express — so this normally runs from a click, with nothing held to
    /// let go of: the overlay then waits for ↩, ⎋ or a click rather than for a
    /// modifier. If ⌘ *is* down, the keystroke reached the menu instead of the
    /// monitor and it behaves as ⌘` should.
    @objc func showSpaceSwitcher(_ sender: Any?) {
        let held = NSEvent.modifierFlags.contains(.command)
        switcher.open(advancing: held ? 1 : 0, commitsOnRelease: held)
    }

    @objc func selectNextSpace() { step(spacesBy: 1) }
    @objc func selectPreviousSpace() { step(spacesBy: -1) }

    /// Every attached host's spaces, in sidebar order, as one list. Both ways
    /// of reaching a space read it: ⌥⌘↑/↓ step along it and ⌥⌘1…⌥⌘9 index into
    /// it, so the ninth row down the sidebar is the ninth row down the sidebar
    /// whichever way you go at it.
    ///
    /// A host that is remembered but not attached has no spaces and so is
    /// simply not in the list: stepping or counting past it must not dial it,
    /// the way selecting its row would.
    private var orderedSpaces: [(host: String, space: String)] {
        connections.connections.flatMap { connection in
            connection.session.spaces.map { (host: connection.id, space: $0.workspaceId) }
        }
    }

    /// Land on a space that may belong to a host other than the selected one,
    /// bringing the host selection with it.
    private func selectSpace(_ target: (host: String, space: String)) {
        if target.host != connections.selectedConnectionId { connections.select(target.host) }
        select(focusTerminal: true) { $0.selectSpace(target.space) }
    }

    /// Down the whole sidebar, not one folder of it: ⌥⌘↑ and ⌥⌘↓ walk every
    /// attached host's spaces in sidebar order and wrap, so the last space of
    /// one host steps into the first space of the next and the host selection
    /// follows.
    private func step(spacesBy offset: Int) {
        // While the overlay is up these move the highlight and nothing else:
        // deferring the landing until the modifier comes up is the whole point
        // of it.
        guard !switcher.isOpen else {
            switcher.move(by: offset)
            return
        }
        let spaces = orderedSpaces
        guard !spaces.isEmpty else { return }
        // With nothing selected yet, step in from the end the user is coming
        // from rather than doing nothing.
        let current = spaces.firstIndex {
            $0.host == connections.selectedConnectionId
                && $0.space == connections.selectedSession?.selectedSpace?.workspaceId
        } ?? (offset > 0 ? -1 : 0)
        selectSpace(spaces[(current + offset + spaces.count) % spaces.count])
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

    /// Closing a pane of a split kills whatever is running in it, so it asks on
    /// the same rule a tab does — `confirm-close-surface`, which is the key this
    /// case is actually named after. `unlessTrivial` is the interesting one: a
    /// bare shell goes without a word, an agent gets asked about.
    private func confirmClosePane(_ paneId: String) {
        guard let session = connections.selectedSession, let window else { return }
        let pane = session.snapshot?.pane(paneId)
        let needsAsking: Bool
        switch GhosttyRuntime.config.confirmClose {
        case .never:
            needsAsking = false
        case .always:
            needsAsking = true
        case .unlessTrivial:
            needsAsking = pane?.agentStatus != .unknown
        }
        guard needsAsking else {
            session.closePane(paneId)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Close this pane?"
        alert.informativeText = "\(pane.map { session.title(ofPane: $0) } ?? "The pane") will be closed on "
            + "\(session.target?.displayName ?? "the host")."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close Pane")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            session.closePane(paneId)
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
        case #selector(closeTab(_:)), #selector(closePane(_:)):
            return session?.selectedTabId != nil
        case #selector(splitRight), #selector(splitDown),
             #selector(focusPaneLeft), #selector(focusPaneRight),
             #selector(focusPaneUp), #selector(focusPaneDown):
            return session?.selectedPaneId != nil
        case #selector(selectNextTab), #selector(selectPreviousTab):
            return (session?.tabsInSelectedSpace.count ?? 0) > 1
        case #selector(selectNextSpace), #selector(selectPreviousSpace), #selector(showSpaceSwitcher(_:)):
            return connections.connections.reduce(0) { $0 + $1.session.spaces.count } > 1
        default:
            return true
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self, name: GhosttyRuntime.configDidChangeNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: SpaceKeys.didChangeNotification, object: nil)
        for monitor in [keyMonitor, flagsMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        keyMonitor = nil
        flagsMonitor = nil
        switcher.cancel()
        // Tear the SSH masters, event threads and bridges down now rather than
        // waiting for ControlPersist to expire.
        content.teardown()
        connections.disconnectAll()
        onClose?(self)
    }

    /// A gesture that ends outside this window ends. Letting go of ⌘ somewhere
    /// else — ⌘⇥ away mid-hold — is a `flagsChanged` this window never sees, and
    /// the overlay would otherwise still be up when the user came back to a
    /// keyboard that had moved on.
    func windowDidResignKey(_ notification: Notification) {
        switcher.cancelHold()
        switcher.cancel()
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

    @objc private func refresh() {
        guard let window else { return }
        let session = connections.selectedSession
        let pane = session?.selectedPane

        // `title` in the ghostty config is a fixed title for every window; with
        // nothing set, the window is named after what it is showing.
        window.title = GhosttyRuntime.config.title
            ?? pane.flatMap { session?.title(ofPane: $0) }
            ?? session?.selectedSpace.map { session?.title(ofSpace: $0) ?? $0.label }
            ?? "Herdglass"
        window.subtitle = subtitle(session: session, pane: pane)

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
        // Asked once for the whole sidebar, so the setting cannot change halfway
        // down it and leave the hints starting at 4.
        let spaceKeys = SpaceKeys.isEnabled
        // How many space rows are already above this host's, so the hints count
        // down the sidebar exactly as `orderedSpaces` does. Both walk
        // `connections.connections` in order and skip a host with no spaces, so
        // the nth hint and the nth key are the same row by construction rather
        // than by two rules agreeing.
        var rowsAbove = 0
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
            // The key hint goes on the rows the key reaches and nowhere else:
            // the first nine spaces in the sidebar, wherever they fall, and none
            // of them while the keys are off. Every host numbering its own
            // spaces from 1 is what emptied the old prefixes out — three
            // attached hosts drew three columns of 1, 2, 3, and a digit that
            // repeats down the sidebar cannot be a key.
            model.spaces[connection.id] = session.spaces.enumerated().map { index, space in
                let count = session.unreadCount(inSpace: space.workspaceId)
                let row = rowsAbove + index
                return SidebarModel.Row(
                    id: Self.spaceRowId(connection.id, space.workspaceId),
                    kind: .space,
                    title: session.title(ofSpace: space),
                    subtitle: spaceSubtitle(space, session: session),
                    status: session.effectiveStatus(ofSpace: space),
                    unread: count > 0,
                    badge: count,
                    shortcut: spaceKeys && SpaceKeys.positions.contains(row + 1)
                        ? SpaceKeys.display(row + 1)
                        : nil
                )
            }
            rowsAbove += session.spaces.count
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

    /// What is in the space, tab by tab. The title says where the space is, so
    /// the second line is the only room there is to say what it is doing — and a
    /// space with three tabs has three answers, not one.
    private func spaceSubtitle(_ space: WorkspaceInfo, session: SessionController) -> String {
        let summaries = session.tabSummaries(inSpace: space.workspaceId)
        if !summaries.isEmpty { return summaries.joined(separator: "  ·  ") }
        // Nothing to list: say so rather than leaving the row half empty.
        if let cwd = space.tokens?["cwd"], !cwd.isEmpty { return cwd.abbreviatingHome }
        return "No tabs"
    }

    // MARK: - Space switcher model

    /// The switcher's tiles: `orderedSpaces` again, which is what makes the
    /// overlay's order, the sidebar's order and the order ⌥⌘↑/↓ walk the same
    /// order by construction rather than by three rules agreeing. A space that
    /// has gone between the walk and the lookup is simply not a tile.
    private func switcherItems() -> [SpaceSwitcherModel.Item] {
        let selectedSpace = connections.selectedSession?.selectedSpace?.workspaceId
        return orderedSpaces.enumerated().compactMap { index, target in
            guard
                let connection = connections.connection(id: target.host),
                let space = connection.session.spaces.first(where: { $0.workspaceId == target.space })
            else { return nil }
            let session = connection.session
            let unread = session.unreadCount(inSpace: space.workspaceId)
            return SpaceSwitcherModel.Item(
                hostId: connection.id,
                spaceId: space.workspaceId,
                hostName: connection.target.displayName,
                symbol: connection.target.isLocal ? "desktopcomputer" : "server.rack",
                title: session.title(ofSpace: space),
                subtitle: spaceSubtitle(space, session: session),
                status: session.effectiveStatus(ofSpace: space),
                unread: unread > 0,
                badge: unread,
                digit: SpaceKeys.positions.contains(index + 1) ? "\(index + 1)" : nil,
                current: connection.id == connections.selectedConnectionId
                    && space.workspaceId == selectedSpace
            )
        }
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
                title: session.title(ofTab: tab),
                status: session.effectiveStatus(ofTab: tab),
                unread: session.unreadCount(inTab: tab.tabId) > 0,
                paneCount: panes.count,
                selected: tab.tabId == session.selectedTabId
            )
        }
        return model
    }

}
