import AppKit
import GhosttyKit

/// The user's `ghostty` config, read for the settings this app can honour.
///
/// libghostty already reads `~/.config/ghostty/config` (and the macOS
/// Application Support copy) for the terminal surfaces themselves. This is the
/// other half: the keys that describe the *window* and the space around a
/// terminal, which a surface knows nothing about, plus the `keybind`s whose
/// actions this app can perform. Everything here is read into a snapshot at
/// load time, so nothing outside `GhosttyRuntime` ever holds a
/// `ghostty_config_t` — that pointer's lifetime belongs to libghostty.
///
/// Not everything in a ghostty config has a meaning here, and a few things that
/// do are unreachable:
///
/// - `mouse-scroll-multiplier` is a plain Zig struct with no `cval`, so
///   `ghostty_config_get` refuses it. Our own wheel handler therefore keeps its
///   three-lines-per-notch default. Same for `theme` itself.
/// - `quit-after-last-window-closed` is readable, but ghostty's macOS default is
///   *false* while this app has always terminated with its last window, and the
///   C API cannot tell a default apart from a value the user typed. Honouring it
///   would silently change behaviour for everyone who never set it.
/// - `window-decoration`, font and padding keys, and anything about scrollback
///   belong to libghostty or to the Herdr server, not to the chrome.
struct GhosttyConfig {
    /// `window-theme`. `auto` follows the terminal background, per ghostty's own
    /// docs; `ghostty` is Linux-only upstream, so it lands on `auto` here.
    enum WindowTheme: String {
        case auto, system, light, dark, ghostty
    }

    /// `macos-titlebar-style`. `tabs` has no meaning here — the tab strip is
    /// Herdr's, not AppKit's — so it reads as `transparent`, which is the half
    /// of `tabs` that is about colour.
    enum TitlebarStyle: String {
        case native, transparent, tabs, hidden
    }

    /// `window-save-state`.
    enum SaveState: String {
        case `default`, never, always
    }

    /// `confirm-close-surface`. `always` asks even for a lone idle pane.
    enum ConfirmClose: String {
        case never = "false"
        case unlessTrivial = "true"
        case always
    }

    /// A `keybind` trigger, in the form `NSMenuItem` wants it.
    struct Shortcut: Equatable {
        var keyEquivalent: String
        var modifiers: NSEvent.ModifierFlags

        /// `⇧⌘D`, for a tooltip or a placeholder that has to name the key.
        var display: String {
            var text = ""
            if modifiers.contains(.control) { text += "⌃" }
            if modifiers.contains(.option) { text += "⌥" }
            if modifiers.contains(.shift) { text += "⇧" }
            if modifiers.contains(.command) { text += "⌘" }
            return text + Self.symbol(keyEquivalent)
        }

        private static func symbol(_ keyEquivalent: String) -> String {
            switch keyEquivalent {
            case "\u{F700}": return "↑"
            case "\u{F701}": return "↓"
            case "\u{F702}": return "←"
            case "\u{F703}": return "→"
            case "\r": return "↩"
            case "\t": return "⇥"
            case "\u{8}": return "⌫"
            case "\u{7F}": return "⌦"
            case "\u{1B}": return "⎋"
            case " ": return "␣"
            default: return keyEquivalent.uppercased()
            }
        }
    }

    /// The ghostty actions this app can carry out, spelled the way `keybind`
    /// spells them, so a rebind in the user's config moves our menu item too.
    /// Anything ghostty can do that Herdr owns instead (zoom, resize_split,
    /// font size, the command palette) is deliberately absent.
    enum Action: String, CaseIterable {
        case newWindow = "new_window"
        case newTab = "new_tab"
        /// `close_surface` is ghostty's "close what is in front of me", and it
        /// is the app's Close: the focused pane when the tab is split, the tab
        /// itself when it is not. `close_tab` closes the whole tab either way,
        /// which is why both exist here and why ⌘W lands on the first of them,
        /// exactly as it does in ghostty.
        case closeSurface = "close_surface"
        case closeTab = "close_tab"
        case closeWindow = "close_window"
        case closeAllWindows = "close_all_windows"
        case quit
        case reloadConfig = "reload_config"
        case openConfig = "open_config"
        case splitRight = "new_split:right"
        case splitDown = "new_split:down"
        case focusSplitLeft = "goto_split:left"
        case focusSplitRight = "goto_split:right"
        case focusSplitUp = "goto_split:up"
        case focusSplitDown = "goto_split:down"
        case nextTab = "next_tab"
        case previousTab = "previous_tab"
        case toggleFullscreen = "toggle_fullscreen"
        case copy = "copy_to_clipboard"
        case paste = "paste_from_clipboard"
        case selectAll = "select_all"
    }

