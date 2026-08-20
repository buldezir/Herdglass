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
    static let configDidChangeNotification = Notification.Name("HerdrTermGhosttyConfigDidChange")

    private static var timer: Timer?
    private static var attachedPanes = 0

    /// libghostty is initialized once, and deliberately not through
    /// `GhosttyTerminalHost.shared`: that convenience injects a theme of its own
    /// (see `loadedConfig`), and `ghostty_init` must not run twice.
    private static let terminalHost: GhosttyTerminalHost? = {
        guard let host = try? GhosttyTerminalHost(loadDefaultTheme: false) else { return nil }
        loadConfig(into: host)
        return host
    }()

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

    static var host: GhosttyTerminalHost? { terminalHost }

    static var unavailableReason: String? {
        host == nil ? "libghostty failed to initialize. Check `ghostty +show-config` for a bad config." : nil
    }

    /// Load `~/.config/ghostty/config` (and the Application Support copy) the
    /// way ghostty itself does, and make it the app's config.
    ///
    /// This app loads the config rather than letting GhosttyKit do it, because
    /// `GhosttyTerminalHost(loadDefaultTheme: true)` writes a Rosé Pine theme
    /// file into Application Support and loads it *after* the user's config
    /// whenever that config has no `theme =` line — which silently overrides
    /// `background`, `foreground`, `palette`, `background-opacity` and
    /// `background-blur` for everyone who set colours without naming a theme.
    /// Since the whole point is to look like the user's ghostty, we skip it and
    /// fall back to ghostty's own defaults instead.
    ///
    /// CLI args are deliberately not loaded: our argv is `--connect`/`--bridge`,
    /// not ghostty flags, and `ghostty_config_load_cli_args` would only collect
    /// diagnostics about them.
    @discardableResult
    private static func loadConfig(into host: GhosttyTerminalHost) -> Bool {
        guard let config = ghostty_config_new() else { return false }
        ghostty_config_load_default_files(config)
        ghostty_config_load_recursive_files(config)
        ghostty_config_finalize(config)

        if let app = host.app {
            ghostty_app_update_config(app, config)
        }
        let previous = loadedConfig
        loadedConfig = config
        snapshot = GhosttyConfig(config)
        if let previous {
            ghostty_config_free(previous)
        }
        return true
    }

    /// Point libghostty at the command a new surface should run.
    ///
    /// This has to go through the *app* config even though
    /// `ghostty_surface_config_s` has a `command` field, because libghostty
    /// ignores that field: a surface always runs the login shell, which is why
    /// the pane used to show a fresh local zsh instead of the Herdr pane. It is
    /// not an ABI mismatch — `working_directory`, the field right before it in
    /// the same struct, is honoured, and the pointer is non-null at the
    /// `ghostty_surface_new` call — and it is not version specific: both the
    /// pinned 0.8.0 libghostty and a rebuild from ghostty `54ac5fd21` drop it,
    /// along with `env_vars`. Hence `BridgeOptions.argv`: the pane has to ride
    /// on the command line, since the surface environment is dropped too.
    ///
    /// The clone is taken from the config we loaded, so the user's own
    /// `~/.config/ghostty/config` and theme survive. libghostty clones the
    /// config it is handed, so ours is freed straight away.
    @discardableResult
    static func useSurfaceCommand(_ argv: [String]) -> Bool {
        guard let host, let app = host.app, let base = loadedConfig, !argv.isEmpty else { return false }
        let command = argv.map(\.shellEscaped).joined(separator: " ")
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdr-term-command-\(ProcessInfo.processInfo.processIdentifier).ghostty")
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
    static func apply(to session: GhosttyTerminalSession) {
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

    /// Re-read the config. `GhosttyTerminalHost.reloadConfig` is not used: it
    /// would re-inject the theme described in `loadConfig(into:)`, and it keeps
    /// the result in a property we cannot reach.
    static func reloadConfig() {
        guard let host else { return }
        loadConfig(into: host)
        NotificationCenter.default.post(name: configDidChangeNotification, object: nil)
    }

    static func openConfig() {
        host?.openConfig()
    }
}
