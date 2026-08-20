import AppKit
import GhosttyKit
import HerdrClient

/// Owns libghostty's app tick. The tick only has work to do while a surface
/// exists, so it is reference counted by attached panes rather than left
/// running at 60 Hz for the lifetime of the process.
@MainActor
enum GhosttyRuntime {
    private static var timer: Timer?
    private static var attachedPanes = 0

    static var host: GhosttyTerminalHost? { GhosttyTerminalHost.shared }

    static var unavailableReason: String? {
        host == nil ? "libghostty failed to initialize. Check `ghostty +show-config` for a bad config." : nil
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
    /// The app config is cloned from whatever GhosttyKit loaded, so the user's
    /// own `~/.config/ghostty/config` and theme survive. libghostty clones the
    /// config it is handed, so ours is freed straight away.
    @discardableResult
    static func useSurfaceCommand(_ argv: [String]) -> Bool {
        guard let host, let app = host.app, let base = host.config, !argv.isEmpty else { return false }
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

    static func reloadConfig() {
        host?.reloadConfig()
    }

    static func openConfig() {
        host?.openConfig()
    }
}