    var background = NSColor(srgbRed: 0x28 / 255, green: 0x2C / 255, blue: 0x34 / 255, alpha: 1)
    var foreground = NSColor.white
    /// 0…1. Anything below 1 needs a non-opaque window to be visible at all.
    var backgroundOpacity: Double = 1
    /// libghostty's encoding: 0 off, a positive radius, or -1/-2 for the macOS
    /// glass materials. We only distinguish "blurred" from "not".
    var backgroundBlur: Int = 0
    /// Alpha of the scrim drawn over a split's unfocused panes, i.e.
    /// `1 - unfocused-split-opacity`.
    var unfocusedSplitDim: Double = 0
    /// `unfocused-split-fill`, defaulting to the background like ghostty does.
    var unfocusedSplitFill: NSColor?
    /// `split-divider-color`; nil means "derive it from the background".
    var splitDividerColor: NSColor?
    var windowTheme: WindowTheme = .auto
    var titlebarStyle: TitlebarStyle = .transparent
    var windowButtonsVisible = true
    var windowShadow = true
    var title: String?
    var saveState: SaveState = .default
    var confirmClose: ConfirmClose = .unlessTrivial
    var focusFollowsMouse = false
    /// True when the config asks for separate light and dark themes, i.e.
    /// `theme = light:…,dark:…`.
    ///
    /// libghostty picks between the two through its *conditional* config state,
    /// which has no C API — `ghostty_config_get` always answers from the default
    /// state, which is `light`. So with a pair, `background` and `foreground` are
    /// the light half no matter which one the terminal is actually drawing, and
    /// this flag is how everything downstream knows not to trust them.
    ///
    /// The *appearance* does not need it: `Config.finalize` in ghostty already
    /// rewrites `window-theme = auto` to `system` when the theme is a pair, so
    /// that case arrives correct. This covers the palette, and the config that
    /// spelled `window-theme = system` out by hand.
    var hasLightDarkTheme = false
    private var shortcuts: [Action: Shortcut] = [:]

    /// The key equivalent the user's config gives this action, if any.
    func shortcut(_ action: Action) -> Shortcut? {
        shortcuts[action]
    }

    /// `goto_tab:1`…`goto_tab:9`, keyed by shortcut, so the ⌘1…⌘9 monitor can
    /// look an event up instead of assuming ⌘digit.
    private(set) var tabShortcuts: [Shortcut: UInt] = [:]

    /// The colour to paint behind a terminal, and the colour to write on it.
    ///
    /// These fall back to AppKit's semantic colours when `hasLightDarkTheme`
    /// says the palette we read is only one half of the answer: a system colour
    /// tracks the same light/dark signal the terminal is following, where the
    /// light half of a pair would put a pale surround on a dark terminal.
    var terminalBackground: NSColor {
        hasLightDarkTheme ? .controlBackgroundColor : background
    }

    var terminalForeground: NSColor {
        hasLightDarkTheme ? .labelColor : foreground
    }

    /// Divider colour for a split: what the config says, or ghostty's own
    /// derivation from the background when it says nothing.
    var effectiveSplitDividerColor: NSColor {
        if let splitDividerColor { return splitDividerColor }
        if hasLightDarkTheme { return .separatorColor }
        return background.darkened(by: background.isLight ? 0.08 : 0.4)
    }

