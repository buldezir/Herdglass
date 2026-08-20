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
    private var isApplyingModel = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowHeight = 42
        outline.indentationPerLevel = 12
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

        emptyLabel.font = .systemFont(ofSize: 11)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 3
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        addButton.title = "Add Host…"
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        addButton.imagePosition = .imageLeading
        addButton.bezelStyle = .inline
        addButton.isBordered = false
        addButton.font = .systemFont(ofSize: 11, weight: .medium)
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
    }

    required init?(coder: NSCoder) { nil }

    func apply(_ model: SidebarModel) {
        let structureChanged = model.structure != self.model.structure
        self.model = model

        isApplyingModel = true
        defer { isApplyingModel = false }

        if structureChanged {
            outline.reloadData()
            for host in model.hosts where !collapsedHosts.contains(host.id) {
                outline.expandItem(host.id)
            }
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

    private func syncSelection() {
        guard let selectedId = model.selectedId else {
            outline.deselectAll(nil)
            return
        }
        let row = outline.row(forItem: selectedId)
        guard row >= 0 else { return }
        guard outline.selectedRow != row else { return }
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
        guard !isApplyingModel else { return }
        guard let id = outline.item(atRow: outline.selectedRow) as? String else { return }
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
    private let badge = BadgeView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        subtitleLabel.font = .systemFont(ofSize: 10)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingHead
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let text = NSStackView(views: [titleLabel, subtitleLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let row = NSStackView(views: [dot, icon, spinner, text, badge])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
            icon.widthAnchor.constraint(equalToConstant: 14),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ row: SidebarModel.Row) {
        titleLabel.stringValue = row.title
        titleLabel.font = .systemFont(ofSize: 12, weight: row.unread ? .semibold : .medium)
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
        toolTip = row.subtitle.isEmpty ? row.title : "\(row.title)\n\(row.subtitle)"
    }
}

/// Filled status dot, ringed while the pane is unread.
private final class StatusDotView: NSView {
    private var status: AgentStatus = .unknown
    private var unread = false

    override var intrinsicContentSize: NSSize { NSSize(width: 10, height: 10) }
    override var wantsUpdateLayer: Bool { false }

    func update(status: AgentStatus, unread: Bool) {
        guard status != self.status || unread != self.unread else { return }
        self.status = status
        self.unread = unread
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = unread ? 2.5 : 1.5
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
        let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.75, dy: 0.75))
        ring.lineWidth = 1.5
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

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        label.font = .systemFont(ofSize: 9, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(greaterThanOrEqualTo: label.widthAnchor, constant: 10),
            heightAnchor.constraint(equalToConstant: 15),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
    }
}
