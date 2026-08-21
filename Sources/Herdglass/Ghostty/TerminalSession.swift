import AppKit
import Carbon
import GhosttyKit

// Ported from GhosttyKit (MIT, https://github.com/briannadoubt/GhosttyKit).
// The handler struct it used to hand a consumer is gone: the view is ours too,
// so it calls this directly and offers the two hooks `TerminalPaneView` needs.

/// One libghostty surface, and everything that has to be told about it: size,
/// scale, focus, occlusion, keys, mouse, clipboard and config.
@MainActor
final class TerminalSession {
    /// What a surface should run and what it should run it with. libghostty
    /// ignores `command` and `environment` (see `GhosttyRuntime.useSurfaceCommand`),
    /// but they stay filled in so the struct describes the intent.
    struct Launch: Sendable {
        var command: String?
        var workingDirectory: String?
        var environment: [String: String] = [:]
        var fontSize: Float = 0
    }

    /// The parts of the terminal's state this app reads back.
    @MainActor
    final class State {
        fileprivate(set) var title: String?
        fileprivate(set) var hoveredLinkURL: String?
        fileprivate(set) var isMouseHidden = false
        /// The cell in pixels, which is how a wheel delta becomes a line count.
        fileprivate(set) var cellSize: (width: Int, height: Int)?
    }

    let host: TerminalHost
    let state = State()
    private(set) var configuration: Launch
    /// Read from libghostty's own threads, which is why it is not actor isolated.
    nonisolated(unsafe) private(set) var surface: ghostty_surface_t?
    weak var view: TerminalSurfaceView?
    /// The surface's process went away. `processAlive` is true when libghostty is
    /// asking to close rather than reporting a child that already exited.
    var closeHandler: ((Bool) -> Void)?
    nonisolated(unsafe) private var secureEventInputEnabled = false

    init(host: TerminalHost, configuration: Launch = Launch()) {
        self.host = host
        self.configuration = configuration
        host.register(self)
    }

    deinit {
        if secureEventInputEnabled {
            DisableSecureEventInput()
        }
        if let surface {
            ghostty_surface_free(surface)
        }
    }

    /// Creates the surface the first time, then re-syncs everything that depends
    /// on where the view ended up. Called again after the view is laid out, which
    /// is why it has to be idempotent.
    func attach(to view: TerminalSurfaceView) {
        self.view = view
        if surface == nil {
            createSurface(in: view)
        }
        updateContentScale()
        resize(to: view.bounds.size)
        setDisplayID(displayID(of: view))
        setFocused(view.window?.firstResponder === view)
        applyColorScheme(appearance: view.effectiveAppearance)
    }

    func resize(to size: CGSize) {
        guard let surface else { return }
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        ghostty_surface_set_size(surface, UInt32(ceil(size.width * scale)), UInt32(ceil(size.height * scale)))
        ghostty_surface_refresh(surface)
    }

    func updateContentScale() {
        guard let surface else { return }
        let scale = Double(scale)
        guard scale.isFinite, scale > 0 else { return }
        ghostty_surface_set_content_scale(surface, scale, scale)
    }

    func render() {
        guard let surface else { return }
        ghostty_surface_draw(surface)
    }

    /// Renders through the view when there is one, so a burst of requests
    /// collapses into one draw per pass.
    func requestRender() {
        if let view {
            view.requestRender()
        } else {
            render()
        }
    }

