import AppKit
import HerdrClient

/// Every attached host's spaces as one grid of tiles over the terminal, up for
/// as long as the keys that opened it are held: ⌘` to step through them the way
/// ⌘⇥ steps through apps, or ⌥⌘ held on its own for two seconds to see the list
/// without stepping anywhere yet.
///
/// Why it sits beside ⌥⌘↑/↓ and ⌥⌘1…⌥⌘9, which reach the same rows: both of
/// those *land* on a space, and landing costs something — the host selection
/// moves, the panes of the space being left are parked, the keyboard goes with
/// it and the server is told. Walking eight spaces with ⌥⌘↓ therefore switches
/// eight times to arrive once. This is the same walk with the landing deferred
/// to the moment the modifier comes up, which is the whole of what ⌘⇥ does for
/// windows — and the only one of the three that shows you the list it is
/// walking.
struct SpaceSwitcherModel {
    struct Item: Equatable {
        /// Where committing this tile goes. The pair, not a rendered row id: the
        /// window has to select a host as well as a space, and a space id is
        /// only unique within its host.
        var hostId: String
        var spaceId: String
        var hostName: String
        var symbol: String
        var title: String
        var subtitle: String
        var status: AgentStatus = .unknown
        var unread = false
        var badge = 0
        /// The digit that jumps the highlight to this tile, on the tiles a digit
        /// reaches and nowhere else — the same rule the sidebar's hints follow.
        ///
        /// Drawn whether or not Settings has turned ⌥⌘1…⌥⌘9 on, because the
        /// setting buys back nine chords the terminal would otherwise not see
        /// and nine numbers on a sidebar that is always on screen. Neither is
        /// spent here: the digit only answers while the overlay is up, and the
        /// overlay is drawing the number that answers it.
        var digit: String?
        /// The space the window is already showing. Marked rather than moved to
        /// the front: this is the sidebar's list, in the sidebar's order, and a
        /// list that reorders itself under a held key is not one you can aim at.
        var current = false
    }

    var items: [Item] = []
    var highlighted = 0
}

/// The gesture: what the overlay is showing, where the highlight sits, and what
/// ends it. The window owns the key monitors — they are window-scoped and torn
/// down with it — and forwards the keystrokes here.
@MainActor
final class SpaceSwitcher {
    /// How long ⌥⌘ has to be held with nothing else pressed before the overlay
    /// appears. Two seconds because ⌥⌘ is a *prefix* here, not a chord of its
    /// own: ⌥⌘T, ⌥⌘W, ⌥⌘arrows and ⌥⌘digits all begin by holding exactly this,
    /// and a hold has to be long enough that reaching for one of them is never
    /// mistaken for asking to see the list. Any keystroke cancels it, so the
    /// only thing that gets this far is a hold with nothing after it.
    static let holdDuration: TimeInterval = 2

    /// The spaces to show, asked for once, at the moment the overlay opens.
    var spaces: (() -> [SpaceSwitcherModel.Item])?
    /// The space the gesture landed on. Never the one it started from.
    var onCommit: ((SpaceSwitcherModel.Item) -> Void)?

    let view = SpaceSwitcherView()

    private(set) var isOpen = false
    /// Frozen for the length of the gesture. Snapshots keep arriving while the
    /// overlay is up — a space can be made or closed on the server mid-hold —
    /// and an index that moves under a held key commits a different space than
    /// the one the user was looking at.
    private var items: [SpaceSwitcherModel.Item] = []
    private var highlighted = 0
    /// Whether letting go of ⌘ is what commits. True for both key routes, false
    /// when the menu item was clicked: there is then nothing held to let go of,
    /// so the overlay waits for ↩, ⎋ or a click instead.
    private var commitsOnRelease = false
    private var holdTimer: Timer?

    init() {
        view.isHidden = true
        view.onPick = { [weak self] index in self?.pick(index) }
        view.onCancel = { [weak self] in self?.cancel() }
    }

    /// Put the overlay up on the space the window is showing, then step `offset`
    /// from it — ⌘` opens and advances in one press, the way ⌘⇥ does; the ⌥⌘
    /// hold opens on 0 because it was never asking to move.
    func open(advancing offset: Int, commitsOnRelease: Bool) {
        cancelHold()
        guard !isOpen else {
            move(by: offset)
            return
        }
        let items = spaces?() ?? []
        // One space is not a choice: an overlay naming the space you are already
        // in, with no alternative beside it, is a flash of chrome rather than a
        // switcher.
        guard items.count > 1 else { return }
        self.items = items
        self.commitsOnRelease = commitsOnRelease
        isOpen = true
        highlighted = wrap((items.firstIndex(where: \.current) ?? 0) + offset)
        view.isHidden = false
        apply()
    }

