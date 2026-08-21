import AppKit
import GhosttyKit
import HerdrClient

/// Owns libghostty: the app handle, the config the whole app reads, and the
/// tick. The tick only has work to do while a surface exists, so it is
/// reference counted by attached panes rather than left running at 60 Hz for
/// the lifetime of the process.
@MainActor
enum GhosttyRuntime {
    /// Posted after the config has been (re)loaded, so the window chrome and
    /// the panes can re-read `GhosttyRuntime.config`.
    static let configDidChangeNotification = Notification.Name("HerdglassGhosttyConfigDidChange")

    private static var timer: Timer?
    private static var attachedPanes = 0

    /// libghostty is initialized once, in this order: the resources directory
    /// has to be in the environment before a theme is resolved, `ghostty_init`
    /// before any other libghostty call, and the config before the app, because
    /// `ghostty_app_new` reads it.
    private static let terminalHost: TerminalHost? = {
        exportResourcesDir()
        guard TerminalHost.initializeLibrary(), let config = newConfig() else { return nil }
        guard let host = try? TerminalHost(config: config) else {
            ghostty_config_free(config)
            return nil
        }
        loadedConfig = config
        snapshot = GhosttyConfig(config)
        return host
    }()

    /// `theme = <name>` is resolved against `<resources>/themes`, and libghostty
    /// finds `<resources>` from `GHOSTTY_RESOURCES_DIR`, or by climbing from its
    /// own executable to a bundle that ships ghostty's terminfo. This app is
    /// neither, so a named theme only resolves when the variable already happens
    /// to be in the environment — which is to say when the app was launched from
    /// a shell inside Ghostty, since ghostty exports it to every shell it
    /// spawns, and not when it was launched from Finder or the Dock.
    ///
    /// The difference is silent: an unresolved theme lands in the config's
    /// diagnostics, every other key is read as usual, and the terminal comes up
    /// in ghostty's own default palette — duller than most themes, which is what
    /// "the colours look washed out when I double-click it" is.
    ///
    /// So point the variable at the user's Ghostty install before libghostty
    /// loads anything, and both launches read the same themes. Nothing is
    /// exported when Ghostty is not installed: without a themes directory there
    /// is no theme to find, and an empty value would only stop libghostty from
    /// looking anywhere else.
    private static func exportResourcesDir() {
        func hasThemes(_ resources: String) -> Bool {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: resources + "/themes",
                isDirectory: &isDirectory
            )
            return exists && isDirectory.boolValue
        }