    func setFocused(_ focused: Bool) {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, focused)
    }

    func setOccluded(_ occluded: Bool) {
        guard let surface else { return }
        ghostty_surface_set_occlusion(surface, !occluded)
    }

    func setDisplayID(_ displayID: CGDirectDisplayID?) {
        guard let surface, let displayID else { return }
        ghostty_surface_set_display_id(surface, displayID)
    }

    func keyboardLayoutChanged() {
        guard let app = host.app else { return }
        ghostty_app_keyboard_changed(app)
    }

    func sendKeyDown(_ event: NSEvent, text: String?) {
        sendKeyEvent(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS, text: text)
        ghostty_surface_refresh(surface)
    }

    func sendKeyUp(_ event: NSEvent) {
        sendKeyEvent(event, action: GHOSTTY_ACTION_RELEASE, text: nil)
        ghostty_surface_refresh(surface)
    }

    func insertText(_ text: String) {
        guard let surface, !text.isEmpty else { return }
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
        }
        ghostty_surface_refresh(surface)
    }

    /// The in-progress text of an input method. `nil` clears it.
    func setMarkedText(_ text: String?) {
        guard let surface else { return }
        guard let text else {
            ghostty_surface_preedit(surface, nil, 0)
            ghostty_surface_refresh(surface)
            return
        }
        text.withCString { ptr in
            ghostty_surface_preedit(surface, ptr, UInt(text.utf8.count))
        }
        ghostty_surface_refresh(surface)
    }

    /// True when libghostty consumed the click, i.e. the program in the pane
    /// wanted it. A false means the view can offer its own context menu.
    @discardableResult
    func sendMouseButton(_ button: TerminalSurfaceView.MouseButton, pressed: Bool, event: NSEvent) -> Bool {
        guard let surface else { return false }
        let state: ghostty_input_mouse_state_e = pressed ? GHOSTTY_MOUSE_PRESS : GHOSTTY_MOUSE_RELEASE
        return ghostty_surface_mouse_button(surface, state, translate(button), translate(event.modifierFlags))
    }

    func sendMousePosition(_ event: NSEvent) {
        guard let surface, let view else { return }
        let position = view.convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(
            surface,
            position.x,
            view.bounds.height - position.y,
            translate(event.modifierFlags)
        )
    }

    func sendMouseExit(modifiers: NSEvent.ModifierFlags) {
        guard let surface else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, translate(modifiers))
    }

    func sendScrollWheel(_ event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY, translateScrollModifiers(event))
    }

    func copySelection() -> String? {
        guard let surface else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(cString: text.text)
    }

    func hasSelection() -> Bool {
        guard let surface else { return false }
        return ghostty_surface_has_selection(surface)
    }

    func paste(_ text: String) {
        insertText(text)
    }

    func openHoveredLink() {
        guard let url = state.hoveredLinkURL, let value = URL(string: url) else { return }
        NSWorkspace.shared.open(value)
    }

    /// Runs one of libghostty's own keybind actions by name, e.g. `select_all`.
    @discardableResult
    func perform(action: String) -> Bool {
        guard let surface else { return false }
        return action.withCString { ptr in
            ghostty_surface_binding_action(surface, ptr, UInt(action.utf8.count))
        }
    }

    func applyColorScheme(appearance: NSAppearance? = nil) {
        guard let surface, let scheme = colorScheme(for: appearance ?? view?.effectiveAppearance) else { return }
        ghostty_surface_set_color_scheme(surface, scheme)
        ghostty_surface_refresh(surface)
    }

    /// Push a reloaded config onto a surface that already exists. A new surface
    /// picks it up from the app config instead.
    func updateConfig(_ config: ghostty_config_t) {
        guard let surface else { return }
        ghostty_surface_update_config(surface, config)
        applyColorScheme(appearance: view?.effectiveAppearance)
    }

    /// Surface-targeted actions. The window, tab and split ones are Herdr's to
    /// decide — this app draws what the server reports — so they are dropped
    /// rather than handled.
    func handle(_ action: ghostty_action_s) {
        switch action.tag {
        case GHOSTTY_ACTION_RENDER:
            requestRender()
        case GHOSTTY_ACTION_SET_TITLE:
            state.title = string(from: action.action.set_title.title)
        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            state.hoveredLinkURL = string(
                from: action.action.mouse_over_link.url,
                length: Int(action.action.mouse_over_link.len)
            )
        case GHOSTTY_ACTION_OPEN_URL:
            if let url = string(from: action.action.open_url.url, length: Int(action.action.open_url.len)),
               let value = URL(string: url) {
                NSWorkspace.shared.open(value)
            }
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            view?.applyCursor(for: action.action.mouse_shape)
        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            let hidden = action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN
            state.isMouseHidden = hidden
            view?.setCursorHidden(hidden)
        case GHOSTTY_ACTION_CELL_SIZE:
            state.cellSize = (
                width: Int(action.action.cell_size.width),
                height: Int(action.action.cell_size.height)
            )
        case GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD:
            let title = state.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let title, !title.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(title, forType: .string)
            }
        case GHOSTTY_ACTION_RING_BELL:
            NSSound.beep()
        case GHOSTTY_ACTION_OPEN_CONFIG:
            host.openConfig()
        case GHOSTTY_ACTION_RELOAD_CONFIG:
            GhosttyRuntime.reloadConfig()
        case GHOSTTY_ACTION_SECURE_INPUT:
            // A password prompt in the pane asks for this, and it is the only way
            // to stop other processes seeing the keystrokes.
            switch action.action.secure_input {
            case GHOSTTY_SECURE_INPUT_ON:
                guard !secureEventInputEnabled else { break }
                EnableSecureEventInput()
                secureEventInputEnabled = true
            case GHOSTTY_SECURE_INPUT_OFF:
                guard secureEventInputEnabled else { break }
                DisableSecureEventInput()
                secureEventInputEnabled = false
            default:
                break
            }
        default:
            break
        }
    }

    func handleCloseRequest(processAlive: Bool) {
        closeHandler?(processAlive)
    }

    /// The scale to report to libghostty. The window's own is the truthful one;
    /// the fallbacks only matter while the view is between windows.
    private var scale: CGFloat {
        view?.window?.backingScaleFactor
            ?? view?.window?.screen?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
    }

    /// `ghostty_surface_new` returns null rather than throwing: libghostty builds
    /// a `CVDisplayLink` from the view's screen, so a view that is not on one yet
    /// (a locked screen counts) cannot have a surface. Callers check `surface`.
    private func createSurface(in view: NSView) {
        guard let app = host.app else { return }
        if let scheme = colorScheme(for: view.effectiveAppearance) {
            ghostty_app_set_color_scheme(app, scheme)
        }

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(view).toOpaque()))
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(scale)
        config.font_size = configuration.fontSize
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        configuration.workingDirectory.withOptionalCString { workingDirectory in
            config.working_directory = workingDirectory
            configuration.command.withOptionalCString { command in
                config.command = command
                surface = withEnvironmentVariables(configuration.environment, config: config) { configured in
                    var configured = configured
                    return ghostty_surface_new(app, &configured)
                }
            }
        }

        if let surface, let scheme = colorScheme(for: view.effectiveAppearance) {
            ghostty_surface_set_color_scheme(surface, scheme)
        }
    }

    /// The two AppKit text commands libghostty has bindings for. Everything else
    /// the view suppresses or passes on.
    func performCommand(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveToBeginningOfDocument(_:)):
            return perform(action: "scroll_to_top")
        case #selector(NSResponder.moveToEndOfDocument(_:)):
            return perform(action: "scroll_to_bottom")
        default:
            return false
        }
    }

    private func sendKeyEvent(_ event: NSEvent, action: ghostty_input_action_e, text: String?) {
        guard let surface else { return }
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode)
        key.mods = translate(event.modifierFlags)
        key.consumed_mods = ghostty_surface_key_translation_mods(surface, key.mods)
        key.composing = false
        key.unshifted_codepoint = event.charactersIgnoringModifiers?.unicodeScalars.first?.value ?? 0

        if let text, !text.isEmpty {
            text.withCString { ptr in
                key.text = ptr
                _ = ghostty_surface_key(surface, key)
            }
        } else {
            key.text = nil
            _ = ghostty_surface_key(surface, key)
        }
    }

    /// Borrows every key and value as a C string for the duration of `body`,
    /// since `ghostty_surface_config_s` only holds pointers.
    private func withEnvironmentVariables<T>(
        _ variables: [String: String],
        config: ghostty_surface_config_s,
        body: (ghostty_surface_config_s) -> T
    ) -> T {
        let keys = Array(variables.keys)
        let values = keys.map { variables[$0] ?? "" }
        return keys.withCStrings { keyPointers in
            values.withCStrings { valuePointers in
                var envVars: [ghostty_env_var_s] = []
                envVars.reserveCapacity(keys.count)
                for index in keys.indices {
                    envVars.append(.init(key: keyPointers[index], value: valuePointers[index]))
                }
                let envVarCount = envVars.count
                return envVars.withUnsafeMutableBufferPointer { buffer in
                    var configured = config
                    configured.env_vars = buffer.baseAddress
                    configured.env_var_count = envVarCount
                    return body(configured)
                }
            }
        }
    }

    private func displayID(of view: NSView) -> CGDirectDisplayID? {
        guard let screenNumber = view.window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(screenNumber.uint32Value)
    }

    private func colorScheme(for appearance: NSAppearance?) -> ghostty_color_scheme_e? {
        let match = (appearance ?? NSApp?.effectiveAppearance ?? NSAppearance(named: .aqua))?
            .bestMatch(from: [.darkAqua, .aqua])
        return match == .darkAqua ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
    }

    private func translate(_ button: TerminalSurfaceView.MouseButton) -> ghostty_input_mouse_button_e {
        switch button {
        case .left: return GHOSTTY_MOUSE_LEFT
        case .right: return GHOSTTY_MOUSE_RIGHT
        case .other(let number):
            switch number {
            case 2: return GHOSTTY_MOUSE_MIDDLE
            case 3: return GHOSTTY_MOUSE_FOUR
            case 4: return GHOSTTY_MOUSE_FIVE
            case 5: return GHOSTTY_MOUSE_SIX
            case 6: return GHOSTTY_MOUSE_SEVEN
            case 7: return GHOSTTY_MOUSE_EIGHT
            case 8: return GHOSTTY_MOUSE_NINE
            case 9: return GHOSTTY_MOUSE_TEN
            case 10: return GHOSTTY_MOUSE_ELEVEN
            default: return GHOSTTY_MOUSE_UNKNOWN
            }
        }
    }

    private func translate(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var raw = UInt32(GHOSTTY_MODS_NONE.rawValue)
        if flags.contains(.shift) { raw |= UInt32(GHOSTTY_MODS_SHIFT.rawValue) }
        if flags.contains(.control) { raw |= UInt32(GHOSTTY_MODS_CTRL.rawValue) }
        if flags.contains(.option) { raw |= UInt32(GHOSTTY_MODS_ALT.rawValue) }
        if flags.contains(.command) { raw |= UInt32(GHOSTTY_MODS_SUPER.rawValue) }
        if flags.contains(.capsLock) { raw |= UInt32(GHOSTTY_MODS_CAPS.rawValue) }
        return ghostty_input_mods_e(raw)
    }

    /// Scroll modifiers carry the momentum phase in the high bits, which is how
    /// libghostty tells a flick from a drag.
    private func translateScrollModifiers(_ event: NSEvent) -> ghostty_input_scroll_mods_t {
        var value = ghostty_input_scroll_mods_t(translate(event.modifierFlags).rawValue)
        switch event.momentumPhase {
        case .began:
            value |= ghostty_input_scroll_mods_t(GHOSTTY_MOUSE_MOMENTUM_BEGAN.rawValue << 16)
        case .changed:
            value |= ghostty_input_scroll_mods_t(GHOSTTY_MOUSE_MOMENTUM_CHANGED.rawValue << 16)
        case .ended:
            value |= ghostty_input_scroll_mods_t(GHOSTTY_MOUSE_MOMENTUM_ENDED.rawValue << 16)
        case .cancelled:
            value |= ghostty_input_scroll_mods_t(GHOSTTY_MOUSE_MOMENTUM_CANCELLED.rawValue << 16)
        case .mayBegin:
            value |= ghostty_input_scroll_mods_t(GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN.rawValue << 16)
        default:
            break
        }
        if event.hasPreciseScrollingDeltas {
            value |= 1 << 24
        }
        return value
    }
}

