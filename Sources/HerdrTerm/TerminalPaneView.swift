import AppKit
import GhosttyKit
import HerdrClient

/// Hosts one libghostty surface, or an explanatory placeholder when there is
/// nothing attached.
@MainActor
final class TerminalPaneView: NSView {
    /// Fires when the attached pane's process goes away, so the window can fall
    /// back to a placeholder instead of showing a frozen last frame.
    var onDetach: (() -> Void)?

    private var session: GhosttyTerminalSession?
    private var terminalView: GhosttyTerminalView?
    private var currentPaneId: String?
    /// A pane whose bridge exited on its own. Re-attaching it automatically
    /// would spin: exit, placeholder, refresh, attach, exit. Wait to be asked.
    private var detachedPaneId: String?

    private let placeholder = PlaceholderView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            placeholder.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        showPlaceholder(title: "No pane attached", detail: "Connect to a Herdr host to attach a pane.")
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

        var launch = GhosttyTerminalLaunchConfiguration()
        launch.command = executablePath + " --bridge"
        launch.environment = [
            "HERDR_TERM_TARGET": paneId,
            "HERDR_SOCKET_PATH": socketPath,
            "HERDR_BIN": herdrBinary,
        ]

        let session = host.makeSession(configuration: launch)
        session.closeHandler = { [weak self] _ in
            self?.handleSessionClosed()
        }
        let view = session.makeView()
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view, positioned: .below, relativeTo: placeholder)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        self.session = session
        terminalView = view
        GhosttyRuntime.paneAttached()
        focusTerminal()
    }

    /// Keystrokes should land in the terminal, not in whatever list the user
    /// last clicked.
    func focusTerminal() {
        guard let terminalView else { return }
        window?.makeFirstResponder(terminalView)
    }

    func teardown() {
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
