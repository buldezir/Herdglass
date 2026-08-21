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

    static let height: CGFloat = 32

    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let newButton = NSButton()
    private let separator = NSBox()
    private var model = TabBarModel()
    private var items: [String: TabItemView] = [:]

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

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: separator.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: newButton.leadingAnchor, constant: -4),
            newButton.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            newButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            newButton.widthAnchor.constraint(equalToConstant: 22),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            // The stack is the scroll view's document: it may grow past the
            // clip view horizontally, never vertically.
            stack.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor),
            stack.widthAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

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
    private var tracking: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = 5

        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        paneCount.font = .systemFont(ofSize: 9, weight: .semibold)
        paneCount.textColor = .tertiaryLabelColor

        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")
        close.symbolConfiguration = .init(pointSize: 8, weight: .semibold)
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

        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -4),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 12),
            close.heightAnchor.constraint(equalToConstant: 12),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 24),
            widthAnchor.constraint(equalToConstant: Self.width),
        ])
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

    func configure(_ item: TabBarModel.Item) {
        label.stringValue = item.title
        label.font = .systemFont(ofSize: 11, weight: item.unread ? .semibold : .medium)
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

    override var intrinsicContentSize: NSSize { NSSize(width: 8, height: 8) }

    func update(status: AgentStatus, unread: Bool) {
        guard status != self.status || unread != self.unread else { return }
        self.status = status
        self.unread = unread
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let core = bounds.insetBy(dx: unread ? 2 : 1, dy: unread ? 2 : 1)
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
        let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        ring.lineWidth = 1.25
        StatusStyle.attentionColor(status).setStroke()
        ring.stroke()
    }
}