        if let current = ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"], hasThemes(current) {
            return
        }
        // LaunchServices first, so a Ghostty kept outside /Applications counts.
        let bundles: [String?] = [
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty")?.path,
            "/Applications/Ghostty.app",
            ("~/Applications/Ghostty.app" as NSString).expandingTildeInPath,
        ]
        for bundle in bundles.compactMap(\.self) {
            let resources = bundle + "/Contents/Resources/ghostty"
            guard hasThemes(resources) else { continue }
            setenv("GHOSTTY_RESOURCES_DIR", resources, 1)
            return
        }
    }

    /// The config libghostty is running with. Freed only after its replacement
    /// has been handed to the app, because `ghostty_app_update_config` clones.
    private static var loadedConfig: ghostty_config_t?

    private static var snapshot = GhosttyConfig()

    /// The settings this app honours, as of the last load. Reading it is what
    /// brings libghostty up, so the very first caller — the app delegate, before
    /// it has a window — still sees the user's real config rather than defaults.
    static var config: GhosttyConfig {
        _ = terminalHost
        return snapshot
    }

    static var host: TerminalHost? { terminalHost }

    static var unavailableReason: String? {
        host == nil ? "libghostty failed to initialize. Check `ghostty +show-config` for a bad config." : nil
    }

    /// Load `~/.config/ghostty/config` (and the Application Support copy) the
    /// way ghostty itself does. Nothing of this app's own is injected: no theme,
    /// no colours, no defaults that disagree with ghostty's — the whole point is
    /// to look like the user's ghostty, and anything added here would silently
    /// override `background`, `foreground` or `palette` for everyone who set
    /// colours without naming a theme.
    ///
    /// CLI args are deliberately not loaded: our argv is `--connect`/`--bridge`,
    /// not ghostty flags, and `ghostty_config_load_cli_args` would only collect
    /// diagnostics about them.
    private static func newConfig() -> ghostty_config_t? {
        guard let config = ghostty_config_new() else { return nil }
        ghostty_config_load_default_files(config)
        ghostty_config_load_recursive_files(config)
        ghostty_config_finalize(config)
        return config
    }

    /// Point libghostty at the command a new surface should run.
    ///
    /// This has to go through the *app* config even though
    /// `ghostty_surface_config_s` has a `command` field, because libghostty
    /// ignores that field: a surface always runs the login shell, which is why
    /// the pane used to show a fresh local zsh instead of the Herdr pane. It is
    /// not an ABI mismatch — `working_directory`, the field right before it in
    /// the same struct, is honoured, and the pointer is non-null at the
    /// `ghostty_surface_new` call — and it is not version specific: GhosttyKit
    /// 0.8.0's libghostty and every rebuild since, up to the commit pinned in
    /// `Vendor/libghostty.version`, all drop it along with `env_vars`. Hence
    /// `BridgeOptions.argv`: the pane has to ride on the command line, since the
    /// surface environment is dropped too.
    ///
    /// The clone is taken from the config we loaded, so the user's own
    /// `~/.config/ghostty/config` and theme survive. libghostty clones the
    /// config it is handed, so ours is freed straight away.
    @discardableResult
    static func useSurfaceCommand(_ argv: [String]) -> Bool {
        guard let host, let app = host.app, let base = loadedConfig, !argv.isEmpty else { return false }
        let command = argv.map(\.shellEscaped).joined(separator: " ")
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdglass-command-\(ProcessInfo.processInfo.processIdentifier).ghostty")
        // `shell:` is explicit rather than relying on the default, so a path
        // containing a colon can never be read as a `direct:`-style prefix.
        guard (try? "command = shell:\(command)\n".write(to: file, atomically: true, encoding: .utf8)) != nil,
              let config = ghostty_config_clone(base)
        else { return false }
        defer {
            ghostty_config_free(config)
            try? FileManager.default.removeItem(at: file)
        }
        // No `ghostty_config_finalize` afterwards: the clone is already
        // finalized, and loading a file is what parses and validates a key —
        // a rejected one lands in the config's diagnostics, which is the only
        // way libghostty reports it.
        let before = ghostty_config_diagnostics_count(config)
        file.path.withCString { path in
            ghostty_config_load_file(config, path)
        }
        guard ghostty_config_diagnostics_count(config) == before else { return false }
        ghostty_app_update_config(app, config)
        return true
    }

    /// Push the current config onto a surface that already exists. Called after
    /// a reload; a new surface gets it from the app config instead.
    static func apply(to session: TerminalSession) {
        guard let loadedConfig else { return }
        session.updateConfig(loadedConfig)
    }

    static func paneAttached() {
        attachedPanes += 1
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            MainActor.assumeIsolated { host?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    static func paneDetached() {
        attachedPanes = max(0, attachedPanes - 1)
        guard attachedPanes == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    /// Re-read the config and hand it to the app. The replaced config is freed
    /// only afterwards, because `ghostty_app_update_config` clones what it is
    /// given rather than taking it over.
    static func reloadConfig() {
        guard let host, let app = host.app, let config = newConfig() else { return }
        ghostty_app_update_config(app, config)
        let previous = loadedConfig
        loadedConfig = config
        snapshot = GhosttyConfig(config)
        if let previous {
            ghostty_config_free(previous)
        }
        // The panes push it onto their own surfaces from the notification, via
        // `apply(to:)` — only they know whether they still have one.
        NotificationCenter.default.post(name: configDidChangeNotification, object: nil)
    }

    static func openConfig() {
        host?.openConfig()
    }
}
