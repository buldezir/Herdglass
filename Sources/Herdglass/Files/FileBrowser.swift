import AppKit
import HerdrClient
import UniformTypeIdentifiers

/// One row of the Files card's tree. An `NSObject` because `NSOutlineView`
/// keeps expansion by item identity, and a Swift class boxed for Objective-C
/// is a fresh box each time it crosses.
@MainActor
final class FileNode: NSObject {
    let path: String
    let name: String
    let kind: RemoteFileEntry.Kind
    let isSymlink: Bool
    /// A row that is a message rather than a file: "Loading…", the entries a
    /// capped listing left out, or why a folder could not be listed.
    let isNote: Bool
    /// Nil until the folder has been listed.
    var children: [FileNode]?
    var truncated = false
    var error: String? {
        didSet { errorRow = error.map { FileNode(note: $0) } }
    }
    var isLoading = false

    init(path: String, name: String, kind: RemoteFileEntry.Kind, isSymlink: Bool = false) {
        self.path = path
        self.name = name
        self.kind = kind
        self.isSymlink = isSymlink
        isNote = false
    }

    init(note: String) {
        path = ""
        name = note
        kind = .other
        isSymlink = false
        isNote = true
    }

    var isDirectory: Bool { kind == .directory }

    /// What the outline shows under this folder. The note rows are made once
    /// and kept: the outline asks for a child many times and expects the same
    /// object back each time.
    var rows: [FileNode] {
        guard let children else { return [loadingRow] }
        var rows = children
        if let errorRow { rows.append(errorRow) }
        if truncated { rows.append(moreRow) }
        return rows
    }

    private lazy var loadingRow = FileNode(note: "Loading…")
    private lazy var moreRow = FileNode(note: "More entries not shown")
    private var errorRow: FileNode?

    func child(named name: String) -> String {
        path == "/" ? "/" + name : path + "/" + name
    }
}

