import AppKit
import HerdrClient

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation, SessionControllerDelegate {
    /// Lets the app delegate stop retaining a window that is on its way out.
    var onClose: ((MainWindowController) -> Void)?

    private let session = SessionController()
    private let sidebar = SidebarView()
    private let terminal = TerminalPaneView()
    private let ring = AttentionRingView()
    private let splitController = NSSplitViewController()
    private var attentionItem: NSToolbarItem?
    private var connectSheet: ConnectSheetController?
    private var workspaceKeyMonitor: Any?

    convenience init(initialTarget: ConnectTarget? = nil) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.init(window: window)

        session.delegate = self
        sidebar.onSelectWorkspace = { [weak self] id, source in
            self?.select(focusTerminal: source == .pointer) { $0.selectWorkspace(id) }
        }
        sidebar.onSelectPane = { [weak self] id, source in
            self?.select(focusTerminal: source == .pointer) { $0.selectPane(id) }
        }
        terminal.onDetach = { [weak self] in
            self?.refresh()
        }

        window.delegate = self
        window.title = "herdr-term"
        window.subtitle = SessionController.State.disconnected.summary
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        window.contentViewController = buildSplitController()
        window.toolbar = buildToolbar()
        window.contentMinSize = NSSize(width: 720, height: 420)
        // Restore where the user last left this window before falling back to
        // the middle of the screen.
        if !window.setFrameUsingName("HerdrTermMain") {
            window.setContentSize(NSSize(width: 1180, height: 760))
            window.center()
        }
        window.setFrameAutosaveName("HerdrTermMain")

        installWorkspaceKeyMonitor()
        refresh()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // `--connect host` skips straight to the host; otherwise ask.
            if let initialTarget {
                self.session.connect(initialTarget)
            } else {
                self.showConnectSheet()
            }
        }
    }

    // MARK: - Layout

    private func buildSplitController() -> NSSplitViewController {
        let sidebarController = NSViewController()
        sidebarController.view = sidebar

        let paneController = NSViewController()
        paneController.view = buildTerminalArea()

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 340
        sidebarItem.canCollapse = true
        sidebarItem.holdingPriority = .defaultLow

        let paneItem = NSSplitViewItem(viewController: paneController)
        paneItem.minimumThickness = 400

        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(paneItem)
        splitController.splitView.autosaveName = "HerdrTermSidebar"
        return splitController
    }

    private func buildTerminalArea() -> NSView {
        let container = NSView()
        for view in [terminal, ring] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            // Safe area, not raw bounds: the window uses a full-size content
            // view, so the top rows would otherwise sit under the toolbar.
            let guide = container.safeAreaLayoutGuide
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: guide.topAnchor),
                view.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            ])
        }
        return container
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

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar,
            .sidebarTrackingSeparator,
            .flexibleSpace,
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
            item.label = "Connect"
            item.toolTip = "Connect to a Herdr host (⌘K)"
            item.image = NSImage(systemSymbolName: "network", accessibilityDescription: nil)
            item.target = self
            item.action = #selector(showConnectSheet)
            return item
        default:
            return nil
        }
    }

    // MARK: - Keyboard

    /// ⌘1…⌘9 selects a workspace by the number Herdr shows for it. Menu items
    /// cannot express this (the set changes with every snapshot), so it is a
    /// monitor — scoped to this window, and torn down with it, so a closed
    /// window can never swallow another window's keystrokes.
    private func installWorkspaceKeyMonitor() {
        workspaceKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return event }
            guard
                let characters = event.charactersIgnoringModifiers,
                let number = UInt(characters), (1...9).contains(number),
                let workspace = self.session.snapshot?.workspaces.first(where: { $0.number == number })
                    ?? self.session.snapshot?.workspaces.dropFirst(Int(number) - 1).first
            else { return event }
            self.select(focusTerminal: true) { $0.selectWorkspace(workspace.workspaceId) }
            return nil
        }
    }

    /// Every user-initiated selection goes through here, so picking a pane also
    /// clears a previous detach and (for pointer picks) hands over the keyboard.
    private func select(focusTerminal: Bool, _ body: (SessionController) -> Void) {
        terminal.allowReattach()
        body(session)
        if focusTerminal { terminal.focusTerminal() }
    }

    // MARK: - Actions

    @objc func showConnectSheet() {
        guard let window, window.attachedSheet == nil else { return }
        let sheet = ConnectSheetController()
        sheet.onConnect = { [weak self] target, completion in
            self?.session.connect(target, completion: completion)
        }
        connectSheet = sheet
        guard let sheetWindow = sheet.window else { return }
        window.beginSheet(sheetWindow) { [weak self] _ in
            self?.connectSheet = nil
            self?.terminal.focusTerminal()
        }
    }

    @objc func jumpToAttention() {
        terminal.allowReattach()
        guard session.jumpToAttention() != nil else { NSSound.beep(); return }
        terminal.focusTerminal()
    }

    @objc func disconnect() {
        session.disconnect()
        refresh()
    }

    @objc func reconnect() {
        session.reconnect()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(jumpToAttention):
            return session.hasAttention
        case #selector(disconnect), #selector(reconnect):
            return session.target != nil
        default:
            return true
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if let workspaceKeyMonitor {
            NSEvent.removeMonitor(workspaceKeyMonitor)
            self.workspaceKeyMonitor = nil
        }
        // Tear the SSH master, event thread and bridge down now rather than
        // waiting for ControlPersist to expire.
        terminal.teardown()
        session.disconnect()
        onClose?(self)
    }

    // MARK: - SessionControllerDelegate

    func sessionDidUpdate(_ session: SessionController) {
        refresh()
    }

    func sessionDidFail(_ session: SessionController, error: Error) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Could not connect"
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
        let pane = session.selectedPane

        window.title = pane?.displayName ?? "herdr-term"
        window.subtitle = subtitle(for: pane)
        attentionItem?.isEnabled = session.hasAttention
        attentionItem?.image = NSImage(
            systemSymbolName: session.hasAttention ? "bell.badge.fill" : "bell",
            accessibilityDescription: nil
        )

        sidebar.apply(buildSidebarModel())

        if let pane, let socketPath = session.socketPath {
            terminal.attach(
                paneId: pane.paneId,
                socketPath: socketPath,
                herdrBinary: session.herdrBinary,
                executablePath: Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
            )
            ring.update(active: session.isUnread(paneId: pane.paneId), status: pane.agentStatus)
        } else {
            ring.update(active: false, status: .idle)
            let (title, detail, symbol) = emptyState()
            terminal.showPlaceholder(title: title, detail: detail, symbol: symbol)
        }
    }

    private func subtitle(for pane: PaneInfo?) -> String {
        var parts = [session.state.summary]
        if let pane {
            parts.append(StatusStyle.label(pane.agentStatus))
            if let cwd = pane.foregroundCwd ?? pane.cwd, !cwd.isEmpty {
                parts.append(cwd.abbreviatingHome)
            }
        }
        return parts.joined(separator: "  ·  ")
    }

    private func emptyState() -> (String, String, String) {
        switch session.state {
        case .disconnected:
            return ("Not connected", "Press ⌘K to attach to a Herdr host.", "network")
        case .connecting(let target), .reconnecting(let target):
            return ("Connecting", "Talking to \(target)…", "arrow.triangle.2.circlepath")
        case .failed(let message):
            return ("Connection failed", message, "exclamationmark.triangle")
        case .connected(let target):
            return ("No panes", "\(target) has no panes yet. Start one with `herdr` on the host.", "rectangle.dashed")
        }
    }

    private func buildSidebarModel() -> SidebarModel {
        var model = SidebarModel()
        guard let snapshot = session.snapshot else {
            model.emptyMessage = session.state.summary
            return model
        }

        let tabNumbers = Dictionary(snapshot.tabs.map { ($0.tabId, $0.number) }, uniquingKeysWith: { first, _ in first })
        let tabsPerWorkspace = Dictionary(grouping: snapshot.tabs, by: \.workspaceId).mapValues(\.count)

        for workspace in snapshot.workspaces {
            let panes = session.panes(in: workspace.workspaceId)
            let unreadCount = panes.filter { session.isUnread(paneId: $0.paneId) }.count
            model.workspaces.append(
                SidebarModel.Row(
                    id: workspace.workspaceId,
                    title: "\(workspace.number)  \(workspace.label)",
                    subtitle: workspaceSubtitle(workspace, paneCount: panes.count),
                    status: session.effectiveStatus(of: workspace),
                    unread: unreadCount > 0,
                    badge: unreadCount
                )
            )
            let showTabNumbers = (tabsPerWorkspace[workspace.workspaceId] ?? 0) > 1
            model.panes[workspace.workspaceId] = panes.map { pane in
                SidebarModel.Row(
                    id: pane.paneId,
                    title: pane.displayName,
                    subtitle: paneSubtitle(
                        pane,
                        tabNumber: showTabNumbers ? tabNumbers[pane.tabId] : nil
                    ),
                    status: pane.agentStatus,
                    unread: session.isUnread(paneId: pane.paneId)
                )
            }
        }

        model.selectedId = session.selectedPaneId
        if model.workspaces.isEmpty {
            model.emptyMessage = "No workspaces on this host yet."
        }
        return model
    }

    private func workspaceSubtitle(_ workspace: WorkspaceInfo, paneCount: Int) -> String {
        if let cwd = workspace.tokens?["cwd"], !cwd.isEmpty {
            return cwd.abbreviatingHome
        }
        return paneCount == 1 ? "1 pane" : "\(paneCount) panes"
    }

    private func paneSubtitle(_ pane: PaneInfo, tabNumber: UInt?) -> String {
        var parts: [String] = []
        if let tabNumber { parts.append("tab \(tabNumber)") }
        // Shell panes are titled `user@host:~/path`, so the cwd underneath would
        // just repeat the title; say something useful instead.
        let cwd = (pane.foregroundCwd ?? pane.cwd).map(\.abbreviatingHome) ?? ""
        if !cwd.isEmpty, !pane.displayName.hasSuffix(cwd) {
            parts.append(cwd)
        } else {
            parts.append(StatusStyle.label(pane.agentStatus))
        }
        return parts.joined(separator: "  ·  ")
    }
}

/// Border drawn over the focused pane while it wants attention. Pulses when an
/// agent is blocked, holds steady for an unseen `done`.
private final class AttentionRingView: NSView {
    private var status: AgentStatus = .idle
    private var isActive = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = 6
    }

    required init?(coder: NSCoder) { nil }

    /// Purely decorative: never take clicks away from the terminal underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.borderWidth = isActive ? 2 : 0
        layer?.borderColor = StatusStyle.attentionColor(status).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func update(active: Bool, status: AgentStatus) {
        guard active != isActive || status != self.status else { return }
        isActive = active
        self.status = status
        needsDisplay = true

        layer?.removeAnimation(forKey: "pulse")
        guard active, status == .blocked else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.35
        pulse.duration = 0.85
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        layer?.add(pulse, forKey: "pulse")
    }
}