    func move(by offset: Int) {
        guard isOpen else { return }
        highlighted = wrap(highlighted + offset)
        apply()
    }

    /// The digit keys, one-based the way the tiles are numbered.
    func jump(to position: Int) {
        guard isOpen, items.indices.contains(position - 1) else { return }
        highlighted = position - 1
        apply()
    }

    func commit() {
        guard isOpen else { return }
        let item = items[highlighted]
        close()
        // Landing on the space that is already showing is how the gesture says
        // "never mind" — holding ⌥⌘ to look at the list and letting go arrives
        // here. Pushing the selection again would take the keyboard off
        // whatever has it and tell the server about a move that did not happen.
        guard !item.current else { return }
        onCommit?(item)
    }

    func cancel() {
        guard isOpen else { return }
        close()
    }

    /// The modifiers moved. Two things hang off that: letting go of ⌘ commits
    /// what the overlay is showing, and holding exactly ⌥⌘ is what starts the
    /// clock that puts it up.
    ///
    /// ⌘ alone is the release test, for both routes, because it is the key both
    /// have in common — the ⌘` route never held ⌥, and a ⌥⌘ hold that gives up
    /// ⌥ while keeping ⌘ is still a hand mid-gesture. That is ⌘⇥'s rule too:
    /// ⇧ comes and goes inside the gesture, ⌘ ends it.
    func modifiersChanged(to modifiers: NSEvent.ModifierFlags) {
        if isOpen {
            guard commitsOnRelease, !modifiers.contains(.command) else { return }
            commit()
            return
        }
        guard modifiers == SpaceKeys.modifiers else {
            cancelHold()
            return
        }
        armHold()
    }

    /// Any keystroke means the ⌥⌘ that is down is the front of a chord, not a
    /// hold. Called for every key the window sees, which is why the timer is the
    /// only state a cancelled hold leaves behind.
    func cancelHold() {
        holdTimer?.invalidate()
        holdTimer = nil
    }

    private func armHold() {
        guard holdTimer == nil else { return }
        holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdDuration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.holdTimer = nil
                self?.holdFired()
            }
        }
    }

    private func holdFired() {
        // The keys have to still be down. A `flagsChanged` this window never saw
        // — the app lost key while the hand was resting on ⌥⌘ — would otherwise
        // put the overlay up two seconds after the gesture stopped happening.
        let modifiers = NSEvent.modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers == SpaceKeys.modifiers else { return }
        open(advancing: 0, commitsOnRelease: true)
    }

    private func pick(_ index: Int) {
        guard isOpen, items.indices.contains(index) else { return }
        highlighted = index
        commit()
    }

    private func close() {
        isOpen = false
        commitsOnRelease = false
        cancelHold()
        view.isHidden = true
        // The items stay: the view reloads its tiles only when they change, so a
        // gesture that opens on the same spaces as the last one reuses them.
    }

    private func wrap(_ index: Int) -> Int {
        guard !items.isEmpty else { return 0 }
        return (index % items.count + items.count) % items.count
    }

    private func apply() {
        view.apply(SpaceSwitcherModel(items: items, highlighted: highlighted))
    }
}

/// The overlay itself: the terminal dimmed, a card of tiles over it, and one
/// line under them saying what is in the tile the highlight is on.
///
/// A view over the terminal area rather than a floating panel: this app has one
/// window on purpose, the keyboard never leaves the pane behind the card (the
/// window stays key, which is what keeps the monitors driving this gesture
/// alive), and the sidebar — which is the same list, at rest — stays readable
/// beside it.
@MainActor
final class SpaceSwitcherView: NSView {
    /// A tile the pointer picked, by index.
    var onPick: ((Int) -> Void)?
    /// A click on the dimmed terminal around the card: not this one.
    var onCancel: (() -> Void)?

    /// Sized like everything else in the chrome, relative to the base font size.
    /// Read by the tiles as well, which is why they are not private.
    fileprivate static let tileWidth: CGFloat = 152
    fileprivate static let tileHeight: CGFloat = 74
    /// A row wide enough to still read as a row. Past this the grid wraps rather
    /// than stretching the card across the whole window.
    private static let maximumColumns = 6

