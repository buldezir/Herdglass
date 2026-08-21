import AppKit
import GhosttyKit

// Ported from GhosttyKit (MIT, https://github.com/briannadoubt/GhosttyKit) and
// trimmed to what this app uses: the config loading and the theme it injected
// are gone, because `GhosttyRuntime` owns the config (see its `loadConfig`), and
// so is everything that served a SwiftUI consumer.

/// libghostty's app handle: one per process, plus the callbacks libghostty calls
/// back into Swift with. `GhosttyRuntime` owns the config and the tick; this owns
/// the `ghostty_app_t` and the route from a surface back to its session.
@MainActor
final class TerminalHost {
    enum Failure: Error, LocalizedError {
        case initFailed
        case appCreationFailed

        var errorDescription: String? {
            switch self {
            case .initFailed: return "ghostty_init failed"
            case .appCreationFailed: return "ghostty_app_new failed"
            }
        }
    }

    /// Read from libghostty's own threads, which is why it is not actor isolated.
    nonisolated(unsafe) private(set) var app: ghostty_app_t?

    private var sessions: [ObjectIdentifier: WeakTerminalSession] = [:]
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    /// `ghostty_init` has to run before any other libghostty call, the config
    /// included, so it is separate from creating the app. Safe to call twice;
    /// only the first call reaches libghostty.
    static func initializeLibrary() -> Bool {
        if initialized { return true }
        initialized = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == 0
        return initialized
    }

    private nonisolated(unsafe) static var initialized = false

    /// The config stays owned by the caller: libghostty reads it here and again
    /// on every `ghostty_app_update_config`, so it has to outlive the app.
    init(config: ghostty_config_t) throws {
        guard Self.initializeLibrary() else { throw Failure.initFailed }

        var runtime = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: terminalHostWakeup,
            action_cb: terminalHostAction,
            read_clipboard_cb: terminalHostReadClipboard,
            confirm_read_clipboard_cb: terminalHostConfirmReadClipboard,
            write_clipboard_cb: terminalHostWriteClipboard,
            close_surface_cb: terminalHostCloseSurface
        )

        guard let app = ghostty_app_new(&runtime, config) else {
            throw Failure.appCreationFailed
        }
        self.app = app
        beginObservingApplicationFocus()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        if let app {
            ghostty_app_free(app)
        }
    }

    func makeSession(configuration: TerminalSession.Launch = TerminalSession.Launch()) -> TerminalSession {
        TerminalSession(host: self, configuration: configuration)
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    func register(_ session: TerminalSession) {
        sessions[ObjectIdentifier(session)] = WeakTerminalSession(value: session)
    }

    func unregister(_ session: TerminalSession) {
        sessions.removeValue(forKey: ObjectIdentifier(session))
    }

    /// Where the user's `~/.config/ghostty/config` lives, according to
    /// libghostty rather than to a guess of our own.
    func openConfig() {
        let path = ghostty_config_open_path()
        defer { ghostty_string_free(path) }
        guard let pointer = path.ptr, path.len > 0 else { return }
        let value = String(
            decoding: UnsafeBufferPointer(start: pointer, count: Int(path.len)).map(UInt8.init(bitPattern:)),
            as: UTF8.self
        )
        NSWorkspace.shared.open(URL(fileURLWithPath: value))
    }

    /// The sessions still alive, dropping any whose pane has gone.
    fileprivate func liveSessions() -> [TerminalSession] {
        sessions = sessions.filter { $0.value.value != nil }
        return sessions.values.compactMap(\.value)
    }

    private func beginObservingApplicationFocus() {
        guard observers.isEmpty else { return }
        let notificationCenter = NotificationCenter.default
        observers.append(
            notificationCenter.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.setAppFocused(true)
                }
            }
        )
        observers.append(
            notificationCenter.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.setAppFocused(false)
                }
            }
        )
        setAppFocused(NSApp?.isActive == true)
    }

    private func setAppFocused(_ focused: Bool) {
        guard let app else { return }
        ghostty_app_set_focus(app, focused)
    }
}

private struct WeakTerminalSession {
    weak var value: TerminalSession?
}

// MARK: - libghostty callbacks
//
// These run on libghostty's threads, so they only unwrap the userdata pointer
// and hop to the main actor.

private func terminalHostWakeup(_ userdata: UnsafeMutableRawPointer?) {
    guard let host = terminalHost(from: userdata) else { return }
    Task { @MainActor in
        host.tick()
    }
}

