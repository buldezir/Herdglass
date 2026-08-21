import AppKit
import UserNotifications

/// The app's own settings — the few choices that are this client's to make.
///
/// Terminal settings still come from the user's ghostty config and pane settings
/// from the Herdr server; nothing that either of those can express belongs here.
/// What is left is how this app behaves as a macOS app, which today is whether
/// Herdr's notifications reach Notification Center.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let notifications = NSButton(
        checkboxWithTitle: "Notify when an agent needs input or finishes",
        target: nil,
        action: nil
    )
    /// Shown only when macOS itself is refusing the notifications the checkbox
    /// says are on, because the toggle alone cannot explain that silence.
    private let deniedRow = NSStackView()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.title = "Settings"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.contentViewController = buildContent()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used; there is no nib")
    }

    override func showWindow(_ sender: Any?) {
        // The user can flip both halves of this — ours in the checkbox, macOS's
        // in System Settings — so read them back every time the window appears.
        applySettings()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    private func buildContent() -> NSViewController {
        let heading = NSTextField(labelWithString: "Notifications")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)

        notifications.target = self
        notifications.action = #selector(toggleNotifications)

        let explanation = NSTextField(wrappingLabelWithString:
            "Herdr reports agents in panes you are not looking at. Each one becomes a "
            + "macOS notification; opening it selects the pane it came from.")
        explanation.font = .systemFont(ofSize: 11)
        explanation.textColor = .secondaryLabelColor

        buildDeniedRow()

        let stack = NSStackView(views: [heading, notifications, explanation, deniedRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.setCustomSpacing(4, after: notifications)
        stack.setCustomSpacing(14, after: explanation)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let controller = NSViewController()
        controller.view = stack
        // Autolayout sizes the window from here; the width has to come from
        // somewhere, and the wrapping label would otherwise pick its own.
        stack.widthAnchor.constraint(equalToConstant: 420).isActive = true
        return controller
    }

    private func buildDeniedRow() {
        let warning = NSTextField(labelWithString: "Turned off for herdr-term in System Settings.")
        warning.font = .systemFont(ofSize: 11)
        warning.textColor = .secondaryLabelColor
        let icon = NSImageView(image: NSImage(
            systemSymbolName: "exclamationmark.triangle",
            accessibilityDescription: nil
        ) ?? NSImage())
        icon.contentTintColor = .systemYellow

        let open = NSButton(title: "Open…", target: self, action: #selector(openSystemSettings))
        open.controlSize = .small
        open.bezelStyle = .rounded

        deniedRow.orientation = .horizontal
        deniedRow.alignment = .centerY
        deniedRow.spacing = 6
        for view in [icon, warning, open] as [NSView] { deniedRow.addView(view, in: .leading) }
        deniedRow.isHidden = true
    }

    private func applySettings() {
        notifications.state = AgentNotifications.isEnabled ? .on : .off
        AgentNotifications.authorizationStatus { [weak self] status in
            guard let self else { return }
            self.deniedRow.isHidden = status != .denied || !AgentNotifications.isEnabled
        }
    }

    @objc private func toggleNotifications(_ sender: NSButton) {
        AgentNotifications.isEnabled = sender.state == .on
        applySettings()
    }

    @objc private func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else { return }
        NSWorkspace.shared.open(url)
    }
}
