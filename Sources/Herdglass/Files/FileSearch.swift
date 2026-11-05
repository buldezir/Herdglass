import AppKit
import HerdrClient
import UniformTypeIdentifiers

/// The Files card's fuzzy search: the field over the tree, and the list of
/// matches that stands in for the tree while the field has something in it.
///
/// The keyboard stays in the field while the arrows move through the list, as
/// in every editor's quick-open, so refining the query never means clicking
/// back into it. Moving through the list opens nothing: an open is an SSH read
/// and can ask about an unsaved edit, which is no way to browse. Return or a
/// click opens the match; Return and a double click also take the keyboard
/// into the file once it is there.
///
/// It owns no file listing of its own. `FileBrowser` fetches one when a search
/// first needs it (`onNeedsIndex`) and hands it over (`setIndex`); a search
/// over the previous listing goes on meanwhile.
@MainActor
final class FileSearch: NSObject, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    /// Open the file at this path, relative to the root; `true` to put the
    /// keyboard in it once it is shown.
    var onOpen: ((String, Bool) -> Void)?
    /// A search has started and there is no listing to search, or only an old one.
    var onNeedsIndex: (() -> Void)?
    /// The query went from empty to not, or back: the tree or the list.
    var onActiveChange: ((Bool) -> Void)?
    /// ⎋ in an empty field.
    var onDismiss: (() -> Void)?
    /// ↓ in an empty field: down into the tree.
    var onLeaveToTree: (() -> Void)?

    let field: NSSearchField
    let table: FileResultsTableView
    let status: NSTextField

    /// The most a search shows. More than anyone scrolls through; the query is
    /// the way to the rest.
    nonisolated static let limit = 200

    private(set) var isActive = false
    private var query = ""
    private var index: FuzzyIndex?
    private var truncated = false
    private var isIndexing = false
    private var error: String?
    private var matches: [FuzzyMatch] = []
    private var total = 0
    /// Latest-wins: a search that finishes after the next keystroke's started
    /// is dropped, and so is an index built for a root since replaced.
    private var searchGeneration = 0
    private var indexGeneration = 0
    private static let queue = DispatchQueue(label: "dev.herdglass.file-search", qos: .userInitiated)

    init(field: NSSearchField, table: FileResultsTableView, status: NSTextField) {
        self.field = field
        self.table = table
        self.status = status
        super.init()
        field.delegate = self
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.doubleAction = #selector(doubleClicked)
        table.onReturn = { [weak self] in self?.openSelected(focusEditor: true) }
        table.onEscape = { [weak self] in self?.focusField() }
        table.onType = { [weak self] text in self?.type(text) }
        table.onUpPastTop = { [weak self] in self?.focusField() }
    }

    // MARK: - What the browser tells it

    /// ⌘P: the keyboard to the field, with what is in it selected so typing
    /// replaces it.
    func focusField() {
        guard let window = field.window else { return }
        window.makeFirstResponder(field)
        if isActive { onNeedsIndex?() }
    }

    /// A listing of the root, finished. Prepared off the main thread, because
    /// a hundred thousand paths take a moment, and the query on screen is run
    /// against it as soon as it is ready.
    func setIndex(_ listing: RemoteFileIndex) {
        indexGeneration += 1
        let generation = indexGeneration
        let paths = listing.paths
        let truncated = listing.truncated
        // Which tool listed the root, where someone wondering why a file is
        // missing will look: `fd` and `rg` honour every `.gitignore`, `find`
        // only skips folders by name.
        status.toolTip = "Listed with \(listing.source == .git ? "git ls-files" : listing.source.rawValue)"
        Self.queue.async { [weak self] in
            let index = FuzzyIndex(paths: paths)
            DispatchQueue.main.async {
                guard let self, generation == self.indexGeneration else { return }
                self.index = index
                self.truncated = truncated
                self.isIndexing = false
                self.error = nil
                self.run()
            }
        }
    }

    func setIndexing() {
        isIndexing = true
        error = nil
        updateStatus()
    }

    func setIndexFailed(_ message: String) {
        isIndexing = false
        error = message
        updateStatus()
    }

    /// Another root: the listing is no longer the right one. The query stays —
    /// ⌘P on a closed card can be typed into before the root is known — and
    /// waits for the new root's listing.
    func reset() {
        indexGeneration += 1
        index = nil
        truncated = false
        isIndexing = false
        error = nil
        run()
    }

    /// Empty the field and go back to the tree.
    func clear() {
        field.stringValue = ""
        queryChanged()
    }

    // MARK: - Searching

    private func queryChanged() {
        query = field.stringValue
        let active = !query.trimmingCharacters(in: .whitespaces).isEmpty
        if active != isActive {
            isActive = active
            onActiveChange?(active)
            if active { onNeedsIndex?() }
        }
        run()
    }

    private func run() {
        searchGeneration += 1
        let generation = searchGeneration
        guard isActive, let index else {
            show([], total: 0)
            return
        }
        let query = query
        Self.queue.async { [weak self] in
            let result = index.search(query, limit: Self.limit)
            DispatchQueue.main.async {
                guard let self, generation == self.searchGeneration else { return }
                self.show(result.matches, total: result.total)
            }
        }
    }

    private func show(_ matches: [FuzzyMatch], total: Int) {
        self.matches = matches
        self.total = total
        table.reloadData()
        if !matches.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
        updateStatus()
    }

    private func updateStatus() {
        let text: String
        if let error {
            text = error
        } else if index == nil {
            text = isIndexing ? "Listing files…" : ""
        } else if matches.isEmpty {
            text = "No matching files"
        } else {
            let count = total.formatted()
            let files = (index?.count ?? 0).formatted()
            text = truncated
                ? "\(count) of the first \(files) files"
                : "\(count) \(total == 1 ? "match" : "matches")"
        }
        status.stringValue = text
        status.isHidden = !isActive || text.isEmpty
    }

    // MARK: - Opening

    private func openSelected(focusEditor: Bool) {
        let row = table.selectedRow
        guard matches.indices.contains(row) else { return }
        onOpen?(matches[row].path, focusEditor)
    }

    @objc private func clicked() {
        let row = table.clickedRow
        guard matches.indices.contains(row) else { return }
        onOpen?(matches[row].path, false)
    }

    @objc private func doubleClicked() {
        let row = table.clickedRow
        guard matches.indices.contains(row) else { return }
        onOpen?(matches[row].path, true)
    }

    /// A character typed in the list goes on the end of the query.
    private func type(_ text: String) {
        guard let window = field.window else { return }
        window.makeFirstResponder(field)
        guard let editor = field.currentEditor() else { return }
        editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
        editor.insertText(text)
    }

    private func moveSelection(by delta: Int) {
        guard !matches.isEmpty else { return }
        let row = max(0, min(matches.count - 1, table.selectedRow + delta))
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    // MARK: - NSSearchFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        queryChanged()
    }

    /// The field keeps the keyboard and the list follows the arrows. ⎋ empties
    /// a field that has something in it and puts the card away otherwise —
    /// the card's own ⎋, one press later.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            if isActive { moveSelection(by: 1) } else { onLeaveToTree?() }
            return true
        case #selector(NSResponder.moveUp(_:)):
            if isActive { moveSelection(by: -1) }
            return true
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)):
            moveSelection(by: visibleRows)
            return true
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)):
            moveSelection(by: -visibleRows)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            openSelected(focusEditor: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if field.stringValue.isEmpty { onDismiss?() } else { clear() }
            return true
        default:
            return false
        }
    }

    private var visibleRows: Int {
        max(1, Int(table.visibleRect.height / max(table.rowHeight, 1)) - 1)
    }

    // MARK: - NSTableViewDataSource / NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        matches.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: FileResultCell.identifier, owner: nil) as? FileResultCell ?? FileResultCell()
        cell.configure(matches[row])
        return cell
    }

    /// Drawn as the selection with the keyboard in it even while the keyboard
    /// is in the field, because that is where Return will go.
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        FileResultRowView()
    }
}

