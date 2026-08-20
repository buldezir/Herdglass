import AppKit
import HerdrClient
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [MainWindowController] = []
    private let initialTarget: ConnectTarget?

    init(initialTarget: ConnectTarget? = nil) {
        self.initialTarget = initialTarget
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        RemoteConnection.pruneStaleWorkDirs()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        openWindow(target: initialTarget)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Drop SSH masters and temp dirs now; `deinit` is not guaranteed at exit.
        for controller in windows {
            controller.window?.performClose(nil)
        }
    }

    @objc func newWindow(_ sender: Any?) {
        openWindow(target: nil)
    }

    private func openWindow(target: ConnectTarget?) {
        let controller = MainWindowController(initialTarget: target)
        controller.onClose = { [weak self] closed in
            self?.windows.removeAll { $0 === closed }
        }
        windows.append(controller)
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
        let menu = NSMenu(title: "herdr-term")
        menu.addItem(withTitle: "About herdr-term", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Reload Terminal Config", action: #selector(AppDelegate.reloadTerminalConfig(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Open Terminal Config…", action: #selector(AppDelegate.openTerminalConfig(_:)), keyEquivalent: "")
        menu.addItem(.separator())

        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu()
        NSApp.servicesMenu = services.submenu
        menu.addItem(services)
        menu.addItem(.separator())

        menu.addItem(withTitle: "Hide herdr-term", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = menu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit herdr-term", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private static func file() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(withTitle: "New Window", action: #selector(AppDelegate.newWindow(_:)), keyEquivalent: "n")
        menu.addItem(withTitle: "Connect…", action: #selector(MainWindowController.showConnectSheet), keyEquivalent: "k")
        menu.addItem(withTitle: "Reconnect", action: #selector(MainWindowController.reconnect), keyEquivalent: "r")
        menu.addItem(withTitle: "Disconnect", action: #selector(MainWindowController.disconnect), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
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
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
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
        menu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]
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
