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
        NSWorkspace.shared.openExternally(URL(fileURLWithPath: value))
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
    // Its strings are copied here for the same reason, and the reason is worse:
    // they are freed rather than merely unowned. See `actionText(from:)`.
    let text = actionText(from: action)
    Task { @MainActor in
        switch target.tag {
        case GHOSTTY_TARGET_SURFACE:
            session?.handle(action, text: text)
        case GHOSTTY_TARGET_APP:
            host.handle(action)
        default:
            host.tick()
        }
    }
    return true
}

/// Text is the one representation this app serves. libghostty names every
/// text-like type the program asked for (OSC 52, a paste, a Kitty clipboard
/// read) by this one MIME type, so nothing else needs recognising.
private let clipboardTextMime = "text/plain"

private func terminalHostReadClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?,
    _ mimes: UnsafePointer<UnsafePointer<CChar>?>?,
    _ mimeCount: Int,
    _ listing: Bool
) -> ghostty_clipboard_read_result_e {
    guard location == GHOSTTY_CLIPBOARD_STANDARD else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
    guard let session = terminalSession(from: userdata) else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
    let wantsText = UnsafeBufferPointer(start: mimes, count: mimes == nil ? 0 : mimeCount)
        .contains { $0.map { String(cString: $0) } == clipboardTextMime }
    // A Kitty clipboard read for an image, say, has nothing to be served with.
    guard wantsText || listing else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
    let userPaste = wantsText && Thread.isMainThread && MainActor.assumeIsolated { session.isReadingClipboardForPaste }
    // A listing (a Kitty paste event) is answered even when it comes back
    // empty, so only a plain read can be turned away up front.
    if Thread.isMainThread, !listing {
        let available = MainActor.assumeIsolated {
            NSPasteboard.general.string(forType: .string) != nil
                || (userPaste && TerminalClipboard.hasImage(.general) && session.view?.onUpload != nil)
        }
        guard available else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
    }
    let request = ClipboardReadState(pointer: state)
    // Keep the session alive across the hop, just like the action callback.
    // Settle the libghostty request before starting a potentially long image
    // transfer; the uploaded path later enters through surface_text (a paste).
    Task { @MainActor in
        guard let surface = session.surface else { return }
        if userPaste, TerminalClipboard.hasImage(.general), session.view?.onUpload != nil {
            // A denied paste is one that does not happen, which frees the
            // request without pasting anything in front of the upload.
            ghostty_surface_deny_clipboard_request(surface, request.pointer)
            session.view?.pasteImage()
        } else {
            let text = NSPasteboard.general.string(forType: .string)
            completeClipboardRead(
                surface,
                text: wantsText ? text : nil,
                listsText: listing && text != nil,
                state: request.pointer
            )
        }
    }
    return GHOSTTY_CLIPBOARD_READ_STARTED
}

/// Opaque libghostty-owned state, carried to the main actor and consumed there.
private struct ClipboardReadState: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer?
}

/// Answers a read with the clipboard's text, if it asked for it, and with a
/// listing of what is on the clipboard, if it asked for that. libghostty only
/// borrows both for the length of the call.
@MainActor
private func completeClipboardRead(
    _ surface: ghostty_surface_t,
    text: String?,
    listsText: Bool,
    state: UnsafeMutableRawPointer?
) {
    clipboardTextMime.withCString { mime in
        (text ?? "").withCString { data in
            let contents = text.map { [ghostty_clipboard_content_s(mime: mime, data: data, len: $0.utf8.count)] } ?? []
            let available: [UnsafePointer<CChar>?] = listsText ? [mime] : []
            contents.withUnsafeBufferPointer { contents in
                available.withUnsafeBufferPointer { available in
                    var complete = ghostty_clipboard_complete_s(
                        contents: contents.baseAddress,
                        contents_len: contents.count,
                        available: available.baseAddress,
                        available_len: available.count,
                        confirmed: false,
                        remember: false
                    )
                    ghostty_surface_complete_clipboard_request(surface, &complete, state)
                }
            }
        }
    }
}

/// libghostty asks before anything its config wants confirmed: a paste
/// `clipboard-paste-protection` thinks is unsafe, or a program reading (or, by
/// the Kitty protocol, writing) the clipboard under `clipboard-read`/
/// `clipboard-write = ask`. This app has no prompt to show, so every such
/// request is denied — the paste does not happen, and a program waiting on a
/// read is told no rather than left waiting. libghostty holds the request until
/// it is either completed or denied, so doing nothing is not an option.
private func terminalHostConfirmReadClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
    _ state: UnsafeMutableRawPointer?,
    _ request: ghostty_clipboard_request_e
) {
    guard let session = terminalSession(from: userdata) else { return }
    let request = ClipboardReadState(pointer: state)
    Task { @MainActor in
        guard let surface = session.surface else { return }
        ghostty_surface_deny_clipboard_request(surface, request.pointer)
    }
}

private func terminalHostWriteClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ content: UnsafePointer<ghostty_clipboard_content_s>?,
    _ len: Int,
    _ confirm: Bool
) {
    guard location == GHOSTTY_CLIPBOARD_STANDARD else { return }
    guard let content, len > 0 else { return }
    // The data carries its own length and is not necessarily NUL-terminated.
    let joined = UnsafeBufferPointer(start: content, count: len).compactMap { item -> String? in
        guard
            let mime = item.mime,
            String(cString: mime) == clipboardTextMime,
            let value = item.data
        else { return nil }
        return String(decoding: UnsafeRawBufferPointer(start: value, count: item.len), as: UTF8.self)
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
