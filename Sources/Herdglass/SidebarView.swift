import AppKit
import HerdrClient

/// What the sidebar draws: hosts as folders, the spaces on each host as their
/// children. Built by `MainWindowController` so this view stays a pure renderer
/// with no opinion about sessions or sockets.
struct SidebarModel {
    enum Kind {
        case host
        case space
    }

    struct Row {
        var id: String
        var kind: Kind
        var title: String
        var subtitle: String
        var status: AgentStatus = .unknown
        var unread: Bool = false
        var badge: Int = 0
        /// A remembered host that is not attached: shown, dimmed, and dialled
        /// when the user picks it.
        var offline: Bool = false
        var busy: Bool = false
        var symbol: String?
        /// The key that selects this row, already rendered (`⇧⌘3`). Nil on
        /// every row no key reaches — a host row, and any space past the ninth
        /// counting down the whole sidebar — because a number drawn where
        /// nothing answers it is what made the old prefixes noise. A row's key
        /// therefore moves when a host above it attaches or gains a space: it
        /// names where the row *is*, which is the only thing a nine-key set
        /// spread over every host can honestly name.
        var shortcut: String?
    }

    var hosts: [Row] = []
    var spaces: [String: [Row]] = [:]
    var selectedId: String?
    var emptyMessage: String?

    /// Row identity in display order. Only a change here needs a full reload;
    /// status and title churn is applied to the existing cells instead.
    var structure: [String] {
        hosts.flatMap { [$0.id] + (spaces[$0.id]?.map(\.id) ?? []) }
    }

    func row(_ id: String) -> Row? {
        if let host = hosts.first(where: { $0.id == id }) { return host }
        for rows in spaces.values {
            if let space = rows.first(where: { $0.id == id }) { return space }
        }
        return nil
    }

    func isHost(_ id: String) -> Bool {
        hosts.contains { $0.id == id }
    }
}

