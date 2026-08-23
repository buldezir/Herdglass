import AppKit

/// ⌥⌘1…⌥⌘9, the keys that pick a space by its row in the sidebar — whether they
/// are on, and how they are spelled.
///
/// Off by default, and a setting rather than a constant, because these are nine
/// chords taken away from the terminal underneath before the pane ever sees
/// them, and because a row only earns a number where a key answers it: with the
/// setting off the sidebar has nine fewer numbers as well as nine fewer keys.
/// ⌥⌘↑/↓ walk the same list one row at a time either way, which is why the
/// default costs a keystroke rather than a capability.
@MainActor
enum SpaceKeys {
    /// The modifiers that pick a space by its row. The window's monitor and the
    /// hints the sidebar draws on its rows both read it from here: a row that
    /// names a key nothing answers is worse than a row that names none.
    ///
    /// ⌥⌘, the same modifier as the ⌥⌘↑/↓ that walk the same list one row at a
    /// time — spaces and tabs are ⌥⌘ throughout, and the splits below them are
    /// ⇧⌘.
    static let modifiers: NSEvent.ModifierFlags = [.command, .option]

    /// How far down the sidebar the keys reach. Nine, because there are nine
    /// digits worth having: ⌥⌘0 is not the tenth of anything.
    static let positions = 1...9

    static let didChangeNotification = Notification.Name("herdglass.space-keys-did-change")

    private static let key = "herdglass.space-keys-enabled"

    /// Off unless the user turns it on. Read straight from defaults rather than
    /// cached, so the settings window, the key monitor and the sidebar's hints
    /// all see the same answer.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set {
            guard newValue != isEnabled else { return }
            UserDefaults.standard.set(newValue, forKey: key)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    /// The key that selects the space in that position, spelled the way the menu
    /// spells its own — via `Shortcut.display`, so a hint and a menu item can
    /// never disagree about how a modifier is drawn.
    static func display(_ position: Int) -> String {
        GhosttyConfig.Shortcut(keyEquivalent: "\(position)", modifiers: modifiers).display
    }
}
