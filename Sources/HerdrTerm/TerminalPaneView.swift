import AppKit
import GhosttyKit
import HerdrClient

/// Hosts one libghostty surface, or an explanatory placeholder when there is
/// nothing attached. One of these per Herdr pane; a tab that is split has
/// several, side by side inside `SplitContainerView`.
@MainActor
final class TerminalPaneView: NSView {
    /// Fires when the attached pane's process goes away, so the window can fall
    /// back to a placeholder instead of showing a frozen last frame.
    var onDetach: (() -> Void)?
    /// The user clicked into this pane. In a split that is how the active pane
    /// changes, so it has to reach the session and not just libghostty.
    var onActivate: (() -> Void)?

    private var session: GhosttyTerminalSession?
    private var terminalView: GhosttyTerminalView?
    private var currentPaneId: String?
    /// Side channel to the bridge for anything that is not a keystroke.
    private var control: PaneControlChannel?
    /// Trackpad deltas arrive in pixels; herdr scrolls in whole lines.
    private var scrollRemainder: CGFloat = 0
    /// A pane whose bridge exited on its own. Re-attaching it automatically
    /// would spin: exit, placeholder, refresh, attach, exit. Wait to be asked.
    private var detachedPaneId: String?

    private let placeholder = PlaceholderView()
    private let ring = AttentionRingView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)
        ring.translatesAutoresizingMaskIntoConstraints = false
        addSubview(ring)
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            placeholder.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            ring.topAnchor.constraint(equalTo: topAnchor),
            ring.bottomAnchor.constraint(equalTo: bottomAnchor),
            ring.leadingAnchor.constraint(equalTo: leadingAnchor),
            ring.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        showPlaceholder(title: "No pane attached", detail: "Connect to a Herdr host to attach a pane.")
    }

    /// Borders: the loud one when an agent in this pane wants attention, a quiet
    /// one to say which pane of a split has the keyboard.
    func decorate(active: Bool, attention: Bool, status: AgentStatus) {
        ring.update(attention: attention, active: active, status: status)
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }

    func showPlaceholder(title: String, detail: String, symbol: String = "rectangle.dashed") {
        teardown()
        placeholder.configure(title: title, detail: detail, symbol: symbol)
        placeholder.isHidden = false
        needsDisplay = true
    }

    /// Called when the user picks a pane, which is also permission to retry one
    /// that dropped out.
    func allowReattach() {
        detachedPaneId = nil
    }

    func attach(paneId: String, socketPath: String, herdrBinary: String, executablePath: String) {
        if currentPaneId == paneId, terminalView != nil { return }
        if detachedPaneId == paneId { return }
        if let reason = GhosttyRuntime.unavailableReason {
            showPlaceholder(title: "Terminal unavailable", detail: reason, symbol: "exclamationmark.triangle")
            return
        }
        guard let host = GhosttyRuntime.host else { return }

        teardown()
        placeholder.isHidden = true
        currentPaneId = paneId

        let control = PaneControlChannel()
        self.control = control

        // libghostty drops the surface's own `command` and `env_vars`, so the
        // bridge is configured app-wide and told which pane it serves on its
        // command line. `launch` is still filled in: it costs nothing, and a
        // libghostty that honours it would simply get there first.
        let argv = BridgeOptions.argv(
            executablePath: executablePath,
            target: paneId,
            socketPath: socketPath,
            herdrBinary: herdrBinary,
            controlPipe: control?.path
        )
        guard GhosttyRuntime.useSurfaceCommand(argv) else {
            failAttach(
                paneId: paneId,
                detail: "Could not tell libghostty to run the Herdr bridge for this pane."
            )
            return
        }

        var launch = GhosttyTerminalLaunchConfiguration()
        launch.command = argv.map(\.shellEscaped).joined(separator: " ")
        launch.environment = [
            "HERDR_TERM_TARGET": paneId,
            "HERDR_SOCKET_PATH": socketPath,
            "HERDR_BIN": herdrBinary,
        ]
        if let control {
            launch.environment[PaneControlChannel.environmentKey] = control.path
        }

        let session = host.makeSession(configuration: launch)
        session.closeHandler = { [weak self] _ in
            self?.handleSessionClosed()
        }
        // `makeView()` with one handler swapped: the surface renders whatever
        // herdr sends and holds no scrollback of its own, so a wheel event has
        // to become `terminal.scroll` on the server instead.
        let view = GhosttyTerminalView()
        var handlers = session.makeViewHandlers()
        handlers.scrollWheel = { [weak self] event in self?.scroll(event) }
        // Clicking a pane in a split is how the user moves the active pane, so
        // the click has to be seen here as well as by libghostty.
        let mouseButton = handlers.mouseButton
        handlers.mouseButton = { [weak self] button, pressed, event in
            if pressed, case .left = button { self?.onActivate?() }
            return mouseButton(button, pressed, event)
        }
        view.handlers = handlers
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view, positioned: .below, relativeTo: placeholder)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        // The surface is created against a view that is already in the window:
        // libghostty builds a `CVDisplayLink` from the view's screen, and a view
        // that has not landed anywhere yet has none, so creating it first fails.
        layoutSubtreeIfNeeded()
        session.attach(to: view)

        // `ghostty_surface_new` reports failure by returning null, which
        // GhosttyKit passes on as a nil `surface`. Without this the pane just
        // renders empty and reads as a terminal that never printed anything.
        guard session.surface != nil else {
            view.removeFromSuperview()
            session.closeHandler = nil
            host.unregister(session)
            failAttach(
                paneId: paneId,
                detail: "libghostty could not create a surface for this pane. It needs the window to be on a "
                    + "display — a locked screen is enough to stop it. Pick the pane again to retry."
            )
            return
        }

        self.session = session
        terminalView = view
        GhosttyRuntime.paneAttached()
        focusTerminal()
    }

    /// An attach that never got as far as a surface. Parked the same way a
    /// bridge that exited is parked: `refresh` runs on every snapshot, so
    /// without this the failure repeats every couple of seconds.
    private func failAttach(paneId: String, detail: String) {
        showPlaceholder(title: "Terminal unavailable", detail: detail, symbol: "exclamationmark.triangle")
        detachedPaneId = paneId
    }

    /// Keystrokes should land in the terminal, not in whatever list the user
    /// last clicked.
    func focusTerminal() {
        guard let terminalView else { return }
        window?.makeFirstResponder(terminalView)
    }

    func teardown() {
        control?.close()
        control = nil
        scrollRemainder = 0
        guard let session else {
            currentPaneId = nil
            return
        }
        session.closeHandler = nil
        // Releasing the session frees the surface, which hangs up the bridge's
        // PTY; the bridge sees EOF on stdin and sends `terminal.release`.
        terminalView?.removeFromSuperview()
        terminalView = nil
        self.session = nil
        session.host.unregister(session)
        currentPaneId = nil
        GhosttyRuntime.paneDetached()
        needsDisplay = true
    }

    /// Wheel and trackpad both land here. AppKit has already applied the
    /// user's natural-scrolling preference, so a positive delta always means
    /// "show me earlier output".
    private func scroll(_ event: NSEvent) {
        guard let control else { return }
        if event.phase == .began { scrollRemainder = 0 }
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }

        let lines: CGFloat
        if event.hasPreciseScrollingDeltas {
            scrollRemainder += delta
            lines = (scrollRemainder / lineHeight).rounded(.towardZero)
            scrollRemainder -= lines * lineHeight
        } else {
            // One notch of a wheel mouse is one unit; three lines is what every
            // other terminal does with it.
            lines = (delta * 3).rounded(delta > 0 ? .up : .down)
        }
        guard lines != 0 else { return }
        // A flung trackpad can produce absurd deltas; herdr clamps at the top
        // of the scrollback anyway, this just keeps the message sane.
        let count = min(Int(abs(lines)), 500)
        control.scroll(lines > 0 ? .up : .down, lines: count)
    }

    /// Point height of one terminal row. libghostty reports the cell in pixels.
    private var lineHeight: CGFloat {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        guard let cell = session?.state.cellSize, cell.height > 0, scale > 0 else { return 18 }
        return CGFloat(cell.height) / scale
    }

    private func handleSessionClosed() {
        let closedPaneId = currentPaneId
        showPlaceholder(
            title: "Pane detached",
            detail: "The Herdr bridge for this pane exited. Pick the pane again to reattach.",
            symbol: "bolt.horizontal.circle"
        )
        detachedPaneId = closedPaneId
        onDetach?()
    }
}