@MainActor
final class SidebarView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// Whether the user drove the change with the pointer or the keyboard.
    /// Arrow-key browsing should not yank focus out of the sidebar; a click
    /// should, because clicking a space means "let me type in it".
    enum SelectionSource {
        case pointer
        case keyboard
    }

    var onSelectHost: ((String, SelectionSource) -> Void)?
    var onSelectSpace: ((String, SelectionSource) -> Void)?
    var onAddHost: (() -> Void)?
    var onReconnectHost: ((String) -> Void)?
    var onDisconnectHost: ((String) -> Void)?
    var onForgetHost: ((String) -> Void)?
    var onNewSpace: ((String) -> Void)?

    private static let cellIdentifier = NSUserInterfaceItemIdentifier("SidebarCell")

    private let scroll = NSScrollView()
    private let outline = NSOutlineView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let addButton = NSButton()
    private var model = SidebarModel()
    private var collapsedHosts: Set<String> = []
    /// The row this view last selected itself. The outline view reports our own
    /// pushes through the same delegate callback as the user's clicks, and the
    /// id is the only thing that tells the two apart — a flag set around the
    /// push cannot, because the notification does not arrive during it.
    private var appliedSelectionId: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowHeight = ChromeMetrics.length(42)
        outline.indentationPerLevel = ChromeMetrics.length(12)
        outline.backgroundColor = .clear
        outline.selectionHighlightStyle = .regular
        outline.allowsEmptySelection = true
        outline.allowsMultipleSelection = false
        outline.dataSource = self
        outline.delegate = self
        outline.menu = buildContextMenu()

        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = ChromeMetrics.font(11)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 3
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        addButton.title = "Add Host…"
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        addButton.imagePosition = .imageLeading
        addButton.bezelStyle = .inline
        addButton.isBordered = false
        addButton.font = ChromeMetrics.font(11, weight: .medium)
        addButton.contentTintColor = .secondaryLabelColor
        addButton.target = self
        addButton.action = #selector(addHostTapped)
        addButton.setAccessibilityIdentifier("AddHostButton")
        addButton.translatesAutoresizingMaskIntoConstraints = false

        // Nothing in here may have an opinion about how wide the sidebar is: a
        // subview pinned to both edges hugs at its own width, which ties with
        // the split item's holding priority and pins the sidebar to its minimum
        // — the divider then silently refuses to drag.
        for view in [emptyLabel, addButton] as [NSView] {
            view.setContentHuggingPriority(.init(rawValue: 1), for: .horizontal)
            view.setContentCompressionResistancePriority(.init(rawValue: 1), for: .horizontal)
        }

        addSubview(scroll)
        addSubview(emptyLabel)
        addSubview(addButton)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -2),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            emptyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            addButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            addButton.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])

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

    /// A new base font size. Rows are recycled by identifier, so the cells
    /// already made have to be told; the row height has to move with them or
    /// larger text simply clips.
    @objc private func chromeMetricsDidChange() {
        emptyLabel.font = ChromeMetrics.font(11)
        addButton.font = ChromeMetrics.font(11, weight: .medium)
        outline.rowHeight = ChromeMetrics.length(42)
        outline.indentationPerLevel = ChromeMetrics.length(12)
        outline.enumerateAvailableRowViews { view, _ in
            (view.view(atColumn: 0) as? SidebarCell)?.applyChromeMetrics()
        }
        refreshVisibleRows()
    }

    func apply(_ model: SidebarModel) {
        let structureChanged = model.structure != self.model.structure
        self.model = model

        if structureChanged {
            outline.reloadData()
            for host in model.hosts where !collapsedHosts.contains(host.id) {
                outline.expandItem(host.id)
            }
            // A reload keeps the selection by index, which may now be a
            // different row; take whatever survived as ours so the next sync
            // does not read it as a selection the user made.
            appliedSelectionId = selectedRowId
        } else {
            // Same rows, new state: reconfigure in place so scroll position and
            // the user's collapsed hosts survive every snapshot.
            refreshVisibleRows()
        }

        emptyLabel.stringValue = model.emptyMessage ?? ""
        emptyLabel.isHidden = !model.hosts.isEmpty || model.emptyMessage == nil
        syncSelection()
    }

    private func refreshVisibleRows() {
        for row in 0..<outline.numberOfRows {
            guard
                let id = outline.item(atRow: row) as? String,
                let data = model.row(id),
                let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCell
            else { continue }
            cell.configure(data)
        }
    }

    /// The row the outline view has selected right now.
    private var selectedRowId: String? {
        guard outline.selectedRow >= 0 else { return nil }
        return outline.item(atRow: outline.selectedRow) as? String
    }

    /// Point the outline view at the row the model says is selected — unless the
    /// user has already moved it somewhere we have not been told about yet.
    ///
    /// `NSOutlineView` does not post `outlineViewSelectionDidChange` from inside
    /// the click that caused it; the notification arrives afterwards. A snapshot
    /// landing in between therefore used to find the outline on the row the user
    /// just clicked and the model still on the old one, and push the old one
    /// back — so the click was undone before it was ever reported, and the
    /// notification that would have reported it was swallowed as one of ours.
    /// That is what made picking a space work only sometimes: the more snapshots
    /// per second, the more often the click lost the race.
    private func syncSelection() {
        let current = selectedRowId
        // Something other than us moved it: leave it alone and let
        // `outlineViewSelectionDidChange` report it.
        guard current == appliedSelectionId else { return }
        guard let selectedId = model.selectedId else {
            guard current != nil else { return }
            appliedSelectionId = nil
            outline.deselectAll(nil)
            return
        }
        guard current != selectedId else { return }
        let row = outline.row(forItem: selectedId)
        guard row >= 0 else { return }
        appliedSelectionId = selectedId
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }

    // MARK: - Context menu

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        // `menuNeedsUpdate` decides what applies to the clicked row; AppKit's
        // own autoenabling would just overwrite it.
        menu.autoenablesItems = false
        for (title, action) in [
            ("New Space", #selector(newSpaceForClickedRow)),
            ("Reconnect", #selector(reconnectClickedRow)),
            ("Disconnect", #selector(disconnectClickedRow)),
            ("Remove Host", #selector(forgetClickedRow)),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    /// The host the context menu applies to: the clicked row, or the host that
    /// owns the clicked space.
    private var clickedHostId: String? {
        guard outline.clickedRow >= 0, let id = outline.item(atRow: outline.clickedRow) as? String else { return nil }
        if model.isHost(id) { return id }
        return model.spaces.first { $0.value.contains { $0.id == id } }?.key
    }

    @objc private func addHostTapped() { onAddHost?() }

    @objc private func newSpaceForClickedRow() {
        guard let id = clickedHostId else { return }
        onNewSpace?(id)
    }

    @objc private func reconnectClickedRow() {
        guard let id = clickedHostId else { return }
        onReconnectHost?(id)
    }

    @objc private func disconnectClickedRow() {
        guard let id = clickedHostId else { return }
        onDisconnectHost?(id)
    }

    @objc private func forgetClickedRow() {
        guard let id = clickedHostId else { return }
        onForgetHost?(id)
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let id = item as? String else { return model.hosts.count }
        return model.spaces[id]?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let id = item as? String else { return model.hosts[index].id }
        return model.spaces[id]?[index].id ?? ""
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let id = item as? String else { return false }
        return !(model.spaces[id]?.isEmpty ?? true)
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let id = item as? String, let data = model.row(id) else { return nil }
        let cell = outlineView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? SidebarCell
            ?? SidebarCell(identifier: Self.cellIdentifier)
        cell.configure(data)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let id = selectedRowId else { return }
        // Our own `syncSelection` echoes back through here; only a row the user
        // moved to is news for the window.
        guard id != appliedSelectionId else { return }
        appliedSelectionId = id
        let source: SelectionSource = switch NSApp.currentEvent?.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown: .pointer
        default: .keyboard
        }
        if model.isHost(id) {
            onSelectHost?(id, source)
        } else {
            onSelectSpace?(id, source)
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let id = notification.userInfo?["NSObject"] as? String else { return }
        collapsedHosts.insert(id)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let id = notification.userInfo?["NSObject"] as? String else { return }
        collapsedHosts.remove(id)
    }
}

// MARK: - Menu validation

extension SidebarView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        let host = clickedHostId.flatMap { model.row($0) }
        for item in menu.items {
            switch item.title {
            case "New Space":
                item.isEnabled = host?.offline == false
            case "Reconnect":
                item.isEnabled = host != nil
            case "Disconnect":
                item.isEnabled = host?.offline == false
            default:
                item.isEnabled = host != nil
            }
        }
    }
}

// MARK: - Cell

private final class SidebarCell: NSTableCellView {
    private let dot = StatusDotView()
    private let icon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private let badge = BadgeView()
    /// The metrics that move with the base font size, kept so a change can be
    /// applied to a cell the outline view is recycling rather than rebuilding.
    private var dotSize: [NSLayoutConstraint] = []
    private var iconWidth: NSLayoutConstraint?
    private var unread = false

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        subtitleLabel.textColor = .secondaryLabelColor
        // Tail, not head: a space's subtitle is its tabs in order, and the first
        // one is the one the user is most likely to want. Head truncation was
        // right when this line was a path — `…/projects/app` keeps the part that
        // identifies it — and is exactly wrong for a list.
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Dim and to the right: the row's job is to say where the work is, and
        // a shortcut you already know is the first thing that should stop
        // competing with the name for the eye.
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .right

        icon.contentTintColor = .secondaryLabelColor

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let text = NSStackView(views: [titleLabel, subtitleLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let row = NSStackView(views: [dot, icon, spinner, text, hint, badge])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        dotSize = [
            dot.widthAnchor.constraint(equalToConstant: 0),
            dot.heightAnchor.constraint(equalToConstant: 0),
        ]
        let iconWidth = icon.widthAnchor.constraint(equalToConstant: 0)
        self.iconWidth = iconWidth
        NSLayoutConstraint.activate(dotSize + [
            iconWidth,
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyChromeMetrics()
    }

    required init?(coder: NSCoder) { nil }

    /// Everything sized from the base font size, in one place, so a cell being
    /// recycled and a cell being made take the same path.
    func applyChromeMetrics() {
        titleLabel.font = ChromeMetrics.font(12, weight: unread ? .semibold : .medium)
        subtitleLabel.font = ChromeMetrics.font(10)
        hint.font = ChromeMetrics.font(10, weight: .medium)
        icon.symbolConfiguration = ChromeMetrics.symbol(11)
        for constraint in dotSize { constraint.constant = ChromeMetrics.length(10) }
        iconWidth?.constant = ChromeMetrics.length(14)
        dot.invalidateIntrinsicContentSize()
        badge.applyChromeMetrics()
    }

    func configure(_ row: SidebarModel.Row) {
        titleLabel.stringValue = row.title
        // The weight says "unread", so the fonts are re-applied from here rather
        // than only when the base size moves.
        unread = row.unread
        applyChromeMetrics()
        titleLabel.textColor = row.offline ? .secondaryLabelColor : .labelColor
        subtitleLabel.stringValue = row.subtitle
        subtitleLabel.isHidden = row.subtitle.isEmpty

        // A host says what it is with an icon; a space says how its agents are
        // doing with a dot. Showing both would be two indicators for one row.
        let isHost = row.kind == .host
        icon.isHidden = !isHost || row.busy
        dot.isHidden = isHost
        if let symbol = row.symbol {
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        icon.contentTintColor = row.unread
            ? StatusStyle.attentionColor(row.status)
            : (row.offline ? .tertiaryLabelColor : .secondaryLabelColor)

        if row.busy {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
        spinner.isHidden = !row.busy

        if !isHost { dot.update(status: row.status, unread: row.unread) }
        badge.count = row.badge

        // The hint and the badge share the trailing edge, and the badge wins:
        // a count is news, a shortcut is the same every time you look at it.
        // The tooltip carries the key either way, so it is still there to be
        // found on the one row that is busy enough to hide it.
        hint.stringValue = row.shortcut ?? ""
        hint.isHidden = row.shortcut == nil || row.badge > 0

        toolTip = [row.title, row.subtitle.isEmpty ? nil : row.subtitle, row.shortcut]
            .compactMap { $0 }
            .joined(separator: "\n")
    }
}

/// Filled status dot, ringed while the pane is unread.
private final class StatusDotView: NSView {
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
private final class BadgeView: NSView {
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
