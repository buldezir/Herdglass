import AppKit

/// The Files card as it is drawn: the terminal dimmed, and over it a card with
/// a header, a banner for what went wrong, the host's folders on the left and
/// the open file on the right.
///
/// A view over the terminal area, like the spaces overlay and for the same
/// reasons: one window, and the sidebar — which is still where hosts and
/// spaces are picked — stays live beside it. Unlike the overlay it takes the
/// keyboard, because it has a text view in it.
@MainActor
final class FileBrowserView: NSView {
    /// A click on the dimmed terminal around the card, or ⎋ from the tree.
    var onDismiss: (() -> Void)?
    var onSave: (() -> Void)?
    var onReload: (() -> Void)?

    let outline = NSOutlineView()
    let editor = CodeEditorView()

    private let scrim = TerminalScrimView()
    private let card = NSVisualEffectView()
    private let stack = NSStackView()
    private let header = NSStackView()
    private let icon = NSImageView()
    private let hostLabel = NSTextField(labelWithString: "")
    private let fileLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let reloadButton = NSButton()
    private let closeButton = NSButton()
    private let banner = NSStackView()
    private let bannerIcon = NSImageView()
    private let bannerLabel = NSTextField(wrappingLabelWithString: "")
    private var bannerActions: [() -> Void] = []
    private let split = NSSplitView()
    private let treeScroll = NSScrollView()
    private let editorArea = NSView()
    private let placeholder = NSTextField(labelWithString: "")
    private var insets: [NSLayoutConstraint] = []
    private var padding: [NSLayoutConstraint] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        card.material = .hudWindow
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true

        icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        hostLabel.textColor = .labelColor
        hostLabel.lineBreakMode = .byTruncatingHead
        fileLabel.textColor = .secondaryLabelColor
        fileLabel.lineBreakMode = .byTruncatingHead
        // When the two do not fit, the root gives way and the file keeps its
        // name: a long root (anything outside the home directory) otherwise
        // squeezed the open file, and its unsaved-changes dot, out of the header.
        hostLabel.setContentCompressionResistancePriority(.init(rawValue: 1), for: .horizontal)
        hostLabel.setContentHuggingPriority(.init(rawValue: 1), for: .horizontal)
        fileLabel.setContentCompressionResistancePriority(.init(rawValue: 2), for: .horizontal)
        fileLabel.setContentHuggingPriority(.init(rawValue: 2), for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        saveButton.bezelStyle = .push
        saveButton.controlSize = .small
        saveButton.target = self
        saveButton.action = #selector(save)
        for (button, symbol, label, action) in [
            (reloadButton, "arrow.clockwise", "Reload", #selector(reload)),
            (closeButton, "xmark", "Close", #selector(dismiss)),
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.isBordered = false
            button.toolTip = label
            button.target = self
            button.action = action
        }
        closeButton.toolTip = "Close (⎋)"
        header.orientation = .horizontal
        header.alignment = .centerY
        header.setViews([icon, hostLabel, fileLabel], in: .leading)
        header.setViews([spinner, saveButton, reloadButton, closeButton], in: .trailing)

        bannerIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        bannerIcon.contentTintColor = .systemYellow
        bannerLabel.textColor = .labelColor
        bannerLabel.setContentCompressionResistancePriority(.init(rawValue: 1), for: .horizontal)
        banner.orientation = .horizontal
        banner.alignment = .centerY
        banner.isHidden = true

        outline.headerView = nil
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.focusRingType = .none
        outline.allowsEmptySelection = true
        outline.indentationPerLevel = 12
        outline.autoresizesOutlineColumn = false
        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        treeScroll.documentView = outline
        treeScroll.hasVerticalScroller = true
        treeScroll.autohidesScrollers = true
        treeScroll.drawsBackground = false
        treeScroll.borderType = .noBorder

        placeholder.alignment = .center
        placeholder.textColor = .secondaryLabelColor
        placeholder.lineBreakMode = .byTruncatingMiddle
        for view in [editor, placeholder] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            editorArea.addSubview(view)
        }
        NSLayoutConstraint.activate([
            editor.topAnchor.constraint(equalTo: editorArea.topAnchor),
            editor.bottomAnchor.constraint(equalTo: editorArea.bottomAnchor),
            editor.leadingAnchor.constraint(equalTo: editorArea.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: editorArea.trailingAnchor),
            placeholder.centerXAnchor.constraint(equalTo: editorArea.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: editorArea.centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: editorArea.widthAnchor, constant: -32),
        ])

        // No delegate: the split only needs the tree to keep its width when the
        // window resizes, which is a holding priority, and an `NSSplitView` must
        // never be its own delegate anyway (see `SplitNodeDelegate`).
        //
        // The tree's starting width is its frame, set before it joins the split.
        // An arranged split takes its first sizes from the frames it is given,
        // and `setPosition(_:ofDividerAt:)` does nothing to one laid out by
        // constraints — the tree sat at its 120-point minimum whatever it was
        // told.
        treeScroll.frame = NSRect(x: 0, y: 0, width: ChromeMetrics.length(240), height: 100)
        editorArea.frame = NSRect(x: 0, y: 0, width: 600, height: 100)
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(treeScroll)
        split.addArrangedSubview(editorArea)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        treeScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        editorArea.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.setViews([header, banner, split], in: .leading)
        for view in [header, banner, split] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        split.setContentHuggingPriority(.init(rawValue: 1), for: .vertical)
        split.setContentCompressionResistancePriority(.init(rawValue: 1), for: .vertical)

        for view in [scrim, card] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        insets = [
            card.topAnchor.constraint(equalTo: topAnchor),
            bottomAnchor.constraint(equalTo: card.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ]
        padding = [
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            card.bottomAnchor.constraint(equalTo: stack.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ]
        NSLayoutConstraint.activate(insets + padding + [
            scrim.topAnchor.constraint(equalTo: topAnchor),
            scrim.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrim.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        NotificationCenter.default.addObserver(
            self, selector: #selector(applyMetrics), name: ChromeMetrics.didChangeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyGhosttyConfig), name: GhosttyRuntime.configDidChangeNotification, object: nil
        )
        applyMetrics()
        showPlaceholder("Select a file")
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - What the controller sets

    /// `host · ~/root`, then the open file relative to the root, with a dot in
    /// front of it while it has changes that are not on the host yet.
    func setHeader(host: String, root: String, file: String?, dirty: Bool, canSave: Bool) {
        hostLabel.stringValue = root.isEmpty ? host : "\(host) · \(root)"
        fileLabel.stringValue = file.map { (dirty ? "● " : "") + $0 } ?? ""
        fileLabel.toolTip = dirty ? "Edited — ⌘S saves it to the host" : nil
        saveButton.isEnabled = canSave
    }

    func setBusy(_ busy: Bool) {
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    func showEditor() {
        placeholder.isHidden = true
        editor.isHidden = false
    }

    func showPlaceholder(_ text: String) {
        editor.clear()
        editor.isHidden = true
        placeholder.stringValue = text
        placeholder.isHidden = false
    }

    /// A message across the top of the card, with up to a couple of answers to
    /// it as buttons. One at a time: the newest one is what the user is looking
    /// at.
    func showBanner(_ message: String, actions: [(String, () -> Void)] = []) {
        bannerLabel.stringValue = message
        bannerActions = actions.map(\.1)
        let buttons = actions.enumerated().map { index, action -> NSButton in
            let button = NSButton(title: action.0, target: self, action: #selector(bannerAction(_:)))
            button.bezelStyle = .push
            button.controlSize = .small
            button.tag = index
            return button
        }
        banner.setViews([bannerIcon, bannerLabel] + buttons, in: .leading)
        banner.isHidden = false
    }

    func hideBanner() {
        banner.isHidden = true
        bannerActions = []
    }

    // MARK: - Events

    /// Clicks on the card itself land on its controls; anything that reaches
    /// here and is outside the card is a click on the dimmed terminal.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !card.convert(card.bounds, to: self).contains(point) { onDismiss?() }
    }

    /// ⎋ from anywhere in the card but the text view, which answers it itself.
    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }

    @objc private func save() { onSave?() }
    @objc private func reload() { onReload?() }
    @objc private func dismiss() { onDismiss?() }

    @objc private func bannerAction(_ sender: NSButton) {
        guard bannerActions.indices.contains(sender.tag) else { return }
        bannerActions[sender.tag]()
    }

    // MARK: - Appearance

    @objc private func applyMetrics() {
        let inset = ChromeMetrics.length(20)
        for constraint in insets { constraint.constant = inset }
        let pad = ChromeMetrics.length(10)
        for constraint in padding { constraint.constant = pad }
        card.layer?.cornerRadius = ChromeMetrics.length(12)
        stack.spacing = ChromeMetrics.length(8)
        header.spacing = ChromeMetrics.length(6)
        banner.spacing = ChromeMetrics.length(6)
        hostLabel.font = ChromeMetrics.font(12, weight: .semibold)
        fileLabel.font = ChromeMetrics.font(12)
        bannerLabel.font = ChromeMetrics.font(11)
        placeholder.font = ChromeMetrics.font(13)
        saveButton.font = ChromeMetrics.font(11)
        icon.symbolConfiguration = ChromeMetrics.symbol(13)
        bannerIcon.symbolConfiguration = ChromeMetrics.symbol(12)
        for button in [reloadButton, closeButton] {
            button.symbolConfiguration = ChromeMetrics.symbol(12, weight: .medium)
        }
        outline.rowHeight = ChromeMetrics.length(20)
        outline.reloadData()
    }

    @objc private func applyGhosttyConfig() {
        editor.applyTheme()
        scrim.needsDisplay = true
    }
}
