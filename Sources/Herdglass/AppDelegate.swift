import AppKit
import HerdrClient
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The window. There is exactly one — see `HerdglassMain` for the other
    /// half of that rule, the one that keeps a second *process* from opening a
    /// second one.
    private var main: MainWindowController?
    private var settings: SettingsWindowController?
    private let initialTarget: ConnectTarget?

    init(initialTarget: ConnectTarget? = nil) {
        self.initialTarget = initialTarget
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        applyGhosttyConfig()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applyGhosttyConfig),
            name: GhosttyRuntime.configDidChangeNotification,
            object: nil
        )
        RemoteConnection.pruneStaleWorkDirs()
        AgentNotifications.prepare(delegate: self)
        // A launch with no `--connect` restores: the hosts that were attached
        // when the app was last running come back with it.
        showMainWindow(target: initialTarget, restoringHosts: initialTarget == nil)
    }

    /// The app-wide half of the ghostty config: the appearance `window-theme`
    /// asks for, and the key equivalents `keybind` gives to actions this app can
    /// perform. Windows look after their own chrome.
    ///
    /// `window-theme` defaults to `auto`, which in ghostty means "match the
    /// window to the terminal background" — that is why a ghostty window is dark
    /// on a light desktop, and why this app is too unless the config says
    /// otherwise.
    @objc private func applyGhosttyConfig() {
        let config = GhosttyRuntime.config
        NSApp.appearance = config.appearance
        NSApp.mainMenu?.applyGhosttyShortcuts(config)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Drop SSH masters and temp dirs now; `deinit` is not guaranteed at exit.
        main?.window?.performClose(nil)
    }

    /// Clicking the Dock icon comes back to the window that already exists —
    /// including out of the Dock, which the default reopen does not do for a
    /// miniaturized window it did not open itself.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let window = main?.window else { return true }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return false
    }

    /// The window, made once and shown again afterwards.
    ///
    /// A second one is not a feature this app withholds, it is one it cannot
    /// have: every window would show the same remembered hosts, and dialling
    /// them from two places gives each host a second SSH master and a second
    /// set of bridges for the same panes — two clients disagreeing about one
    /// server, in one app.
    private func showMainWindow(target: ConnectTarget?, restoringHosts: Bool = false) {
        let controller = main ?? {
            let new = MainWindowController(initialTarget: target, restoringHosts: restoringHosts)
            new.onClose = { [weak self] closed in
                guard self?.main === closed else { return }
                self?.main = nil
            }
            main = new
            return new
        }()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func reloadTerminalConfig(_ sender: Any?) {
        GhosttyRuntime.reloadConfig()
    }

    @objc func openTerminalConfig(_ sender: Any?) {
        GhosttyRuntime.openConfig()
    }

    @objc func showSettings(_ sender: Any?) {
        let controller = settings ?? SettingsWindowController()
        settings = controller
        controller.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Open the pane a notification came from: its host, its space and tab, and
    /// the keyboard. The pane belongs to a host the window may not be showing.
    private func reveal(paneId: String) {
        NSApp.activate(ignoringOtherApps: true)
        main?.reveal(paneId: paneId)
    }
}

// MARK: - Notifications

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Banner even while this app is frontmost: a notification is only ever
    /// posted for a pane that is *not* on screen, so the user still cannot see
    /// what it is telling them about.
    ///
    /// Both callbacks are `nonisolated` because nothing UserNotifications hands
    /// over is `Sendable`: read the one string we need where it arrives, and hop
    /// to the main actor with that.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let paneId = response.notification.request.content.userInfo[AgentNotifications.paneIdKey] as? String
        completionHandler()
        guard let paneId else { return }
        Task { @MainActor in self.reveal(paneId: paneId) }
    }
}

