import AppKit
import HerdrClient

/// The tabs of the selected space, as Herdr reports them.
struct TabBarModel {
    struct Item {
        var id: String
        var number: UInt
        var title: String
        var status: AgentStatus
        var unread: Bool
        var paneCount: Int
        var selected: Bool
    }

    var items: [Item] = []
    /// Whether this space can take another tab at all — false while the host is
    /// not attached, so the `+` is not offering something that cannot happen.
    var canCreate = false

    var structure: [String] { items.map(\.id) }
}

/// Horizontal strip above the terminal, one entry per Herdr tab. Scrolls rather
/// than shrinking, so a tab title stays readable however many tabs there are.
@MainActor
final class TabBarView: NSView {
    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?
    var onNew: (() -> Void)?

    /// The strip's own height before the base font size scales it; `length`
    /// makes it the real one.
    static let height: CGFloat = 32

    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let newButton = NSButton()
    private let separator = NSBox()
    private var model = TabBarModel()
    private var items: [String: TabItemView] = [:]
    private var heightConstraint: NSLayoutConstraint?
    private var newButtonWidth: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false

        scroll.documentView = stack
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        newButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New tab")
        newButton.bezelStyle = .inline
        newButton.isBordered = false
        newButton.contentTintColor = .secondaryLabelColor
        newButton.toolTip = "New tab (⌘T)"
        newButton.target = self
        newButton.action = #selector(newTapped)
        newButton.setAccessibilityIdentifier("NewTabButton")
        newButton.translatesAutoresizingMaskIntoConstraints = false

        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scroll)
        addSubview(newButton)
        addSubview(separator)

        let heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        let newButtonWidth = newButton.widthAnchor.constraint(equalToConstant: 0)
        self.heightConstraint = heightConstraint
        self.newButtonWidth = newButtonWidth
        NSLayoutConstraint.activate([
            heightConstraint,
            newButtonWidth,
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: separator.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: newButton.leadingAnchor, constant: -4),
            newButton.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            newButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            // The stack is the scroll view's document: it may grow past the
            // clip view horizontally, never vertically.
            stack.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor),
            stack.widthAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.widthAnchor),
        ])
        applyChromeMetrics()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(chromeMetricsDidChange),
            name: ChromeMetrics.didChangeNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func applyChromeMetrics() {
        heightConstraint?.constant = ChromeMetrics.length(Self.height)
        newButtonWidth?.constant = ChromeMetrics.length(22)
        newButton.symbolConfiguration = ChromeMetrics.symbol(12, weight: .medium)
    }

    /// A new base font size: the strip, the `+`, and every tab in it.
    @objc private func chromeMetricsDidChange() {
        applyChromeMetrics()
        for view in items.values { view.applyChromeMetrics() }
        invalidateIntrinsicContentSize()
    }

    func apply(_ model: TabBarModel) {
        let structureChanged = model.structure != self.model.structure
        self.model = model

        if structureChanged {
            for view in stack.views { stack.removeView(view) }
            var reused: [String: TabItemView] = [:]
            for item in model.items {
                let view = items[item.id] ?? TabItemView()
                view.onSelect = { [weak self] in self?.onSelect?(item.id) }
                view.onClose = { [weak self] in self?.onClose?(item.id) }
                reused[item.id] = view
                stack.addView(view, in: .leading)
            }
            items = reused
        }

        for item in model.items {
            items[item.id]?.configure(item)
        }
        newButton.isEnabled = model.canCreate
        if structureChanged { scrollSelectedIntoView() }
    }

    private func scrollSelectedIntoView() {
        guard let id = model.items.first(where: \.selected)?.id, let view = items[id] else { return }
        // Wait for the stack to lay out, or the frame being scrolled to is the
        // one from before this tab existed.
        DispatchQueue.main.async { [weak self] in
            guard let self, view.superview != nil else { return }
            self.scroll.contentView.scrollToVisible(view.frame)
        }
    }

    @objc private func newTapped() { onNew?() }
}