/// The list of matches. Return opens, ⎋ and ↑ off the top go back to the
/// field, and anything typed carries on the query there — the list is only
/// ever a step away from the field.
@MainActor
final class FileResultsTableView: NSTableView {
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?
    var onType: ((String) -> Void)?
    var onUpPastTop: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.shift, .capsLock, .numericPad, .function])
        switch event.keyCode {
        case 36, 76: // Return, Enter
            onReturn?()
            return
        case 53: // ⎋
            onEscape?()
            return
        case 126 where selectedRow <= 0: // ↑ on the first row
            onUpPastTop?()
            return
        default:
            break
        }
        if modifiers.isEmpty, let text = event.characters, !text.isEmpty,
           text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) {
            onType?(text)
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
private final class FileResultRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }
}

/// A match: the file's icon, its name, and the folder it is in, dimmer and
/// giving way first — the name is what was searched for. The characters the
/// query landed on are bold in both.
@MainActor
private final class FileResultCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("match")

    private let icon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let folderLabel = NSTextField(labelWithString: "")
    private var match: FuzzyMatch?
    private var iconSide: NSLayoutConstraint?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        nameLabel.lineBreakMode = .byTruncatingTail
        folderLabel.lineBreakMode = .byTruncatingHead
        // Both give way to the cell, so nothing in the tree column has an
        // opinion about its width; between the two, the folder goes first.
        nameLabel.setContentCompressionResistancePriority(.init(rawValue: 2), for: .horizontal)
        folderLabel.setContentCompressionResistancePriority(.init(rawValue: 1), for: .horizontal)
        nameLabel.setContentHuggingPriority(.init(rawValue: 2), for: .horizontal)
        folderLabel.setContentHuggingPriority(.init(rawValue: 1), for: .horizontal)
        for view in [icon, nameLabel, folderLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        imageView = icon
        textField = nameLabel
        let side = icon.widthAnchor.constraint(equalToConstant: 16)
        iconSide = side
        NSLayoutConstraint.activate([
            side,
            icon.heightAnchor.constraint(equalTo: icon.widthAnchor),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            folderLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 6),
            folderLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            folderLabel.firstBaselineAnchor.constraint(equalTo: nameLabel.firstBaselineAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ match: FuzzyMatch) {
        self.match = match
        iconSide?.constant = ChromeMetrics.length(16)
        let path = match.path as NSString
        let name = path.lastPathComponent
        icon.image = NSWorkspace.shared.icon(for: UTType(filenameExtension: (name as NSString).pathExtension) ?? .plainText)
        toolTip = match.path
        draw()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { draw() }
    }

    /// Attributed text keeps the colours it was given, so the selection's
    /// white is chosen here rather than left to the label.
    private func draw() {
        guard let match else { return }
        let path = match.path as NSString
        let nameStart = path.length - (path.lastPathComponent as NSString).length
        let selected = backgroundStyle == .emphasized
        let primary: NSColor = selected ? .alternateSelectedControlTextColor : .labelColor
        let secondary: NSColor = selected ? .alternateSelectedControlTextColor.withAlphaComponent(0.75) : .secondaryLabelColor
        let folder = nameStart > 0 ? NSRange(location: 0, length: nameStart - 1) : NSRange(location: 0, length: 0)
        nameLabel.attributedStringValue = Self.text(
            path, NSRange(location: nameStart, length: path.length - nameStart), match.positions,
            size: 12, color: primary, truncating: .byTruncatingTail
        )
        folderLabel.attributedStringValue = Self.text(
            path, folder, match.positions, size: 11, color: secondary, truncating: .byTruncatingHead
        )
    }

    /// The truncation travels in the string: an attributed value overrides the
    /// label's own `lineBreakMode`, and without it the text is clipped.
    private static func text(
        _ path: NSString, _ range: NSRange, _ positions: [Int],
        size: CGFloat, color: NSColor, truncating: NSLineBreakMode
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = truncating
        let text = NSMutableAttributedString(string: path.substring(with: range), attributes: [
            .font: ChromeMetrics.font(size),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
        let bold = ChromeMetrics.font(size, weight: .bold)
        for position in positions where NSLocationInRange(position, range) {
            text.addAttribute(.font, value: bold, range: NSRange(location: position - range.location, length: 1))
        }
        return text
    }
}