/// Centered icon + headline + explanation, used for every empty and error state.
private final class PlaceholderView: NSStackView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .centerX
        spacing = 8

        icon.symbolConfiguration = .init(pointSize: 26, weight: .regular)
        icon.contentTintColor = .tertiaryLabelColor

        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.textColor = .secondaryLabelColor
        title.alignment = .center

        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .tertiaryLabelColor
        detail.alignment = .center
        detail.maximumNumberOfLines = 4

        setViews([icon, title, detail], in: .leading)
        setCustomSpacing(4, after: title)
    }

    required init?(coder: NSCoder) { nil }

    func configure(title: String, detail: String, symbol: String) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        self.title.stringValue = title
        self.detail.stringValue = detail
    }
}

/// Border drawn over a pane. The loud version says an agent wants attention
/// (pulsing while it is blocked, steady for an unseen `done`); the quiet version
/// says which pane of a split has the keyboard.
private final class AttentionRingView: NSView {
    private var status: AgentStatus = .idle
    private var attention = false
    private var active = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = 6
    }

    required init?(coder: NSCoder) { nil }

    /// Purely decorative: never take clicks away from the terminal underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        if attention {
            layer?.borderWidth = 2
            layer?.borderColor = StatusStyle.attentionColor(status).cgColor
        } else if active {
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
        } else {
            layer?.borderWidth = 0
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func update(attention: Bool, active: Bool, status: AgentStatus) {
        guard attention != self.attention || active != self.active || status != self.status else { return }
        self.attention = attention
        self.active = active
        self.status = status
        needsDisplay = true

        layer?.removeAnimation(forKey: "pulse")
        guard attention, status == .blocked else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.35
        pulse.duration = 0.85
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        layer?.add(pulse, forKey: "pulse")
    }
}