/// The Files card: browse, read and edit the files of the host a space is on,
/// without opening an editor in one of its panes.
///
/// The card is anchored to what it was opened on — a host and the folder the
/// selected pane was in — the way a file drop belongs to the pane it started
/// in. Picking another space or host while it is up changes what is behind
/// the card, not the card: a document with unsaved edits must keep saving to
/// the host it came from. Nothing about the card is a pane, a tab or a split;
/// it sits over the terminal area and owns nothing Herdr does.
///
/// It never hides with unsaved changes — every way out asks first — so what
/// it keeps between openings is only the tree, and only for the same host and
/// root.
@MainActor
final class FileBrowser: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// The card went away; the keyboard should go back to the pane.
    var onClose: (() -> Void)?

    let view = FileBrowserView()
    private(set) var isOpen = false

    private struct Document {
        var path: String
        var name: String
        var token: String
    }

    private weak var session: SessionController?
    private var hostName = ""
    private var root: RemoteRoot?
    private var rootNode: FileNode?
    private var document: Document?
    /// Bumped by every edit; a save remembers the count it sent, so typing
    /// while it is in flight still leaves the document dirty.
    private var changeCount = 0
    private var savedChangeCount = 0
    private var isSaving = false
    /// Latest-wins counters: a root, or a file, that was asked for and then
    /// superseded before it arrived is dropped rather than shown.
    private var rootGeneration = 0
    private var openGeneration = 0
    /// Raised while a listing redraws its folder. `reloadItem(_:reloadChildren:)`
    /// re-expands every open folder it reloads, that folder included, and posts
    /// `itemWillExpand` for each, inside the call. Taken for the user's expand,
    /// that listed the folder again, whose reload listed it again: the tree
    /// redrew itself for as long as a folder was open.
    private var isRedrawingListing = false

    override init() {
        super.init()
        view.isHidden = true
        view.outline.dataSource = self
        view.outline.delegate = self
        view.outline.target = self
        view.outline.action = #selector(rowClicked)
        view.outline.doubleAction = #selector(rowDoubleClicked)
        view.onDismiss = { [weak self] in self?.close() }
        view.onSave = { [weak self] in self?.save() }
        view.onReload = { [weak self] in self?.reload() }
        view.editor.onCancel = { [weak self] in self?.close() }
        view.editor.onChange = { [weak self] in
            guard let self else { return }
            self.changeCount += 1
            self.updateHeader()
        }
    }

    var isDirty: Bool { document != nil && changeCount != savedChangeCount }

    var canSave: Bool { isDirty && view.editor.isEditable && !isSaving }

    /// Find, Find Next and Find Previous answer while the keyboard is in the
    /// card and there is a file to search — and not over a pane, where ⌘F is
    /// the terminal's.
    var canFind: Bool {
        guard isOpen, !view.editor.isHidden, let responder = view.window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: view)
    }

    func performFind(_ sender: Any?) {
        guard canFind else { return }
        view.editor.performFind(sender)
    }

    /// Take the keyboard, unless something in the card already has it.
    func focus() {
        guard isOpen, let window = view.window else { return }
        if let responder = window.firstResponder as? NSView, responder.isDescendant(of: view) { return }
        window.makeFirstResponder(view.outline)
    }

    // MARK: - Opening and closing

    /// Put the card up on `session`'s host, rooted at the repository around
    /// `directory` (or `directory` itself, or the home directory). Already up,
    /// it only takes the keyboard back to the tree.
    func open(session: SessionController, hostName: String, directory: String?) {
        if isOpen {
            view.window?.makeFirstResponder(view.outline)
            return
        }
        isOpen = true
        view.isHidden = false
        view.needsLayout = true
        view.hideBanner()
        let sameHost = self.session === session && self.hostName == hostName
        self.session = session
        self.hostName = hostName
        if !sameHost {
            root = nil
            rootNode = nil
            view.outline.reloadData()
        }
        updateHeader()
        view.window?.makeFirstResponder(view.outline)

        rootGeneration += 1
        let generation = rootGeneration
        view.setBusy(true)
        session.files({ try $0.resolveRoot(from: directory) }) { [weak self] result in
            guard let self, self.isOpen, generation == self.rootGeneration else { return }
            self.view.setBusy(false)
            switch result {
            case .success(let root):
                if root == self.root, let node = self.rootNode {
                    self.refresh(node)
                } else {
                    self.root = root
                    let node = FileNode(path: root.path, name: root.displayPath, kind: .directory)
                    self.rootNode = node
                    self.view.outline.reloadData()
                    self.load(node)
                }
                self.updateHeader()
            case .failure(let error):
                self.view.showBanner(error.localizedDescription)
            }
        }
    }

    /// ⎋, ⌘J, ⌘W, the close button, a click on the scrim: put the card away,
    /// after asking about unsaved changes.
    func close() {
        guard isOpen else { return }
        confirmDiscard { [weak self] proceed in
            guard proceed else { return }
            self?.finishClose()
        }
    }

    private func finishClose() {
        isOpen = false
        rootGeneration += 1
        openGeneration += 1
        document = nil
        changeCount = 0
        savedChangeCount = 0
        view.isHidden = true
        view.hideBanner()
        view.showPlaceholder("Select a file")
        view.outline.deselectAll(nil)
        onClose?()
    }

    /// Ask what to do with unsaved changes — Save, Don't Save, Cancel — and
    /// answer whether whoever asked may go on. Answers at once when there is
    /// nothing to lose.
    func confirmDiscard(_ completion: @escaping (Bool) -> Void) {
        guard isDirty, let document, let window = view.window else {
            completion(true)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Save changes to \(document.name)?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        let discard = alert.addButton(withTitle: "Don't Save")
        discard.keyEquivalent = "d"
        discard.keyEquivalentModifierMask = .command
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                self?.save(completion: completion)
            case .alertSecondButtonReturn:
                self?.savedChangeCount = self?.changeCount ?? 0
                completion(true)
            default:
                completion(false)
            }
        }
    }

    // MARK: - Files

    private func load(_ node: FileNode) {
        guard node.isDirectory, !node.isLoading, let session else { return }
        node.isLoading = true
        let path = node.path
        session.files({ try $0.list(path) }) { [weak self, weak node] result in
            guard let self, let node else { return }
            node.isLoading = false
            switch result {
            case .success(let listing):
                node.children = self.merge(listing.entries, into: node)
                node.truncated = listing.truncated
                node.error = nil
            case .failure(let error):
                node.children = node.children ?? []
                node.error = error.localizedDescription.components(separatedBy: "\n").last ?? "Could not list this folder."
            }
            self.isRedrawingListing = true
            self.view.outline.reloadItem(node === self.rootNode ? nil : node, reloadChildren: true)
            self.isRedrawingListing = false
        }
    }

    /// The new listing, reusing the nodes that were already there so a folder
    /// that was open stays open, with what was listed in it, across a refresh.
    private func merge(_ entries: [RemoteFileEntry], into node: FileNode) -> [FileNode] {
        var existing: [String: FileNode] = [:]
        for child in node.children ?? [] { existing[child.name] = child }
        return entries.map { entry in
            if let old = existing[entry.name], old.kind == entry.kind, old.isSymlink == entry.isSymlink { return old }
            return FileNode(path: node.child(named: entry.name), name: entry.name, kind: entry.kind, isSymlink: entry.isSymlink)
        }
    }

    /// List again every folder that is open, from `node` down. A collapsed one
    /// is listed again when it is next opened (`outlineViewItemWillExpand`).
    private func refresh(_ node: FileNode) {
        guard node === rootNode || view.outline.isItemExpanded(node) else { return }
        for child in node.children ?? [] where child.isDirectory {
            refresh(child)
        }
        load(node)
    }

    private func open(_ node: FileNode) {
        guard node.kind == .file, node.path != document?.path else { return }
        confirmDiscard { [weak self] proceed in
            guard let self else { return }
            guard proceed else {
                self.selectDocumentRow()
                return
            }
            self.read(node.path, name: node.name)
        }
    }

    private func read(_ path: String, name: String) {
        guard let session else { return }
        openGeneration += 1
        let generation = openGeneration
        document = nil
        changeCount = 0
        savedChangeCount = 0
        view.hideBanner()
        view.showPlaceholder("Loading \(name)…")
        view.setBusy(true)
        updateHeader(file: relativePath(path))
        session.files({ try $0.read(path) }) { [weak self] result in
            guard let self, self.isOpen, generation == self.openGeneration else { return }
            self.view.setBusy(false)
            switch result {
            case .success(let contents):
                self.show(contents, path: path, name: name)
            case .failure(let error):
                self.view.showPlaceholder("")
                self.view.showBanner(error.localizedDescription)
            }
            self.updateHeader()
        }
    }

    /// The file in the editor, or a line saying why it is not: too large to
    /// send, binary, or not UTF-8 — none of which a text view can edit safely.
    private func show(_ contents: RemoteFileContents, path: String, name: String) {
        guard let data = contents.data else {
            view.showPlaceholder("\(name) is \(Self.size(contents.size)) — larger than the \(Self.size(RemoteFiles.readLimit)) the card opens.")
            return
        }
        guard !data.prefix(8192).contains(0) else {
            view.showPlaceholder("\(name) is a binary file (\(Self.size(contents.size))).")
            return
        }
        guard let text = String(data: data, encoding: .utf8) else {
            view.showPlaceholder("\(name) is not UTF-8 text.")
            return
        }
        let firstLine = text.prefix { $0 != "\n" }
        document = Document(path: path, name: name, token: contents.token)
        view.editor.load(text, language: SyntaxLanguage.detect(filename: name, firstLine: firstLine), editable: contents.writable)
        view.showEditor()
        if !contents.writable { view.showBanner("Read-only: you do not have permission to write \(name) on \(hostName).") }
    }

    /// ⌘S. `force` skips the check that the file has not moved on the host,
    /// which is what Overwrite in the conflict banner means.
    func save(force: Bool = false, completion: ((Bool) -> Void)? = nil) {
        guard let document, let session, view.editor.isEditable, isDirty || force, !isSaving else {
            completion?(!isDirty)
            return
        }
        let data = Data(view.editor.text.utf8)
        let token = force ? nil : document.token
        let path = document.path
        let sent = changeCount
        isSaving = true
        view.setBusy(true)
        updateHeader()
        session.files({ try $0.save(data, to: path, expecting: token) }) { [weak self] result in
            guard let self else { return }
            self.isSaving = false
            self.view.setBusy(false)
            // The card may have moved on to another file while this was out.
            guard self.document?.path == path else {
                completion?(false)
                return
            }
            switch result {
            case .success(let token):
                self.document?.token = token
                self.savedChangeCount = sent
                self.view.hideBanner()
                completion?(true)
            case .failure(let error) where RemoteFiles.isChangedOnHost(error):
                self.view.showBanner("\(document.name) changed on \(self.hostName) since you opened it.", actions: [
                    ("Overwrite", { [weak self] in self?.save(force: true) }),
                    ("Reload", { [weak self] in self?.reloadDocument() }),
                ])
                completion?(false)
            case .failure(let error):
                self.view.showBanner(error.localizedDescription)
                completion?(false)
            }
            self.updateHeader()
        }
    }

    /// The reload button: the open folders listed again, and the open file
    /// read again unless that would throw away an edit.
    func reload() {
        if let rootNode { refresh(rootNode) }
        guard let document, !isDirty else { return }
        read(document.path, name: document.name)
    }

    /// The conflict banner's Reload: the host's version, after asking about the
    /// edits it replaces.
    private func reloadDocument() {
        guard let document else { return }
        confirmDiscard { [weak self] proceed in
            guard proceed else { return }
            self?.read(document.path, name: document.name)
        }
    }

    // MARK: - Header

    private func updateHeader(file: String? = nil) {
        view.setHeader(
            host: hostName,
            root: root?.displayPath ?? "",
            file: file ?? document.map { relativePath($0.path) },
            dirty: isDirty,
            canSave: canSave
        )
    }

    private func relativePath(_ path: String) -> String {
        guard let root = root?.path, path.hasPrefix(root + "/") else { return path }
        return String(path.dropFirst(root.count + 1))
    }

    private static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func selectDocumentRow() {
        guard let path = document?.path else {
            view.outline.deselectAll(nil)
            return
        }
        for row in 0..<view.outline.numberOfRows {
            if let node = view.outline.item(atRow: row) as? FileNode, node.path == path {
                view.outline.selectRowIndexes([row], byExtendingSelection: false)
                return
            }
        }
    }

    // MARK: - Clicks

    /// A click on a folder opens or closes it; a click on a file is a selection
    /// change, which opens it.
    @objc private func rowClicked() {
        let row = view.outline.clickedRow
        guard row >= 0, let node = view.outline.item(atRow: row) as? FileNode, node.isDirectory else { return }
        if view.outline.isItemExpanded(node) {
            view.outline.collapseItem(node)
        } else {
            view.outline.expandItem(node)
        }
    }

    /// A double click on a file takes the keyboard into it.
    @objc private func rowDoubleClicked() {
        let row = view.outline.clickedRow
        guard row >= 0, let node = view.outline.item(atRow: row) as? FileNode, node.kind == .file else { return }
        view.window?.makeFirstResponder(view.editor.focusTarget)
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = (item as? FileNode) ?? rootNode else { return 0 }
        return node.rows.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = (item as? FileNode) ?? rootNode else { return FileNode(note: "") }
        return node.rows[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDirectory == true
    }

    // MARK: - NSOutlineViewDelegate

    /// Every expand lists the folder again, so a folder opened after an agent
    /// wrote into it shows what is there now. What was listed before is shown
    /// meanwhile. Not an expand a listing's own reload replays
    /// (`isRedrawingListing`).
    func outlineViewItemWillExpand(_ notification: Notification) {
        guard !isRedrawingListing, let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        load(node)
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? FileNode)?.isNote == false
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = view.outline.selectedRow
        guard row >= 0, let node = view.outline.item(atRow: row) as? FileNode else { return }
        open(node)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let cell = outlineView.makeView(withIdentifier: FileCell.identifier, owner: nil) as? FileCell ?? FileCell()
        cell.configure(node)
        return cell
    }
}

