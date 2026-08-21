import AppKit
import GhosttyKit

// Ported from GhosttyKit (MIT, https://github.com/briannadoubt/GhosttyKit).
// The closure struct it routed everything through is gone — this talks to its
// session directly — and the layer takes its colour from the user's ghostty
// config rather than from a theme of the library's own.

/// The `NSView` libghostty draws a surface into, and the AppKit end of its
/// input: keys (including input methods), mouse, scroll and the context menu.
@MainActor
final class TerminalSurfaceView: NSView, @preconcurrency NSTextInputClient {
    enum MouseButton: Equatable {
        case left
        case right
        /// AppKit's `buttonNumber`, so 2 is the middle button.
        case other(Int)
    }

    let session: TerminalSession

    /// Takes the wheel away from libghostty. Herdr owns the scrollback, so a
    /// wheel event has to become a `terminal.scroll` on the server instead of
    /// scrolling a viewport that only ever holds one frame.
    var onScrollWheel: ((NSEvent) -> Void)?
    /// A left click landed here. In a split that is how the active pane changes,
    /// so it has to be seen outside libghostty as well.
    var onPrimaryClick: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    private var markedText = NSMutableAttributedString()
    /// Collects what `interpretKeyEvents` produces during one `keyDown`, so the
    /// key and its text reach libghostty together.
    private var keyTextAccumulator: [String]?
    private var pendingRenderRequest = false
    private var isRendering = false
    private var observedWindow: NSWindow?
    private var cursorHidden = false
    nonisolated(unsafe) private var windowObservers: [NSObjectProtocol] = []
    nonisolated(unsafe) private var globalObservers: [NSObjectProtocol] = []

