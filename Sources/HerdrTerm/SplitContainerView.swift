import AppKit
import HerdrClient

/// Everything the container needs to put a live terminal in a leaf.
struct PaneAttachment {
    var socketPath: String
    var herdrBinary: String
    var executablePath: String
}

/// One tab's panes, laid out the way Herdr says they are split.
///
/// The tree comes from `layout.export`, so the GUI shows the same geometry as
/// the TUI, and dragging a divider pushes the new ratio back to the server
/// rather than keeping a private opinion about it.
@MainActor
final class SplitContainerView: NSView {
    struct Model {
        var tree: LayoutNode?
        var panes: [PaneInfo] = []
        var activePaneId: String?
        var unreadPaneIds: Set<String> = []
        var attachment: PaneAttachment?
    }

    /// The user clicked into a pane, or its bridge exited. Both mean the window
    /// has something to re-evaluate.
    var onActivatePane: ((String) -> Void)?
    var onPaneDetached: (() -> Void)?
    var onSplitRatioChanged: (([Bool], Double) -> Void)?

    private var paneViews: [String: TerminalPaneView] = [:]
    private var splitViews: [String: SplitNodeView] = [:]
    private var structureSignature: String?
    private let placeholder = TerminalPaneView()
    private var model = Model()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        pin(placeholder)
        placeholder.showPlaceholder(
            title: "No pane attached",
            detail: "Connect to a Herdr host to attach a pane."
        )
    }

    required init?(coder: NSCoder) { nil }

    /// The pane the keyboard should go to, when there is one.
    var activePaneView: TerminalPaneView? {
        model.activePaneId.flatMap { paneViews[$0] }
    }

    func focusActivePane() {
        activePaneView?.focusTerminal()
    }

    func allowReattach() {
        for view in paneViews.values { view.allowReattach() }
        placeholder.allowReattach()
    }

    /// Release every pane, and with it every bridge. Called when the window is
    /// closing, so the surfaces go before libghostty's tick does.
    func teardown() {
        clearPanes()
        placeholder.teardown()
    }

    func showPlaceholder(title: String, detail: String, symbol: String = "rectangle.dashed") {
        clearPanes()
        placeholder.isHidden = false
        placeholder.showPlaceholder(title: title, detail: detail, symbol: symbol)
    }

    func apply(_ model: Model) {
        self.model = model
        guard let tree = model.tree, !tree.paneIds.isEmpty else {
            return
        }

        placeholder.isHidden = true
        placeholder.teardown()

        // Panes that left the tree take their bridge with them; keeping them
        // attached would leave `herdr terminal session control` running for a
        // pane nobody is looking at.
        let live = Set(tree.paneIds)
        for (paneId, view) in paneViews where !live.contains(paneId) {
            view.teardown()
            view.removeFromSuperview()
            paneViews.removeValue(forKey: paneId)
        }

        if tree.structureSignature != structureSignature {
            rebuild(tree)
            structureSignature = tree.structureSignature
        }
        applyRatios(tree, path: [])
        decorate()
        attachPanes()
    }

    // MARK: - Hierarchy

    private func rebuild(_ tree: LayoutNode) {
        for view in subviews where view !== placeholder {
            view.removeFromSuperview()
        }
        splitViews.removeAll()
        let root = buildView(tree, path: [])
        pin(root, below: placeholder)
    }

    private func buildView(_ node: LayoutNode, path: [Bool]) -> NSView {
        switch node {
        case .pane(let paneId, _, _):
            guard let paneId else { return NSView() }
            return paneView(paneId)
        case .split(let direction, _, let first, let second):
            let split = SplitNodeView(direction: direction)
            split.onRatioChanged = { [weak self] ratio in
                self?.onSplitRatioChanged?(path, ratio)
            }
            split.addArrangedSubview(buildView(first, path: path + [false]))
            split.addArrangedSubview(buildView(second, path: path + [true]))
            splitViews[Self.key(path)] = split
            return split
        }
    }

    private func paneView(_ paneId: String) -> TerminalPaneView {
        if let existing = paneViews[paneId] { return existing }
        let view = TerminalPaneView()
        view.onActivate = { [weak self] in self?.onActivatePane?(paneId) }
        view.onDetach = { [weak self] in self?.onPaneDetached?() }
        paneViews[paneId] = view
        return view
    }

    private func applyRatios(_ node: LayoutNode, path: [Bool]) {
        guard case .split(_, let ratio, let first, let second) = node else { return }
        splitViews[Self.key(path)]?.setModelRatio(ratio)
        applyRatios(first, path: path + [false])
        applyRatios(second, path: path + [true])
    }

    private func decorate() {
        let panesById = Dictionary(model.panes.map { ($0.paneId, $0) }, uniquingKeysWith: { first, _ in first })
        let isSplit = paneViews.count > 1
        for (paneId, view) in paneViews {
            let pane = panesById[paneId]
            view.decorate(
                active: isSplit && paneId == model.activePaneId,
                attention: model.unreadPaneIds.contains(paneId),
                status: pane?.agentStatus ?? .unknown
            )
        }
    }

    private func attachPanes() {
        guard let attachment = model.attachment else { return }
        for (paneId, view) in paneViews {
            view.attach(
                paneId: paneId,
                socketPath: attachment.socketPath,
                herdrBinary: attachment.herdrBinary,
                executablePath: attachment.executablePath
            )
        }
    }

    private func clearPanes() {
        for (_, view) in paneViews {
            view.teardown()
            view.removeFromSuperview()
        }
        paneViews.removeAll()
        splitViews.removeAll()
        structureSignature = nil
        for view in subviews where view !== placeholder {
            view.removeFromSuperview()
        }
    }

    private func pin(_ view: NSView, below sibling: NSView? = nil) {
        view.translatesAutoresizingMaskIntoConstraints = false
        if let sibling {
            addSubview(view, positioned: .below, relativeTo: sibling)
        } else {
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    private static func key(_ path: [Bool]) -> String {
        path.map { $0 ? "1" : "0" }.joined()
    }
}

/// One split of a tab, holding two subtrees.
///
/// `NSSplitView` reports every resize through `didResizeSubviews`, including the
/// ones caused by the window changing size, so a ratio is only sent to the
/// server when the user actually finished dragging this divider — which is
/// exactly the span of the `mouseDown` tracking loop.
private final class SplitNodeView: NSSplitView {
    /// Smallest useful terminal; below this a pane is not worth showing.
    static let minimumPaneLength: CGFloat = 90

    var onRatioChanged: ((Double) -> Void)?

    /// `NSSplitView.delegate` is weak, and a split view must not be its own
    /// delegate: AppKit's sidebar category answers `respondsToSelector:` by
    /// asking the delegate, so `delegate == self` recurses until the stack dies.
    private let splitDelegate = SplitNodeDelegate()
    private var modelRatio: Double
    private var appliedRatio: Double?
    private var isApplyingRatio = false

    init(direction: SplitDirection) {
        modelRatio = 0.5
        super.init(frame: .zero)
        isVertical = direction == .right
        dividerStyle = .thin
        arrangesAllSubviews = false
        splitDelegate.node = self
        delegate = splitDelegate
    }

    required init?(coder: NSCoder) { nil }

    /// The ratio Herdr says this split has. Applied on the next layout pass, so
    /// it lands after the split view knows how big it is.
    func setModelRatio(_ ratio: Double) {
        guard abs(ratio - modelRatio) > 0.0005 else { return }
        modelRatio = ratio
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard !isApplyingRatio, available > 0 else { return }
        guard appliedRatio == nil || abs((appliedRatio ?? 0) - modelRatio) > 0.0005 else { return }
        isApplyingRatio = true
        setPosition(CGFloat(modelRatio) * available, ofDividerAt: 0)
        isApplyingRatio = false
        appliedRatio = modelRatio
    }

    /// A divider drag is a tracking loop inside `super.mouseDown`; when it
    /// returns, the user has let go and the new ratio is worth publishing.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard available > 0, let first = arrangedSubviews.first else { return }
        let length = isVertical ? first.frame.width : first.frame.height
        let ratio = Double(length / available)
        guard ratio.isFinite, ratio > 0.01, ratio < 0.99 else { return }
        guard abs(ratio - modelRatio) > 0.005 else { return }
        modelRatio = ratio
        appliedRatio = ratio
        onRatioChanged?(ratio)
    }

    /// Length the two panes share, i.e. everything but the divider.
    var available: CGFloat {
        (isVertical ? bounds.width : bounds.height) - dividerThickness
    }

}

/// Keeps a pane from being dragged away to nothing. Separate from the split view
/// itself so the view is never its own delegate.
private final class SplitNodeDelegate: NSObject, NSSplitViewDelegate {
    weak var node: SplitNodeView?

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        max(proposedMinimumPosition, SplitNodeView.minimumPaneLength)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard let available = node?.available else { return proposedMaximumPosition }
        return min(proposedMaximumPosition, available - SplitNodeView.minimumPaneLength)
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        false
    }
}