/// A row of the tree: the file's icon and name, dimmed when it is a dotfile
/// or a note rather than a file.
@MainActor
private final class FileCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("file")

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.init(rawValue: 1), for: .horizontal)
        for view in [icon, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        imageView = icon
        textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        widthConstraint = icon.widthAnchor.constraint(equalToConstant: 16)
        heightConstraint = icon.heightAnchor.constraint(equalToConstant: 16)
        NSLayoutConstraint.activate([widthConstraint, heightConstraint].compactMap { $0 })
    }

    required init?(coder: NSCoder) { nil }

    private var widthConstraint: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?

    func configure(_ node: FileNode) {
        // Re-read every time, not in `init`: cells are recycled, and the chrome's
        // size can change between two uses of the same one.
        let side = ChromeMetrics.length(16)
        widthConstraint?.constant = side
        heightConstraint?.constant = side
        label.font = ChromeMetrics.font(12)
        label.stringValue = node.name
        label.textColor = node.isNote || node.isHidden ? .secondaryLabelColor : .labelColor
        icon.isHidden = node.isNote
        icon.image = Self.icon(for: node)
        toolTip = node.isNote ? nil : node.path
    }

    private static func icon(for node: FileNode) -> NSImage? {
        switch node.kind {
        case .directory:
            return NSWorkspace.shared.icon(for: .folder)
        case .file:
            let type = UTType(filenameExtension: (node.name as NSString).pathExtension) ?? .plainText
            return NSWorkspace.shared.icon(for: type)
        case .other:
            return node.isNote ? nil : NSWorkspace.shared.icon(for: .item)
        }
    }
}

private extension FileNode {
    var isHidden: Bool { name.hasPrefix(".") }
}