    init(session: TerminalSession) {
        self.session = session
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        applyBackgroundColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        let notificationCenter = NotificationCenter.default
        for observer in windowObservers + globalObservers {
            notificationCenter.removeObserver(observer)
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The surface is created here rather than at init: libghostty builds a
    /// `CVDisplayLink` from the view's screen, so there has to be a window
    /// first. `TerminalPaneView` calls `attach` again once the view is laid out.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateObservers()
        applyBackgroundColor()
        guard window != nil else { return }
        session.attach(to: self)
        renderIfNeeded()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        session.updateContentScale()
        session.setDisplayID(currentDisplayID())
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackgroundColor()
        session.applyColorScheme(appearance: effectiveAppearance)
    }

    override func updateLayer() {
        requestRender()
    }

    override func layout() {
        super.layout()
        session.resize(to: bounds.size)
    }

    override func becomeFirstResponder() -> Bool {
        session.setFocused(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        session.setFocused(false)
        return true
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        onPrimaryClick?()
        requestWindowFirstResponder()
        session.sendMousePosition(event)
        session.sendMouseButton(.left, pressed: true, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        session.sendMousePosition(event)
        session.sendMouseButton(.left, pressed: false, event: event)
    }

    /// libghostty gets the right click first; the context menu is what happens
    /// when the program in the pane does not want it.
    override func rightMouseDown(with event: NSEvent) {
        requestWindowFirstResponder()
        session.sendMousePosition(event)
        if !session.sendMouseButton(.right, pressed: true, event: event) {
            presentContextMenu(with: event)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        session.sendMousePosition(event)
        session.sendMouseButton(.right, pressed: false, event: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        requestWindowFirstResponder()
        session.sendMousePosition(event)
        session.sendMouseButton(.other(Int(event.buttonNumber)), pressed: true, event: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        session.sendMousePosition(event)
        session.sendMouseButton(.other(Int(event.buttonNumber)), pressed: false, event: event)
    }

    override func mouseEntered(with event: NSEvent) { session.sendMousePosition(event) }
    override func mouseExited(with event: NSEvent) { session.sendMouseExit(modifiers: event.modifierFlags) }
    override func mouseMoved(with event: NSEvent) { session.sendMousePosition(event) }
    override func mouseDragged(with event: NSEvent) { session.sendMousePosition(event) }
    override func rightMouseDragged(with event: NSEvent) { session.sendMousePosition(event) }
    override func otherMouseDragged(with event: NSEvent) { session.sendMousePosition(event) }

    override func scrollWheel(with event: NSEvent) {
        if let onScrollWheel {
            onScrollWheel(event)
        } else {
            session.sendScrollWheel(event)
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        keyTextAccumulator = []
        interpretKeyEvents([event])
        let text = keyTextAccumulator?.joined()
        keyTextAccumulator = nil
        session.sendKeyDown(event, text: text?.isEmpty == true ? nil : text)
    }

    override func keyUp(with event: NSEvent) {
        session.sendKeyUp(event)
    }

    override func flagsChanged(with event: NSEvent) {
        session.sendMousePosition(event)
        super.flagsChanged(with: event)
    }

    override func doCommand(by selector: Selector) {
        if session.performCommand(selector) {
            return
        }
        // Everything the terminal handles itself: letting AppKit also insert a
        // newline or move the insertion point would double the keystroke.
        if Self.shouldSuppressSystemTextInputCommand(selector) {
            return
        }
        super.doCommand(by: selector)
    }

    // MARK: - Menu actions

    @objc func copy(_ sender: Any?) {
        guard let text = session.copySelection(), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        session.paste(text)
    }

    override func selectAll(_ sender: Any?) {
        session.perform(action: "select_all")
    }

    @objc func openHoveredLink(_ sender: Any?) {
        session.openHoveredLink()
    }

    @objc func copyHoveredLink(_ sender: Any?) {
        guard let url = session.state.hoveredLinkURL, !url.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    @objc func openTerminalConfig(_ sender: Any?) {
        session.host.openConfig()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        isMenuActionEnabled(menuItem.action)
    }

    // MARK: - NSTextInputClient

    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func markedRange() -> NSRange {
        hasMarkedText() ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = Self.plainString(from: string) ?? ""
        markedText = NSMutableAttributedString(string: text)
        session.setMarkedText(text.isEmpty ? nil : text)
    }

    func unmarkText() {
        markedText = NSMutableAttributedString()
        session.setMarkedText(nil)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(bounds, to: nil))
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard let text = Self.plainString(from: string) else { return }
        unmarkText()
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(text)
        } else {
            session.insertText(text)
        }
    }

    // MARK: - Rendering and cursor

    func requestFocus() {
        requestWindowFirstResponder()
    }

    /// Coalesces the render requests libghostty makes from its own thread into
    /// one draw per pass, and never re-enters one already in progress.
    func requestRender() {
        pendingRenderRequest = true
        needsDisplay = true
        layer?.setNeedsDisplay()
        renderIfNeeded()
    }

    func applyCursor(for shape: ghostty_action_mouse_shape_e) {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_TEXT,
             GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT:
            NSCursor.iBeam.set()
        case GHOSTTY_MOUSE_SHAPE_POINTER:
            NSCursor.pointingHand.set()
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR:
            NSCursor.crosshair.set()
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED,
             GHOSTTY_MOUSE_SHAPE_NO_DROP:
            NSCursor.operationNotAllowed.set()
        case GHOSTTY_MOUSE_SHAPE_COL_RESIZE,
             GHOSTTY_MOUSE_SHAPE_EW_RESIZE:
            NSCursor.resizeLeftRight.set()
        case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE,
             GHOSTTY_MOUSE_SHAPE_NS_RESIZE:
            NSCursor.resizeUpDown.set()
        case GHOSTTY_MOUSE_SHAPE_GRAB,
             GHOSTTY_MOUSE_SHAPE_GRABBING:
            NSCursor.openHand.set()
        default:
            NSCursor.arrow.set()
        }
    }

    func setCursorHidden(_ hidden: Bool) {
        guard cursorHidden != hidden else { return }
        cursorHidden = hidden
        NSCursor.setHiddenUntilMouseMoves(hidden)
    }

    static func shouldSuppressSystemTextInputCommand(_ selector: Selector) -> Bool {
        selector == #selector(NSResponder.insertNewline(_:))
            || selector == #selector(NSResponder.insertLineBreak(_:))
            || selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
            || selector == #selector(NSResponder.insertTab(_:))
            || selector == #selector(NSResponder.insertBacktab(_:))
            || selector == #selector(NSResponder.deleteBackward(_:))
            || selector == #selector(NSResponder.deleteForward(_:))
            || selector == #selector(NSResponder.deleteWordBackward(_:))
            || selector == #selector(NSResponder.deleteWordForward(_:))
            || selector == #selector(NSResponder.deleteToBeginningOfLine(_:))
            || selector == #selector(NSResponder.deleteToEndOfLine(_:))
            || selector == #selector(NSResponder.moveUp(_:))
            || selector == #selector(NSResponder.moveDown(_:))
            || selector == #selector(NSResponder.moveLeft(_:))
            || selector == #selector(NSResponder.moveRight(_:))
            || selector == #selector(NSResponder.moveWordLeft(_:))
            || selector == #selector(NSResponder.moveWordRight(_:))
            || selector == #selector(NSResponder.moveToBeginningOfLine(_:))
            || selector == #selector(NSResponder.moveToEndOfLine(_:))
            || selector == #selector(NSResponder.pageUp(_:))
            || selector == #selector(NSResponder.pageDown(_:))
            || selector == #selector(NSResponder.cancelOperation(_:))
    }

    // MARK: - Private

    /// The padding libghostty leaves around the grid is this layer, so it has to
    /// be the terminal's background rather than a colour of the view's own.
    private func applyBackgroundColor() {
        layer?.backgroundColor = GhosttyRuntime.config.paneBackground.cgColor
    }

    private func renderIfNeeded() {
        guard !isRendering else { return }
        while pendingRenderRequest {
            pendingRenderRequest = false
            isRendering = true
            session.render()
            isRendering = false
        }
    }

    private func updateObservers() {
        let notificationCenter = NotificationCenter.default
        if observedWindow !== window {
            for observer in windowObservers {
                notificationCenter.removeObserver(observer)
            }
            windowObservers.removeAll()
            observedWindow = window

            if let window {
                windowObservers.append(
                    notificationCenter.addObserver(
                        forName: NSWindow.didChangeOcclusionStateNotification,
                        object: window,
                        queue: .main
                    ) { [weak self] _ in
                        Task { @MainActor [weak self] in
                            self?.session.setOccluded(!window.occlusionState.contains(.visible))
                        }
                    }
                )
                windowObservers.append(
                    notificationCenter.addObserver(
                        forName: NSWindow.didChangeScreenNotification,
                        object: window,
                        queue: .main
                    ) { [weak self] _ in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.session.setDisplayID(self.currentDisplayID())
                        }
                    }
                )
            }
        }

        if globalObservers.isEmpty {
            globalObservers.append(
                notificationCenter.addObserver(
                    forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.session.keyboardLayoutChanged()
                    }
                }
            )
        }
    }

    private func requestWindowFirstResponder() {
        guard let window else { return }
        if !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
        }
        if window.firstResponder !== self {
            window.makeFirstResponder(self)
        }
    }

    private func currentDisplayID() -> CGDirectDisplayID? {
        guard let screenNumber = window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(screenNumber.uint32Value)
    }

    private func presentContextMenu(with event: NSEvent) {
        guard let menu = makeContextMenu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func makeContextMenu() -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(menuItem(title: "Copy", action: #selector(copy(_:))))
        menu.addItem(menuItem(title: "Paste", action: #selector(paste(_:))))
        menu.addItem(menuItem(title: "Select All", action: #selector(selectAll(_:))))

        if session.state.hoveredLinkURL?.isEmpty == false {
            menu.addItem(NSMenuItem.separator())
            menu.addItem(menuItem(title: "Open Hovered Link", action: #selector(openHoveredLink(_:))))
            menu.addItem(menuItem(title: "Copy Hovered Link", action: #selector(copyHoveredLink(_:))))
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem(title: "Open Terminal Config", action: #selector(openTerminalConfig(_:))))
        return menu
    }

    private func menuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = isMenuActionEnabled(action)
        return item
    }

    private func isMenuActionEnabled(_ action: Selector?) -> Bool {
        switch action {
        case #selector(copy(_:)):
            return session.hasSelection()
        case #selector(paste(_:)):
            return NSPasteboard.general.string(forType: .string) != nil
        case #selector(selectAll(_:)), #selector(openTerminalConfig(_:)):
            return true
        case #selector(openHoveredLink(_:)), #selector(copyHoveredLink(_:)):
            return session.state.hoveredLinkURL?.isEmpty == false
        default:
            return false
        }
    }

    private static func plainString(from string: Any) -> String? {
        switch string {
        case let string as String:
            return string
        case let attributed as NSAttributedString:
            return attributed.string
        default:
            return nil
        }
    }
}
