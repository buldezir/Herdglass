import AppKit
import HerdrClient

/// One place that decides how an agent status looks and reads, so the sidebar
/// dot, the attention ring and the window subtitle can never drift apart.
enum StatusStyle {
    /// Fill for the status dot. System colors so light and dark both work.
    static func color(_ status: AgentStatus) -> NSColor {
        switch status {
        case .blocked: return .systemOrange
        case .done: return .systemBlue
        case .working: return .systemGreen
        case .idle: return .tertiaryLabelColor
        case .unknown: return .tertiaryLabelColor
        }
    }

    /// Ring drawn around whatever is asking to be looked at.
    static func attentionColor(_ status: AgentStatus) -> NSColor {
        status == .blocked ? .systemOrange : .systemBlue
    }

    static func label(_ status: AgentStatus) -> String {
        switch status {
        case .blocked: return "needs input"
        case .done: return "done"
        case .working: return "working"
        case .idle: return "idle"
        case .unknown: return "no agent"
        }
    }

    static func symbolName(_ status: AgentStatus) -> String {
        switch status {
        case .blocked: return "exclamationmark.bubble.fill"
        case .done: return "checkmark.circle.fill"
        case .working: return "circle.dotted"
        case .idle: return "circle"
        case .unknown: return "circle.dashed"
        }
    }
}

// MARK: - Views

/// The two small views that draw a status and an unread count. They live beside
/// `StatusStyle` rather than inside the sidebar because a sidebar row is no
/// longer the only thing that draws them — a space switcher tile draws the same
/// dot and the same count, and two spellings of "this space needs input" is
/// exactly what one place deciding is meant to prevent.

/// Filled status dot, ringed while the pane is unread.
final class StatusDotView: NSView {
    private var status: AgentStatus = .unknown
    private var unread = false

    override var intrinsicContentSize: NSSize {
        let side = ChromeMetrics.length(10)
        return NSSize(width: side, height: side)
    }

    override var wantsUpdateLayer: Bool { false }

    func update(status: AgentStatus, unread: Bool) {
        guard status != self.status || unread != self.unread else { return }
        self.status = status
        self.unread = unread
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Insets and line widths are fractions of the dot, not fixed points, so
        // a dot that grows with the base font size still reads as a dot.
        let inset = bounds.width * (unread ? 0.25 : 0.15)
        let core = bounds.insetBy(dx: inset, dy: inset)
        if status == .unknown {
            // Nothing to report: an outline keeps the column aligned without
            // implying a state.
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

/// Small count pill, hidden at zero.
final class BadgeView: NSView {
    var count = 0 {
        didSet {
            guard count != oldValue else { return }
            label.stringValue = "\(count)"
            isHidden = count == 0
            invalidateIntrinsicContentSize()
        }
    }

    private let label = NSTextField(labelWithString: "")
    private var height: NSLayoutConstraint?

    /// A pill is as wide as its count and no wider. Without this it has no
    /// intrinsic width at all — only a `>=` against the label — and a stack view
    /// hands a view with no width of its own whatever slack the row has, which
    /// is how a count of 1 ended up in a pill wide enough for four digits.
    override var intrinsicContentSize: NSSize {
        NSSize(width: label.intrinsicContentSize.width + 10, height: ChromeMetrics.length(15))
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        let height = heightAnchor.constraint(equalToConstant: 0)
        self.height = height
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(greaterThanOrEqualTo: label.widthAnchor, constant: 10),
            height,
        ])
        applyChromeMetrics()
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    func applyChromeMetrics() {
        label.font = ChromeMetrics.font(9, weight: .semibold)
        height?.constant = ChromeMetrics.length(15)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
    }
}
