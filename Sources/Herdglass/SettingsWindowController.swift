import AppKit
import UserNotifications

/// The app's own settings — the few choices that are this client's to make.
///
/// Terminal settings still come from the user's ghostty config and pane settings
/// from the Herdr server; nothing that either of those can express belongs here.
/// What is left is how this app behaves as a macOS app: whether Herdr's
/// notifications reach Notification Center, and how big the chrome around the
/// terminals is drawn — a size that is nobody else's to state, because ghostty's
/// `font-size` is the terminal's own and Herdr has no window.
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
    private let fontSize = NSStepper()
    private let fontSizeValue = NSTextField(labelWithString: "")
    private var fontSizeValueWidth: NSLayoutConstraint?
    /// Every label in this window, so the size being chosen can be shown in the
    /// window that chooses it — the setting is about text, and a preview that
    /// needs a restart to appear is no preview.
    private var scaled: [(NSTextField, Double, NSFont.Weight)] = []

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
        let appearanceHeading = label("Appearance", size: 13, weight: .semibold)
        let sizeRow = buildFontSizeRow()
        let sizeExplanation = wrappingLabel(
            "The size of this app's own chrome — the sidebar, the tab strip and the labels "
            + "around a terminal. The terminal's own font stays `font-size` in your ghostty "
            + "config, and a pane's contents belong to the Herdr server."
        )

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let heading = label("Notifications", size: 13, weight: .semibold)

        notifications.target = self
        notifications.action = #selector(toggleNotifications)

        let explanation = wrappingLabel(
            "Herdr reports agents in panes you are not looking at. Each one becomes a "
            + "macOS notification; opening it selects the pane it came from."
        )

        buildDeniedRow()

        let stack = NSStackView(views: [
            appearanceHeading, sizeRow, sizeExplanation, separator,
            heading, notifications, explanation, deniedRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.setCustomSpacing(4, after: sizeRow)
        stack.setCustomSpacing(16, after: sizeExplanation)
        stack.setCustomSpacing(16, after: separator)
        stack.setCustomSpacing(4, after: notifications)
        stack.setCustomSpacing(14, after: explanation)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let controller = NSViewController()
        controller.view = stack
        // Autolayout sizes the window from here; the width has to come from
        // somewhere, and the wrapping label would otherwise pick its own.
        stack.widthAnchor.constraint(equalToConstant: 420).isActive = true
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        return controller
    }

    /// `Interface text size  [ 12 pt ] [stepper]`. A stepper rather than a field:
    /// the range is a dozen whole points, and every step is applied at once, so
    /// there is nothing to type and nothing to validate.
    private func buildFontSizeRow() -> NSView {
        let caption = label("Interface text size", size: 12, weight: .regular)

        fontSize.minValue = ChromeMetrics.range.lowerBound
        fontSize.maxValue = ChromeMetrics.range.upperBound
        fontSize.increment = 1
        fontSize.valueWraps = false
        fontSize.autorepeat = false
        fontSize.target = self
        fontSize.action = #selector(stepFontSize)
        fontSize.setAccessibilityIdentifier("InterfaceTextSizeStepper")

        // Monospaced digits and a width of its own, so stepping through the
        // range does not shuffle the stepper sideways under the pointer.
        fontSizeValue.alignment = .right
        fontSizeValue.textColor = .secondaryLabelColor
        let width = fontSizeValue.widthAnchor.constraint(equalToConstant: 0)
        fontSizeValueWidth = width
        width.isActive = true

        let row = NSStackView(views: [caption, fontSizeValue, fontSize])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    /// The labels this window draws at the size it is setting.
    private func label(_ text: String, size: Double, weight: NSFont.Weight) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = ChromeMetrics.font(size, weight: weight)
        scaled.append((field, size, weight))
        return field
    }

    private func wrappingLabel(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = ChromeMetrics.font(11)
        field.textColor = .secondaryLabelColor
        scaled.append((field, 11, .regular))
        return field
    }

    private func buildDeniedRow() {
        let warning = label("Turned off for Herdglass in System Settings.", size: 11, weight: .regular)
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
        fontSize.doubleValue = ChromeMetrics.fontSize
        fontSizeValue.stringValue = "\(Int(ChromeMetrics.fontSize)) pt"
        fontSizeValue.font = .monospacedDigitSystemFont(ofSize: ChromeMetrics.length(11), weight: .regular)
        fontSizeValueWidth?.constant = ChromeMetrics.length(40)
        AgentNotifications.authorizationStatus { [weak self] status in
            guard let self else { return }
            self.deniedRow.isHidden = status != .denied || !AgentNotifications.isEnabled
        }
    }

    @objc private func toggleNotifications(_ sender: NSButton) {
        AgentNotifications.isEnabled = sender.state == .on
        applySettings()
    }

    /// Applied on the step, not on an OK button: the whole app redraws at the
    /// new size, which is the only honest preview of what is being chosen.
    @objc private func stepFontSize(_ sender: NSStepper) {
        ChromeMetrics.fontSize = sender.doubleValue
        for (field, size, weight) in scaled { field.font = ChromeMetrics.font(size, weight: weight) }
        applySettings()
    }

    @objc private func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else { return }
        NSWorkspace.shared.open(url)
    }
}