private func string(from pointer: UnsafePointer<CChar>?) -> String? {
    guard let pointer else { return nil }
    return String(cString: pointer)
}

private func string(from pointer: UnsafePointer<CChar>?, length: Int) -> String? {
    guard let pointer, length > 0 else { return nil }
    let buffer = UnsafeBufferPointer(start: pointer, count: length)
    return String(decoding: buffer.map(UInt8.init(bitPattern:)), as: UTF8.self)
}

private extension Optional where Wrapped == String {
    func withOptionalCString<T>(_ body: (UnsafePointer<CChar>?) -> T) -> T {
        switch self {
        case .none:
            return body(nil)
        case .some(let value):
            return value.withCString(body)
        }
    }
}

private extension Collection where Element == String {
    /// Nests `withCString` once per element so every pointer is valid at once.
    func withCStrings<T>(_ body: ([UnsafePointer<CChar>?]) -> T) -> T {
        var strings = Array(self)
        return strings.withUnsafeMutableBufferPointer { buffer in
            var pointers: [UnsafePointer<CChar>?] = []
            pointers.reserveCapacity(buffer.count)
            func appendPointer(at index: Int) -> T {
                if index == buffer.count {
                    return body(pointers)
                }
                return buffer[index].withCString { pointer in
                    pointers.append(pointer)
                    return appendPointer(at: index + 1)
                }
            }
            return appendPointer(at: 0)
        }
    }
}