/// One tab. Draws its own background so the selected tab reads as a container
/// for the terminal below it, the way a tab bar is meant to.
private final class TabItemView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    private let dot = TabStatusDot()
    private let label = NSTextField(labelWithString: "")
    private let paneCount = NSTextField(labelWithString: "")
    private let close = NSButton()
    private var isSelected = false
    private var isHovering = false
    private var isUnread = false
    private var tracking: NSTrackingArea?
    /// The metrics that follow the base font size. A tab is a fixed size on
    /// purpose — see `width` — so every one of them is a constraint to move.
    private var dotSize: [NSLayoutConstraint] = []
    private var closeSize: [NSLayoutConstraint] = []
    private var box: [NSLayoutConstraint] = []

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = 5

        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        paneCount.textColor = .tertiaryLabelColor

        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")
        close.bezelStyle = .inline
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        close.target = self
        close.action = #selector(closeTapped)
        // Faded rather than hidden, so it holds its place in the layout — and
        // disabled with it, because a view at `alphaValue = 0` is still
        // hit-tested and an invisible close button is a trap.
        close.alphaValue = 0
        close.isEnabled = false

        // `dot`, `label` and `paneCount` ride a stack that grows from the
        // leading edge; `close` is pinned to the trailing edge on its own and is
        // never hidden, only faded. Both halves matter:
        //
        // An `NSStackView` drops a hidden view from its layout, so a `close`
        // inside it made every tab 17pt wider the moment the pointer touched it
        // — and shoved every tab after it sideways. And a width that follows the
        // text made the whole strip shuffle each time a title changed, which is
        // now, by design, whenever an agent starts or a pane changes directory.
        let row = NSStackView(views: [dot, label, paneCount])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 5
        row.translatesAutoresizingMaskIntoConstraints = false
        close.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        addSubview(close)

        dotSize = [
            dot.widthAnchor.constraint(equalToConstant: 0),
            dot.heightAnchor.constraint(equalToConstant: 0),
        ]
        closeSize = [
            close.widthAnchor.constraint(equalToConstant: 0),
            close.heightAnchor.constraint(equalToConstant: 0),
        ]
        box = [
            heightAnchor.constraint(equalToConstant: 0),
            widthAnchor.constraint(equalToConstant: 0),
        ]
        NSLayoutConstraint.activate(dotSize + closeSize + box + [
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -4),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyChromeMetrics()
    }

    /// One width for every tab, so the strip only ever moves when a tab is
    /// opened or closed — not when a title changes under it and not on hover.
    ///
    /// Sized from the label rather than by eye: the chrome around it takes 55pt
    /// in the worst case (8 leading, the 8pt dot, 5, then 5, a pane count, 4,
    /// the 12pt close button and 7 trailing), and a project-length name like
    /// `simple-mac-launcher` measures 115pt at 11pt medium. Anything longer
    /// still truncates — a tab wide enough for a full path would leave the
    /// short ones mostly empty, and an unselected tab draws no background, so
    /// slack past the text reads as a gap rather than as a tab.
    static let width: CGFloat = 172

    required init?(coder: NSCoder) { nil }

    /// Everything the base font size moves. The width goes with it: the number
    /// above was measured against 11pt medium text, so a tab drawn at twice that
    /// and left 172pt wide would fit four characters.
    func applyChromeMetrics() {
        label.font = ChromeMetrics.font(11, weight: isUnread ? .semibold : .medium)
        paneCount.font = ChromeMetrics.font(9, weight: .semibold)
        close.symbolConfiguration = ChromeMetrics.symbol(8, weight: .semibold)
        for constraint in dotSize { constraint.constant = ChromeMetrics.length(8) }
        for constraint in closeSize { constraint.constant = ChromeMetrics.length(12) }
        box[0].constant = ChromeMetrics.length(24)
        box[1].constant = ChromeMetrics.length(Self.width)
        dot.invalidateIntrinsicContentSize()
    }

    func configure(_ item: TabBarModel.Item) {
        label.stringValue = item.title
        // The weight says "unread", so the fonts are re-applied from here rather
        // than only when the base size moves.
        isUnread = item.unread
        applyChromeMetrics()
        label.textColor = item.selected ? .labelColor : .secondaryLabelColor
        paneCount.stringValue = item.paneCount > 1 ? "\(item.paneCount)" : ""
        paneCount.isHidden = item.paneCount <= 1
        dot.update(status: item.status, unread: item.unread)
        isSelected = item.selected
        toolTip = "Tab \(item.number): \(item.title)"
        setAccessibilityIdentifier("Tab-\(item.id)")
        updateAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    private func updateAppearance() {
        // Semantic colors only: a hardcoded tab background would be wrong in
        // one of the two appearances.
        let background: NSColor = if isSelected {
            .selectedContentBackgroundColor.withAlphaComponent(0.22)
        } else if isHovering {
            .quaternaryLabelColor.withAlphaComponent(0.35)
        } else {
            .clear
        }
        layer?.backgroundColor = background.cgColor
        let showsClose = isHovering || isSelected
        close.alphaValue = showsClose ? 1 : 0
        close.isEnabled = showsClose
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    @objc private func closeTapped() { onClose?() }
}

/// Smaller sibling of the sidebar's dot; a tab has less room to spend.
private final class TabStatusDot: NSView {
    private var status: AgentStatus = .unknown
    private var unread = false

    override var intrinsicContentSize: NSSize {
        let side = ChromeMetrics.length(8)
        return NSSize(width: side, height: side)
    }

    func update(status: AgentStatus, unread: Bool) {
        guard status != self.status || unread != self.unread else { return }
        self.status = status
        self.unread = unread
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.width * (unread ? 0.25 : 0.125)
        let core = bounds.insetBy(dx: inset, dy: inset)
        if status == .unknown {
            let outline = NSBezierPath(ovalIn: core.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 1
            StatusStyle.color(status).setStroke()
            outline.stroke()
        } else {
            StatusStyle.color(status).setFill()
            NSBezierPath(ovalIn: core).fill()
        }
        guard unread else { return }
        let width = max(bounds.width * 0.15, 1)
        let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: width / 2, dy: width / 2))
        ring.lineWidth = width
        StatusStyle.attentionColor(status).setStroke()
        ring.stroke()
    }
}