    /// Appearance to force on the app, or nil to follow the system.
    ///
    /// `auto` is ghostty's default and means "match the window to the terminal
    /// background", which is why a ghostty window is dark on a light desktop.
    var appearance: NSAppearance? {
        switch windowTheme {
        case .system:
            return nil
        case .light:
            return NSAppearance(named: .aqua)
        case .dark:
            return NSAppearance(named: .darkAqua)
        case .auto, .ghostty:
            // ghostty's own rule, which its `finalize` normally applies for us:
            // with separate light and dark themes there is no single background
            // to match, so `auto` becomes `system`.
            guard !hasLightDarkTheme else { return nil }
            return NSAppearance(named: background.isLight ? .aqua : .darkAqua)
        }
    }

    /// True when the terminal is meant to show the desktop through it.
    var isTranslucent: Bool {
        backgroundOpacity < 1 || backgroundBlur != 0
    }

    /// What to paint behind a terminal: the terminal's own background, carrying
    /// `background-opacity` so a translucent window really is translucent all
    /// the way down rather than only where libghostty draws.
    var paneBackground: NSColor {
        terminalBackground.withAlphaComponent(CGFloat(backgroundOpacity))
    }

    init() {}

    /// Reads every key we honour out of a finalized `ghostty_config_t`.
    init(_ config: ghostty_config_t) {
        background = Self.color(config, "background") ?? background
        foreground = Self.color(config, "foreground") ?? foreground
        backgroundOpacity = min(max(Self.double(config, "background-opacity") ?? 1, 0), 1)
        backgroundBlur = Int(Self.short(config, "background-blur") ?? 0)
        // ghostty stores the opacity of the unfocused pane; we draw the scrim
        // that produces it, so this is its complement.
        let splitOpacity = min(max(Self.double(config, "unfocused-split-opacity") ?? 1, 0), 1)
        unfocusedSplitDim = 1 - splitOpacity
        unfocusedSplitFill = Self.color(config, "unfocused-split-fill")
        splitDividerColor = Self.color(config, "split-divider-color")
        windowTheme = Self.value(config, "window-theme", WindowTheme.self) ?? .auto
        titlebarStyle = Self.value(config, "macos-titlebar-style", TitlebarStyle.self) ?? .transparent
        windowButtonsVisible = Self.string(config, "macos-window-buttons") != "hidden"
        windowShadow = Self.bool(config, "macos-window-shadow") ?? true
        title = Self.string(config, "title")
        saveState = Self.value(config, "window-save-state", SaveState.self) ?? .default
        confirmClose = Self.value(config, "confirm-close-surface", ConfirmClose.self) ?? .unlessTrivial
        focusFollowsMouse = Self.bool(config, "focus-follows-mouse") ?? false
        hasLightDarkTheme = Self.declaresLightDarkTheme()

        for action in Action.allCases {
            guard let shortcut = Self.shortcut(config, action.rawValue) else { continue }
            shortcuts[action] = shortcut
        }
        for number in UInt(1)...9 {
            guard let shortcut = Self.shortcut(config, "goto_tab:\(number)") else { continue }
            // First binding wins, so a config that points two keys at one tab
            // cannot make the later one shadow a different tab's key.
            if tabShortcuts[shortcut] == nil { tabShortcuts[shortcut] = number }
        }
    }

    // MARK: - Typed reads
    //
    // `ghostty_config_get` writes through a `void*` whose type is decided by the
    // config field, so each of these has to match libghostty's own mapping
    // (`src/config/c_get.zig`): bool, `c_uint`, `c_short`, `f64`, a colour
    // struct, and `const char*` for both strings and enum tags. It returns false
    // for a key the C API does not expose, and for an optional that is unset —
    // which is how `split-divider-color` says "derive one".

    private static func bool(_ config: ghostty_config_t, _ key: String) -> Bool? {
        var value = false
        return ghostty_config_get(config, &value, key, UInt(key.utf8.count)) ? value : nil
    }

    private static func double(_ config: ghostty_config_t, _ key: String) -> Double? {
        var value: Double = 0
        return ghostty_config_get(config, &value, key, UInt(key.utf8.count)) ? value : nil
    }