private func terminalHostAction(
    _ app: ghostty_app_t?,
    _ target: ghostty_target_s,
    _ action: ghostty_action_s
) -> Bool {
    guard let app, let host = terminalHost(from: ghostty_app_userdata(app)) else { return false }
    // The surface's session is resolved *here*, not inside the hop, and the
    // strong reference that produces is what keeps it alive until the action is
    // handled — the same shape as `terminalHostCloseSurface`.
    //
    // Resolving it inside the `Task` instead is a use-after-free, and closing a
    // tab is how you hit it: libghostty queues an action for a surface, the tab
    // closes, `TerminalSession.deinit` frees the surface, and the hop then runs
    // `Unmanaged.takeUnretainedValue()` on a session that is already gone and
    // writes to its `state`. `EXC_BAD_ACCESS` at a small address, in
    // `TerminalSession.handle`, one `surface closed` line later in libghostty's
    // log — intermittent, because it needs an action already in flight.
    let session = target.tag == GHOSTTY_TARGET_SURFACE
        ? terminalSession(for: target.target.surface)
        : nil
    Task { @MainActor in
        switch target.tag {
        case GHOSTTY_TARGET_SURFACE:
            session?.handle(action)
        case GHOSTTY_TARGET_APP:
            host.handle(action)
        default:
            host.tick()
        }
    }
    return true
}

private func terminalHostReadClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?
) -> Bool {
    guard location != GHOSTTY_CLIPBOARD_SELECTION else { return false }
    guard let session = terminalSession(from: userdata), let surface = session.surface else { return false }
    guard let text = NSPasteboard.general.string(forType: .string) else { return false }
    text.withCString { ptr in
        ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
    }
    return true
}

/// libghostty asks before pasting something that looks unsafe. This app pastes
/// what the user asked for and never prompts, which is also what the read above
/// does by passing `confirmed: false`.
private func terminalHostConfirmReadClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ string: UnsafePointer<CChar>?,
    _ state: UnsafeMutableRawPointer?,
    _ request: ghostty_clipboard_request_e
) {
}

private func terminalHostWriteClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ content: UnsafePointer<ghostty_clipboard_content_s>?,
    _ len: Int,
    _ confirm: Bool
) {
    guard location != GHOSTTY_CLIPBOARD_SELECTION else { return }
    guard let content, len > 0 else { return }
    let joined = UnsafeBufferPointer(start: content, count: len).compactMap { item -> String? in
        guard
            let mime = item.mime,
            String(cString: mime) == "text/plain",
            let value = item.data
        else { return nil }
        return String(cString: value)
    }.joined(separator: "\n")
    guard !joined.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(joined, forType: .string)
}

private func terminalHostCloseSurface(_ userdata: UnsafeMutableRawPointer?, _ processAlive: Bool) {
    guard let session = terminalSession(from: userdata) else { return }
    Task { @MainActor in
        session.handleCloseRequest(processAlive: processAlive)
    }
}

private func terminalHost(from pointer: UnsafeMutableRawPointer?) -> TerminalHost? {
    guard let pointer else { return nil }
    return Unmanaged<TerminalHost>.fromOpaque(pointer).takeUnretainedValue()
}

private func terminalSession(for surface: ghostty_surface_t?) -> TerminalSession? {
    guard let surface, let userdata = ghostty_surface_userdata(surface) else { return nil }
    return terminalSession(from: userdata)
}

private func terminalSession(from pointer: UnsafeMutableRawPointer?) -> TerminalSession? {
    guard let pointer else { return nil }
    return Unmanaged<TerminalSession>.fromOpaque(pointer).takeUnretainedValue()
}

@MainActor
private extension TerminalHost {
    /// App-targeted actions. Anything that would rearrange windows, tabs or
    /// splits is Herdr's to decide, so it is deliberately not handled here.
    func handle(_ action: ghostty_action_s) {
        switch action.tag {
        case GHOSTTY_ACTION_RENDER:
            for session in liveSessions() {
                session.requestRender()
            }
        case GHOSTTY_ACTION_OPEN_CONFIG:
            openConfig()
        case GHOSTTY_ACTION_RELOAD_CONFIG:
            GhosttyRuntime.reloadConfig()
        case GHOSTTY_ACTION_RING_BELL:
            NSSound.beep()
        default:
            break
        }
    }
}
