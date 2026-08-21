import AppKit
import HerdrClient

/// Connect sheet. Stays up while the connection is attempted so failures land
/// where the user typed the host, instead of in an alert behind a closed sheet.
@MainActor
final class ConnectSheetController: NSWindowController {
    var onConnect: ((ConnectTarget, @escaping (Error?) -> Void) -> Void)?

    private let hostField = NSTextField(string: "")
    private let sessionField = NSTextField(string: "")
    private let knownHosts = NSPopUpButton()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let connectButton = NSButton()
    private let cancelButton = NSButton()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Connect to Herdr"
        self.init(window: window)
        let content = buildView()
        window.contentView = content
        prefill()
        // Sheets do not resize: let the constraints decide the height instead of
        // stretching the stack's gaps to fill a guessed one.
        window.setContentSize(content.fittingSize)
    }

    private func buildView() -> NSView {
        hostField.placeholderString = "SSH host, ssh://user@host:22, or local"
        hostField.setAccessibilityIdentifier("HostField")
        hostField.target = self
        hostField.action = #selector(connectTapped)

        sessionField.placeholderString = "optional named session"
        sessionField.setAccessibilityIdentifier("SessionField")
        sessionField.target = self
        sessionField.action = #selector(connectTapped)

        knownHosts.pullsDown = false
        knownHosts.target = self
        knownHosts.action = #selector(pickKnownHost)
        knownHosts.setAccessibilityIdentifier("KnownHostsPopUp")
        knownHosts.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let hostRow = NSStackView(views: [hostField, knownHosts])
        hostRow.orientation = .horizontal
        hostRow.spacing = 8

        let hint = NSTextField(wrappingLabelWithString:
            "Same targets as `herdr --remote`; `local` attaches to a Herdr server on this Mac. "
            + "Remote hosts use BatchMode SSH, so the key must already be in ssh-agent."
        )
        hint.font = ChromeMetrics.font(11)
        hint.textColor = .secondaryLabelColor

        errorLabel.font = ChromeMetrics.font(11)
        errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 4
        errorLabel.isHidden = true

        let grid = NSGridView(views: [
            [label("Host"), hostRow],
            [label("Session"), sessionField],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.rowAlignment = .firstBaseline

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.keyEquivalent = "\u{1b}"

        connectButton.title = "Connect"
        connectButton.bezelStyle = .rounded
        connectButton.target = self
        connectButton.action = #selector(connectTapped)
        connectButton.keyEquivalent = "\r"
        connectButton.setAccessibilityIdentifier("ConnectButton")

        // `.trailing` gravity keeps the buttons right-aligned even though the
        // row is stretched to the full sheet width.
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 10
        for view in [spinner, cancelButton, connectButton] {
            buttons.addView(view, in: .trailing)
        }

        let root = NSStackView(views: [grid, hint, errorLabel, buttons])
        root.orientation = .vertical
        root.alignment = .width
        root.distribution = .fill
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 470),
        ])
        return container
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.textColor = .secondaryLabelColor
        return field
    }

    /// `local`, then what the user actually used, then everything in ssh_config.
    private func prefill() {
        let recents = RecentsStore.load()
        knownHosts.removeAllItems()
        knownHosts.addItem(withTitle: "local")

        let recentHosts = recents.map(\.host).filter { $0 != "local" }
        if !recentHosts.isEmpty {
            knownHosts.menu?.addItem(.separator())
            for host in Set(recentHosts).sorted() { knownHosts.addItem(withTitle: host) }
        }

        let configured = SSHConfig.hostAliases().filter { !knownHosts.itemTitles.contains($0) }
        if !configured.isEmpty {
            knownHosts.menu?.addItem(.separator())
            for host in configured { knownHosts.addItem(withTitle: host) }
        }

        // The host the window was last on, not the head of `recents` — that list
        // is in sidebar order now, so its first entry is the oldest host the user
        // has, which is the least likely thing they want typed in for them.
        if let recent = RecentsStore.selectedHost() ?? recents.last {
            hostField.stringValue = recent.host
            sessionField.stringValue = recent.session ?? ""
        } else {
            hostField.stringValue = "local"
        }
        knownHosts.selectItem(withTitle: hostField.stringValue)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeFirstResponder(hostField)
    }

    // MARK: - Actions

    @objc private func pickKnownHost() {
        guard let title = knownHosts.titleOfSelectedItem else { return }
        hostField.stringValue = title
        window?.makeFirstResponder(hostField)
    }

    @objc private func connectTapped() {
        let target = ConnectTarget(host: hostField.stringValue, session: sessionField.stringValue)
        guard !target.host.isEmpty else {
            show(error: "Enter an SSH host, or `local` for a Herdr server on this Mac.")
            return
        }
        guard let onConnect else { return }

        setBusy(true)
        onConnect(target) { [weak self] error in
            guard let self else { return }
            self.setBusy(false)
            if let error {
                self.show(error: error.localizedDescription)
            } else {
                self.dismiss()
            }
        }
    }

    @objc private func cancelTapped() {
        dismiss()
    }

    private func dismiss() {
        guard let window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
    }

    private func setBusy(_ busy: Bool) {
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        connectButton.isEnabled = !busy
        cancelButton.isEnabled = !busy
        hostField.isEnabled = !busy
        sessionField.isEnabled = !busy
        knownHosts.isEnabled = !busy
        if busy { errorLabel.isHidden = true }
    }

    private func show(error: String) {
        errorLabel.stringValue = error
        errorLabel.isHidden = false
    }
}