/// The menu bar. Built in code because there is no nib; kept close to the
/// standard AppKit layout so the usual shortcuts all exist.
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(submenu(app()))
        mainMenu.addItem(submenu(file()))
        mainMenu.addItem(submenu(edit()))
        mainMenu.addItem(submenu(view()))
        mainMenu.addItem(submenu(terminal()))
        let windowMenu = window()
        mainMenu.addItem(submenu(windowMenu))
        NSApp.windowsMenu = windowMenu
        return mainMenu
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem()
        item.title = menu.title
        item.submenu = menu
        return item
    }

    private static func app() -> NSMenu {
        let menu = NSMenu(title: "Herdglass")
        menu.addItem(withTitle: "About Herdglass", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Reload Terminal Config", action: #selector(AppDelegate.reloadTerminalConfig(_:)), keyEquivalent: "")
            .ghostty(.reloadConfig)
        menu.addItem(withTitle: "Open Terminal Config…", action: #selector(AppDelegate.openTerminalConfig(_:)), keyEquivalent: "")
            .ghostty(.openConfig)
        menu.addItem(.separator())

        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu()
        NSApp.servicesMenu = services.submenu
        menu.addItem(services)
        menu.addItem(.separator())

        menu.addItem(withTitle: "Hide Herdglass", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = menu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Herdglass", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            .ghostty(.quit)
        return menu
    }

    private static func file() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(withTitle: "Add Host…", action: #selector(MainWindowController.showConnectSheet), keyEquivalent: "k")
        menu.addItem(withTitle: "New Space", action: #selector(MainWindowController.newSpace(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Reconnect", action: #selector(MainWindowController.reconnect), keyEquivalent: "r")
        menu.addItem(withTitle: "Disconnect", action: #selector(MainWindowController.disconnect), keyEquivalent: "")
        menu.addItem(.separator())
        // Three of the four closes ghostty has, in the same order and on the
        // same keys. ⌘W is Close, which is the pane when the tab is split and
        // the tab when it is not — closing a whole split with one keystroke is
        // not something the user can ask for by accident. Close All Windows is
        // not among them: with one window it is Close Window under a second
        // name and a second key. (AppKit still grows its own "Close All" out of
        // Close Window, on ⌥⇧⌘W, shown while Option is held — that one is the
        // system's and closes the same single window.)
        menu.addItem(withTitle: "Close", action: #selector(MainWindowController.closePane(_:)), keyEquivalent: "w")
            .ghostty(.closeSurface)
        let closeTab = menu.addItem(
            withTitle: "Close Tab",
            action: #selector(MainWindowController.closeTab(_:)),
            keyEquivalent: "w"
        )
        closeTab.keyEquivalentModifierMask = [.command, .option]
        closeTab.ghostty(.closeTab)
        let closeWindow = menu.addItem(
            withTitle: "Close Window",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        closeWindow.keyEquivalentModifierMask = [.command, .shift]
        closeWindow.ghostty(.closeWindow)
        return menu
    }

    /// Tabs and splits, both of which live on the Herdr server; the GUI only
    /// asks for them.
    private static func terminal() -> NSMenu {
        let menu = NSMenu(title: "Terminal")
        menu.addItem(withTitle: "New Tab", action: #selector(MainWindowController.newTab(_:)), keyEquivalent: "t")
            .ghostty(.newTab)
        // The arrows the chrome is laid out in: tabs run across the strip, so
        // they are ⌥⌘← and ⌥⌘→, and spaces run down the sidebar — every
        // attached host's, one list — so they are ⌥⌘↑ and ⌥⌘↓. Splits, the
        // layer below both, take the same four arrows on ⇧⌘. Not ⌃⌥⌘, which
        // is where they were first put: the menu carried them and AppKit
        // matched them, but something above this app was eating the real
        // keystrokes before it ever saw them.
        let nextTab = menu.addItem(
            withTitle: "Next Tab",
            action: #selector(MainWindowController.selectNextTab),
            keyEquivalent: "\u{F703}"
        )
        nextTab.keyEquivalentModifierMask = [.command, .option]
        nextTab.ghostty(.nextTab)
        let previousTab = menu.addItem(
            withTitle: "Previous Tab",
            action: #selector(MainWindowController.selectPreviousTab),
            keyEquivalent: "\u{F702}"
        )
        previousTab.keyEquivalentModifierMask = [.command, .option]
        previousTab.ghostty(.previousTab)
        menu.addItem(.separator())
        // Spaces are Herdr's own, so ghostty has no action to rebind these to,
        // and they cross hosts: the walk is the sidebar, top to bottom.
        let nextSpace = menu.addItem(
            withTitle: "Next Space",
            action: #selector(MainWindowController.selectNextSpace),
            keyEquivalent: "\u{F701}"
        )
        nextSpace.keyEquivalentModifierMask = [.command, .option]
        let previousSpace = menu.addItem(
            withTitle: "Previous Space",
            action: #selector(MainWindowController.selectPreviousSpace),
            keyEquivalent: "\u{F700}"
        )
        previousSpace.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Split Right", action: #selector(MainWindowController.splitRight), keyEquivalent: "d")
            .ghostty(.splitRight)
        let splitDown = menu.addItem(
            withTitle: "Split Down",
            action: #selector(MainWindowController.splitDown),
            keyEquivalent: "d"
        )
        splitDown.keyEquivalentModifierMask = [.command, .shift]
        splitDown.ghostty(.splitDown)
        menu.addItem(.separator())

        let focus = NSMenu(title: "Select Split")
        for (title, selector, key, action) in [
            ("Left", #selector(MainWindowController.focusPaneLeft), "\u{F702}", GhosttyConfig.Action.focusSplitLeft),
            ("Right", #selector(MainWindowController.focusPaneRight), "\u{F703}", .focusSplitRight),
            ("Up", #selector(MainWindowController.focusPaneUp), "\u{F700}", .focusSplitUp),
            ("Down", #selector(MainWindowController.focusPaneDown), "\u{F701}", .focusSplitDown),
        ] {
            let item = focus.addItem(withTitle: title, action: selector, keyEquivalent: key)
            item.keyEquivalentModifierMask = [.command, .shift]
            item.ghostty(action)
        }
        let focusItem = NSMenuItem(title: "Select Split", action: nil, keyEquivalent: "")
        focusItem.submenu = focus
        menu.addItem(focusItem)
        return menu
    }

    private static func edit() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: #selector(TextEditingActions.undo(_:)), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "Redo", action: #selector(TextEditingActions.redo(_:)), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
            .ghostty(.copy)
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            .ghostty(.paste)
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
            .ghostty(.selectAll)
        return menu
    }

    private static func view() -> NSMenu {
        let menu = NSMenu(title: "View")
        // ⌃⌘S is the system-wide sidebar shortcut; ⌘S belongs to Save.
        menu.addItem(
            withTitle: "Toggle Sidebar",
            action: #selector(NSSplitViewController.toggleSidebar(_:)),
            keyEquivalent: "s"
        ).keyEquivalentModifierMask = [.command, .control]
        let attention = menu.addItem(
            withTitle: "Jump to Attention",
            action: #selector(MainWindowController.jumpToAttention),
            keyEquivalent: "u"
        )
        attention.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        let fullScreen = menu.addItem(
            withTitle: "Enter Full Screen",
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f"
        )
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        fullScreen.ghostty(.toggleFullscreen)
        return menu
    }

    private static func window() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        return menu
    }
}

/// Undo and redo are dispatched down the responder chain by selector; there is
/// no concrete AppKit class to name them on.
@objc private protocol TextEditingActions {
    func undo(_ sender: Any?)
    func redo(_ sender: Any?)
}

private extension NSMenu {
    @discardableResult
    func addItem(withTitle title: String, action: Selector?, keyEquivalent: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        addItem(item)
        return item
    }
}

extension NSMenu {
    /// Re-point every tagged item at the key the user's ghostty config binds to
    /// its action, so a `keybind` line moves this app's menu too.
    ///
    /// An item ghostty has no binding for keeps the shortcut this app shipped
    /// with — that is how ⌘C, ⌘V and the Herdr-only items (Add Host, Jump to
    /// Attention, Toggle Sidebar) survive: ghostty either has no keybind for
    /// them or no such action at all.
    ///
    /// So does an item whose only competition is a ghostty *default*
    /// (`GhosttyConfig.isRebound`). This window has hosts and spaces in it that
    /// ghostty has no actions for, and they need the same arrows: ⌥⌘↑ and ⌥⌘↓
    /// walk the spaces, so the splits ghostty puts there move over to
    /// ⇧⌘arrows. Moving `goto_split:up` somewhere else in the config still
    /// moves the menu item — the one thing that cannot be honoured is a config
    /// that spells ghostty's default out again, since a re-typed default and a
    /// default are the same two bytes to `ghostty_config_trigger`.
    /// An item that ships with no key of its own — Open Terminal Config, whose
    /// ⌘, *is* ghostty's default — takes the binding either way.
    ///
    /// Unless it collides. `open_config` is ⌘, in ghostty and Settings is ⌘,
    /// everywhere in macOS, so those two items ship wanting the same key; a menu
    /// with a duplicate key equivalent silently gives it to whichever item comes
    /// first and the other simply stops working. The keybind wins, because it is
    /// the user's own, and this app's default steps aside.
    func applyGhosttyShortcuts(_ config: GhosttyConfig) {
        surrenderShortcuts(to: applyGhosttyTriggers(config))
    }

    private func applyGhosttyTriggers(_ config: GhosttyConfig) -> Set<GhosttyConfig.Shortcut> {
        var claimed: Set<GhosttyConfig.Shortcut> = []
        for item in items {
            claimed.formUnion(item.submenu?.applyGhosttyTriggers(config) ?? [])
            guard let action = item.ghosttyAction, let shortcut = config.shortcut(action) else { continue }
            guard item.keyEquivalent.isEmpty || config.isRebound(action) else { continue }
            item.keyEquivalent = shortcut.keyEquivalent
            item.keyEquivalentModifierMask = shortcut.modifiers
            claimed.insert(shortcut)
        }
        return claimed
    }

    private func surrenderShortcuts(to claimed: Set<GhosttyConfig.Shortcut>) {
        for item in items {
            item.submenu?.surrenderShortcuts(to: claimed)
            guard item.ghosttyAction == nil, !item.keyEquivalent.isEmpty else { continue }
            let shortcut = GhosttyConfig.Shortcut(
                keyEquivalent: item.keyEquivalent,
                modifiers: item.keyEquivalentModifierMask
            )
            guard claimed.contains(shortcut) else { continue }
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
        }
    }
}

extension NSMenu {
    /// Every item that has a shortcut, and whether it came from the ghostty
    /// config or from this app's own default. Printed by
    /// `--show-ghostty-config`.
    func shortcutSummary(_ config: GhosttyConfig, indent: String = "  ") -> String {
        var lines: [String] = []
        for item in items {
            if !item.keyEquivalent.isEmpty {
                let shortcut = GhosttyConfig.Shortcut(
                    keyEquivalent: item.keyEquivalent,
                    modifiers: item.keyEquivalentModifierMask
                )
                // By what the item is actually wearing: an action whose
                // keybind was not applied kept this app's own key.
                let source = item.ghosttyAction
                    .flatMap { config.shortcut($0) == shortcut ? "keybind \($0.rawValue)" : nil }
                    ?? "built in"
                lines.append("\(indent)\(item.title.padding(toLength: 24, withPad: " ", startingAt: 0)) "
                    + "\(shortcut.display.padding(toLength: 6, withPad: " ", startingAt: 0)) \(source)")
            }
            if let submenu = item.submenu {
                lines.append(
                    contentsOf: submenu.shortcutSummary(config, indent: indent + "  ")
                        .split(separator: "\n")
                        .map(String.init)
                )
            }
        }
        return lines.joined(separator: "\n")
    }
}

private extension NSMenuItem {
    private static let ghosttyPrefix = "ghostty:"

    /// Names the ghostty `keybind` action this item performs. Stored in the
    /// item's identifier so the menu itself carries the mapping and
    /// `applyGhosttyShortcuts` can be a plain walk of the tree.
    @discardableResult
    func ghostty(_ action: GhosttyConfig.Action) -> NSMenuItem {
        identifier = NSUserInterfaceItemIdentifier(Self.ghosttyPrefix + action.rawValue)
        return self
    }

    var ghosttyAction: GhosttyConfig.Action? {
        guard let raw = identifier?.rawValue, raw.hasPrefix(Self.ghosttyPrefix) else { return nil }
        return GhosttyConfig.Action(rawValue: String(raw.dropFirst(Self.ghosttyPrefix.count)))
    }
}