    private static func short(_ config: ghostty_config_t, _ key: String) -> Int16? {
        var value: Int16 = 0
        return ghostty_config_get(config, &value, key, UInt(key.utf8.count)) ? value : nil
    }

    /// Strings and enum tags arrive the same way: a pointer libghostty owns.
    private static func string(_ config: ghostty_config_t, _ key: String) -> String? {
        var value: UnsafePointer<CChar>?
        guard ghostty_config_get(config, &value, key, UInt(key.utf8.count)), let value else { return nil }
        let string = String(cString: value)
        return string.isEmpty ? nil : string
    }

    private static func value<T: RawRepresentable>(
        _ config: ghostty_config_t,
        _ key: String,
        _ type: T.Type
    ) -> T? where T.RawValue == String {
        string(config, key).flatMap(T.init(rawValue:))
    }

    /// `theme` is a plain Zig struct, so `ghostty_config_get` refuses it and the
    /// pair has to be spotted in the text of the config instead — the same
    /// `theme` line, and the same comma/colon/equals test, that ghostty uses to
    /// decide it is parsing a pair.
    ///
    /// Only ghostty's own default locations are read. A pair reached through a
    /// `config-file` include is missed, because `config-file` is not readable
    /// through the C API either; that lands back on treating the light half as
    /// the whole palette, which is what happens without this check at all.
    private static func declaresLightDarkTheme() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".config")
        let paths = [
            xdg.appendingPathComponent("ghostty/config"),
            home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty/config"),
        ]
        return paths.contains { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return text.split(whereSeparator: \.isNewline).contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("theme") else { return false }
                let rest = trimmed.dropFirst("theme".count).trimmingCharacters(in: .whitespaces)
                guard rest.hasPrefix("=") else { return false }
                let value = rest.dropFirst()
                return value.contains(",") || value.contains(":") || value.contains("=")
            }
        }
    }

    private static func color(_ config: ghostty_config_t, _ key: String) -> NSColor? {
        var value = ghostty_config_color_s()
        guard ghostty_config_get(config, &value, key, UInt(key.utf8.count)) else { return nil }
        return NSColor(
            srgbRed: CGFloat(value.r) / 255,
            green: CGFloat(value.g) / 255,
            blue: CGFloat(value.b) / 255,
            alpha: 1
        )
    }

    /// An unbound action comes back as a zeroed trigger, which is a physical
    /// `unidentified` key — the one value that can never be a shortcut.
    ///
    /// A trigger with no ⌘/⌃/⌥ is dropped as well. A menu key equivalent is
    /// checked before the terminal ever sees the keystroke, so honouring a bare
    /// `keybind = a=…` would stop the user typing that letter; libghostty
    /// handles those itself, inside the surface, where they belong.
    private static func shortcut(_ config: ghostty_config_t, _ action: String) -> Shortcut? {
        let trigger = ghostty_config_trigger(config, action, UInt(action.utf8.count))
        let modifiers = self.modifiers(trigger.mods)
        guard !modifiers.intersection([.command, .control, .option]).isEmpty else { return nil }

        let key: String
        switch trigger.tag {
        case GHOSTTY_TRIGGER_PHYSICAL:
            guard let equivalent = physicalKeys[trigger.key.physical] else { return nil }
            key = equivalent
        case GHOSTTY_TRIGGER_UNICODE:
            guard
                let scalar = UnicodeScalar(trigger.key.unicode),
                let lowered = Character(scalar).lowercased().first
            else { return nil }
            key = String(lowered)
        default:
            // catch_all matches every key, and cannot be one shortcut.
            return nil
        }
        return Shortcut(keyEquivalent: key, modifiers: modifiers)
    }

    private static func modifiers(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags()
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        return flags
    }

    /// Only the layout-independent keys can become a key equivalent; everything
    /// else in ghostty's physical-key enum depends on the keyboard layout, which
    /// an `NSMenuItem` shortcut does not.
    private static let physicalKeys: [ghostty_input_key_e: String] = [
        GHOSTTY_KEY_ARROW_UP: "\u{F700}",
        GHOSTTY_KEY_ARROW_DOWN: "\u{F701}",
        GHOSTTY_KEY_ARROW_LEFT: "\u{F702}",
        GHOSTTY_KEY_ARROW_RIGHT: "\u{F703}",
        GHOSTTY_KEY_HOME: "\u{F729}",
        GHOSTTY_KEY_END: "\u{F72B}",
        GHOSTTY_KEY_PAGE_UP: "\u{F72C}",
        GHOSTTY_KEY_PAGE_DOWN: "\u{F72D}",
        GHOSTTY_KEY_DELETE: "\u{7F}",
        GHOSTTY_KEY_BACKSPACE: "\u{8}",
        GHOSTTY_KEY_ESCAPE: "\u{1B}",
        GHOSTTY_KEY_ENTER: "\r",
        GHOSTTY_KEY_TAB: "\t",
        GHOSTTY_KEY_SPACE: " ",
    ]
}