    private let scrim = SwitcherScrimView()
    private let card = NSVisualEffectView()
    private let stack = NSStackView()
    private let grid = NSStackView()
    private let caption = NSTextField(labelWithString: "")
    private var tiles: [SpaceTile] = []
    /// How many tiles the last build put on a row, so `layout` can tell a resize
    /// that changes the answer from one that does not.
    private var columns = 0
    /// The card's padding, kept because it moves with the base font size.
    private var padding: [NSLayoutConstraint] = []
    private var model = SpaceSwitcherModel()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        card.material = .hudWindow
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true

        grid.orientation = .vertical
        grid.alignment = .centerX

        caption.alignment = .center
        caption.textColor = .secondaryLabelColor
        caption.lineBreakMode = .byTruncatingTail
        // The tiles decide how wide the card is. A space with six tabs has a
        // long line under it, and a line allowed its own width would widen the
        // card past the grid it is describing — and, on a narrow window, past
        // the window.
        caption.setContentCompressionResistancePriority(.init(rawValue: 1), for: .horizontal)

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.setViews([grid, caption], in: .leading)

        for view in [scrim, card] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        // The card's inset is four constraints rather than the stack's own
        // `edgeInsets`: a vertical stack aligned on `centerX` honours the insets
        // along its axis and not across it, which left the tiles flush with the
        // card's sides and the last one clipped by its rounded corner.
        padding = [
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            card.bottomAnchor.constraint(equalTo: stack.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ]
        NSLayoutConstraint.activate(padding + [
            scrim.topAnchor.constraint(equalTo: topAnchor),
            scrim.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrim.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            caption.widthAnchor.constraint(lessThanOrEqualTo: grid.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func apply(_ model: SpaceSwitcherModel) {
        let changed = model.items != self.model.items
        self.model = model
        if changed || tiles.count != model.items.count { rebuild() }
        applyHighlight()
        // Read as it is built rather than watched for, because the overlay is
        // built afresh on every gesture: the dim is the terminal's own colour, so
        // a config reload has to reach it, and the only reload that matters is
        // one that happened while it was down.
        scrim.needsDisplay = true
    }

    /// The card is centred in whatever width the window has, so a window resize
    /// or a sidebar drag can change how many tiles fit on a row. Rebuilding from
    /// `layout` settles on the next pass — the column count it computes is then
    /// the one it built with — rather than looping.
    override func layout() {
        super.layout()
        guard !isHidden, !tiles.isEmpty, columnsThatFit(tiles.count) != columns else { return }
        rebuild()
        applyHighlight()
    }

    /// Clicking a tile is picking it; clicking the dimmed terminal around the
    /// card is not picking any. A click on the card itself does neither: it is
    /// the frame around the choice, not part of it.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = tiles.firstIndex(where: { $0.convert($0.bounds, to: self).contains(point) }) {
            onPick?(index)
        } else if !card.convert(card.bounds, to: self).contains(point) {
            onCancel?()
        }
    }

    private func rebuild() {
        let spacing = ChromeMetrics.length(8)
        let padding = ChromeMetrics.length(16)
        card.layer?.cornerRadius = ChromeMetrics.length(16)
        caption.font = ChromeMetrics.font(11)
        grid.spacing = spacing
        stack.spacing = ChromeMetrics.length(10)
        for constraint in self.padding { constraint.constant = padding }

        tiles = model.items.map { SpaceTile($0) }
        columns = columnsThatFit(tiles.count)
        grid.setViews([], in: .leading)
        for start in stride(from: 0, to: tiles.count, by: columns) {
            let row = NSStackView(views: Array(tiles[start..<min(start + columns, tiles.count)]))
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = spacing
            grid.addView(row, in: .leading)
        }
    }

    /// How many tiles fit across the window this overlay is over, never more
    /// than a row's worth and never fewer than one.
    private func columnsThatFit(_ count: Int) -> Int {
        guard count > 0 else { return 1 }
        let tile = ChromeMetrics.length(Self.tileWidth)
        let spacing = ChromeMetrics.length(8)
        let available = max(bounds.width - ChromeMetrics.length(80), tile)
        let fit = Int((available + spacing) / (tile + spacing))
        return max(1, min(min(count, Self.maximumColumns), fit))
    }

    private func applyHighlight() {
        for (index, tile) in tiles.enumerated() {
            tile.highlight(index == model.highlighted)
        }
        // The tiles say where each space is; the one line under them says what is
        // running in the space being pointed at, which is the thing that decides
        // whether it is the one wanted. A space with no tabs says so.
        let item = model.items.indices.contains(model.highlighted) ? model.items[model.highlighted] : nil
        caption.stringValue = item?.subtitle ?? ""
        caption.isHidden = caption.stringValue.isEmpty
    }
}

/// One space. Two lines, in the sidebar's vocabulary: the host it is on above,
/// with the digit that reaches it, and the space itself below, with its status
/// dot and its unread count.
private final class SpaceTile: NSView {
    private let dot = StatusDotView()
    private let icon = NSImageView()
    private let hostLabel = NSTextField(labelWithString: "")
    private let digitLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let badge = BadgeView()
    private let isCurrent: Bool
    private var highlighted = false

    init(_ item: SpaceSwitcherModel.Item) {
        isCurrent = item.current
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = ChromeMetrics.length(10)

        icon.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = ChromeMetrics.symbol(10)
        hostLabel.stringValue = item.hostName
        hostLabel.font = ChromeMetrics.font(10)
        hostLabel.lineBreakMode = .byTruncatingTail
        digitLabel.stringValue = item.digit ?? ""
        digitLabel.font = ChromeMetrics.font(10, weight: .medium)
        // Hidden rather than empty: a stack view drops a hidden view from its
        // layout, and an empty label past the ninth tile would otherwise leave
        // the gap a digit sits in.
        digitLabel.isHidden = item.digit == nil
        titleLabel.stringValue = item.title
        titleLabel.font = ChromeMetrics.font(13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        dot.update(status: item.status, unread: item.unread)
        badge.count = item.badge

        // The labels take the slack, so the count sits on the trailing edge the
        // way a sidebar row's badge does and a long name truncates instead of
        // widening the tile it is in.
        for label in [hostLabel, titleLabel] {
            label.setContentHuggingPriority(.init(rawValue: 1), for: .horizontal)
            label.setContentCompressionResistancePriority(.init(rawValue: 1), for: .horizontal)
        }

        // The digit leads and the count trails. A sidebar row puts its key hint
        // on the right because the row is one line and the right is where the
        // spare room is; a tile has two, and a dim number stacked directly over
        // a count pill reads as one number written twice.
        let hostRow = NSStackView(views: [digitLabel, icon, hostLabel])
        let titleRow = NSStackView(views: [dot, titleLabel, badge])
        for row in [hostRow, titleRow] {
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = ChromeMetrics.length(5)
        }

        let stack = NSStackView(views: [hostRow, titleRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = ChromeMetrics.length(5)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let side = ChromeMetrics.length(10)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: ChromeMetrics.length(SpaceSwitcherView.tileWidth)),
            heightAnchor.constraint(equalToConstant: ChromeMetrics.length(SpaceSwitcherView.tileHeight)),
            dot.widthAnchor.constraint(equalToConstant: side),
            dot.heightAnchor.constraint(equalToConstant: side),
            icon.widthAnchor.constraint(equalToConstant: ChromeMetrics.length(13)),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ChromeMetrics.length(11)),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ChromeMetrics.length(11)),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            hostRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            titleRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        highlight(false)
    }

    required init?(coder: NSCoder) { nil }

    /// Where the gesture is pointing. The space it started from is outlined
    /// instead, so a held key shows both where you are and where you would land
    /// — one of the two things ⌥⌘↑/↓ cannot say.
    func highlight(_ on: Bool) {
        highlighted = on
        needsDisplay = true
        titleLabel.textColor = on ? .alternateSelectedControlTextColor : .labelColor
        let secondary: NSColor = on
            ? .alternateSelectedControlTextColor.withAlphaComponent(0.75)
            : .secondaryLabelColor
        hostLabel.textColor = secondary
        icon.contentTintColor = secondary
        digitLabel.textColor = on ? secondary : .tertiaryLabelColor
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // A tile is a tile whether or not it is the one being pointed at, so the
        // quiet ones carry a fill too — text alone on the card's own material
        // reads as space between tiles rather than as one of them. The outline
        // is "you are here", which the highlight then covers: while it is on the
        // space it started from, where you are and where you would land are the
        // same tile and one mark is enough.
        layer?.backgroundColor = highlighted
            ? NSColor.selectedContentBackgroundColor.cgColor
            : NSColor.quaternaryLabelColor.cgColor
        layer?.borderWidth = isCurrent && !highlighted ? 1 : 0
        layer?.borderColor = NSColor.tertiaryLabelColor.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// The terminal, dimmed while the overlay is up.
///
/// This is the terminal area, so the dim is ghostty's background at partial
/// alpha rather than a semantic colour — the same rule the unfocused-split scrim
/// follows, and for the same reason: a semantic grey over a terminal palette is
/// the one combination that can come out lighter than what it is dimming.
private final class SwitcherScrimView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = GhosttyRuntime.config.terminalBackground.withAlphaComponent(0.55).cgColor
    }
}