extension GhosttyConfig.Shortcut: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(keyEquivalent)
        hasher.combine(modifiers.rawValue)
    }
}

extension NSColor {
    /// Same split as ghostty uses to decide whether a background reads as light.
    var isLight: Bool {
        guard let rgb = usingColorSpace(.sRGB) else { return false }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (0.299 * r) + (0.587 * g) + (0.114 * b) > 0.5
    }

    func darkened(by amount: CGFloat) -> NSColor {
        guard let rgb = usingColorSpace(.sRGB) else { return self }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: s, brightness: min(b * (1 - amount), 1), alpha: a)
    }
}

extension GhosttyConfig {
    /// What the app took from the ghostty config, for `--show-ghostty-config`.
    /// The counterpart to `ghostty +show-config`: that lists what ghostty read,
    /// this lists the subset herdr-term acts on.
    var summary: String {
        var lines: [String] = []
        func row(_ key: String, _ value: String) {
            lines.append("  \(key.padding(toLength: 28, withPad: " ", startingAt: 0)) \(value)")
        }
        lines.append("terminal area")
        row("theme", hasLightDarkTheme ? "light/dark pair — palette left to the system" : "single")
        row("background", hasLightDarkTheme ? "\(background.hexString) (light half, unused)" : background.hexString)
        row("foreground", hasLightDarkTheme ? "\(foreground.hexString) (light half, unused)" : foreground.hexString)
        row("background-opacity", String(format: "%.2f", backgroundOpacity))
        row("background-blur", backgroundBlur == 0 ? "off" : "\(backgroundBlur)")
        row("split-divider-color", splitDividerColor?.hexString ?? "\(effectiveSplitDividerColor.hexString) (derived)")
        row("unfocused-split-opacity", String(format: "%.2f", 1 - unfocusedSplitDim))
        row("unfocused-split-fill", unfocusedSplitFill?.hexString ?? "\(terminalBackground.hexString) (background)")
        lines.append("window")
        row("window-theme", "\(windowTheme.rawValue) → \(appearance?.name.rawValue ?? "system")")
        row("macos-titlebar-style", titlebarStyle.rawValue)
        row("macos-window-buttons", windowButtonsVisible ? "visible" : "hidden")
        row("macos-window-shadow", "\(windowShadow)")
        row("window-save-state", saveState.rawValue)
        row("title", title ?? "(from the selected pane)")
        lines.append("behaviour")
        row("confirm-close-surface", confirmClose.rawValue)
        row("focus-follows-mouse", "\(focusFollowsMouse)")
        lines.append("ghostty install")
        // Not a config key: where a named `theme` is looked up, which is the one
        // thing that changes with how the app was launched.
        row(
            "resources",
            ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"]
                ?? "(no Ghostty install found — a named theme cannot resolve)"
        )
        lines.append("keybind")
        for action in Action.allCases {
            row(action.rawValue, shortcut(action)?.display ?? "(unbound here)")
        }
        for (shortcut, number) in tabShortcuts.sorted(by: { $0.value < $1.value }) {
            row("goto_tab:\(number)", shortcut.display)
        }
        return lines.joined(separator: "\n")
    }
}

private extension NSColor {
    var hexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "?" }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02x%02x%02x", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}
