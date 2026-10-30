import AppKit

/// The Files card's editor: a plain-text view with no wrapping, a line-number
/// gutter, and highlighting that follows the text a beat behind the keyboard.
///
/// TextKit 1, built by hand rather than taking `NSTextView`'s TextKit 2
/// default: the gutter is an `NSRulerView` that asks the layout manager where
/// each line landed, and non-contiguous layout is what keeps a 4 MB file from
/// being laid out end to end before the first screenful appears.
///
/// Highlighting is a whole-file re-lex on a background queue, debounced after
/// each edit and dropped if the text moved on while it ran. That is simple and
/// it is enough: the lexer is a single pass over UTF-16, a typical source file
/// is lexed faster than a keystroke repeats, and a typed character takes the
/// plain foreground for the 150 ms until the pass lands. Applying the result
/// touches attributes only, through the text storage directly, so it neither
/// registers with undo nor triggers another pass.
@MainActor
final class CodeEditorView: NSView, NSTextStorageDelegate {
    /// The user changed the text.
    var onChange: (() -> Void)?
    /// ⎋ in the editor: the card decides what that means.
    var onCancel: (() -> Void)?

    /// Past this, a file is shown plain: the lex still finishes, but applying a
    /// few hundred thousand attribute runs is a visible stall on the main thread.
    private static let highlightLimit = 1 << 20
    private static let highlightDelay: TimeInterval = 0.15
    /// "No limit" for a container and a text view that never wrap: `FLT_MAX`,
    /// as Apple's own no-wrap recipe has it.
    private static let unbounded = CGFloat(Float.greatestFiniteMagnitude)

    private let scrollView = NSScrollView()
    private let storage = NSTextStorage()
    private let textView: CodeTextView
    private let ruler: LineNumberRuler
    private var language: SyntaxLanguage?
    private var theme = SyntaxTheme()
    /// Bumped on every change of text, so a pass that started against older
    /// text can tell and throw its result away.
    private var generation = 0
    private var pending: DispatchWorkItem?
    /// `load` replaces the text through the storage, which reports an edit like
    /// any other; that one is not the user's.
    private var isLoading = false
    private static let lexQueue = DispatchQueue(label: "herdglass.files.lex", qos: .userInitiated)

    override init(frame frameRect: NSRect) {
        let layoutManager = NSLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: Self.unbounded, height: Self.unbounded))
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)
        textView = CodeTextView(frame: .zero, textContainer: container)
        ruler = LineNumberRuler(scrollView: scrollView, orientation: .verticalRuler)
        super.init(frame: frameRect)

        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: Self.unbounded, height: Self.unbounded)
        textView.autoresizingMask = [.width, .height]
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.onCancel = { [weak self] in self?.onCancel?() }
        storage.delegate = self

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        ruler.clientView = textView
        ruler.textView = textView
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        applyTheme()
    }

    required init?(coder: NSCoder) { nil }

    var text: String { textView.string }

    /// The text view, for the window to hand the keyboard to.
    var focusTarget: NSView { textView }

    var isEditable: Bool { textView.isEditable }

    /// A Find menu item, handed to the text view's finder, which reads what to
    /// do from the item's tag.
    func performFind(_ sender: Any?) {
        textView.performTextFinderAction(sender)
    }

    /// Show `text`, coloured as `language`, and start a fresh undo history.
    func load(_ text: String, language: SyntaxLanguage?, editable: Bool) {
        self.language = language
        isLoading = true
        storage.setAttributedString(NSAttributedString(string: text, attributes: theme.base))
        isLoading = false
        textView.isEditable = editable
        textView.undoManager?.removeAllActions()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scroll(.zero)
        rehighlight(after: 0)
    }

    func clear() {
        load("", language: nil, editable: false)
    }

    /// Re-read the font and colours: the ghostty config was reloaded.
    func applyTheme() {
        theme = SyntaxTheme()
        textView.backgroundColor = theme.background
        textView.insertionPointColor = theme.foreground
        textView.typingAttributes = theme.base
        textView.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor]
        scrollView.backgroundColor = theme.background
        scrollView.drawsBackground = true
        ruler.theme = theme
        rehighlight(after: 0)
    }

    // MARK: - NSTextStorageDelegate

    nonisolated func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {
            generation += 1
            if !isLoading { onChange?() }
            rehighlight(after: Self.highlightDelay)
        }
    }

    // MARK: - Highlighting

    private func rehighlight(after delay: TimeInterval) {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.startPass() }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func startPass() {
        let generation = generation
        let text = storage.string
        let language = (text.utf16.count <= Self.highlightLimit) ? language : nil
        Self.lexQueue.async { [weak self] in
            let tokens = language.map { SyntaxLexer.tokens(in: text, language: $0) } ?? []
            let lineStarts = LineNumberRuler.lineStarts(of: text)
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.apply(tokens, lineStarts: lineStarts)
            }
        }
    }

    private func apply(_ tokens: [SyntaxToken], lineStarts: [Int]) {
        let length = storage.length
        storage.beginEditing()
        storage.setAttributes(theme.base, range: NSRange(location: 0, length: length))
        for token in tokens where NSMaxRange(token.range) <= length {
            storage.addAttributes(theme.attributes(for: token.kind), range: token.range)
        }
        storage.endEditing()
        ruler.lineStarts = lineStarts
    }
}

/// The text view itself: two behaviours a code editor needs that `NSTextView`
/// does not have.
@MainActor
final class CodeTextView: NSTextView {
    var onCancel: (() -> Void)?

    /// ⎋ is `complete:` in a text view, which offers word completions — not
    /// something a code viewer wants, and in the card ⎋ means "put it away".
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// A new line starts where the one before it did.
    override func insertNewline(_ sender: Any?) {
        let text = string as NSString
        let caret = selectedRange().location
        let line = text.lineRange(for: NSRange(location: caret, length: 0))
        var end = line.location
        while end < caret, end < text.length {
            let c = text.character(at: end)
            guard c == 0x20 || c == 0x09 else { break }
            end += 1
        }
        let indent = text.substring(with: NSRange(location: line.location, length: end - line.location))
        super.insertNewline(sender)
        if !indent.isEmpty { insertText(indent, replacementRange: selectedRange()) }
    }
}

/// Line numbers down the editor's leading edge, drawn for the lines in view.
@MainActor
final class LineNumberRuler: NSRulerView {
    weak var textView: NSTextView?
    var theme = SyntaxTheme() {
        didSet { updateThickness() }
    }

    /// UTF-16 offset of the first character of each line. Kept by the editor
    /// from the same background pass as the highlighting, so finding the first
    /// visible line is a binary search rather than a count of every newline
    /// above it on each scroll.
    var lineStarts: [Int] = [0] {
        didSet {
            updateThickness()
            needsDisplay = true
        }
    }

    nonisolated static func lineStarts(of text: String) -> [Int] {
        var starts = [0]
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 10 { starts.append(offset) }
        }
        return starts
    }

    private var attributes: [NSAttributedString.Key: Any] {
        let font = NSFont.monospacedDigitSystemFont(ofSize: max(theme.font.pointSize - 2, 8), weight: .regular)
        return [.font: font, .foregroundColor: theme.gutter]
    }

    private func updateThickness() {
        let digits = max(String(lineStarts.count).count, 3)
        let width = (String(repeating: "8", count: digits) as NSString).size(withAttributes: attributes).width
        let thickness = ceil(width + 16)
        if ruleThickness != thickness { ruleThickness = thickness }
    }

    /// The fill is clipped to the ruler by hand. Since the macOS 14 SDK a view
    /// no longer clips its drawing to its bounds (`clipsToBounds` is false),
    /// and the dirty rect the scroll view hands a ruler can reach across the
    /// text: filling it as given painted the background over every glyph,
    /// leaving numbers beside an empty page.
    override func draw(_ dirtyRect: NSRect) {
        theme.background.setFill()
        dirtyRect.intersection(bounds).fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let length = (textView.string as NSString).length
        let visible = textView.visibleRect
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let attributes = self.attributes
        let origin = textView.textContainerOrigin

        var line = firstLine(atOrBefore: characters.location)
        while line < lineStarts.count, lineStarts[line] <= NSMaxRange(characters), lineStarts[line] <= length {
            let start = lineStarts[line]
            let fragment: NSRect
            if start >= length {
                // The empty line after a final newline has no glyph of its own.
                fragment = layoutManager.extraLineFragmentRect
                if fragment.isEmpty { break }
            } else {
                fragment = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: start),
                                                          effectiveRange: nil, withoutAdditionalLayout: true)
            }
            let top = convert(NSPoint(x: 0, y: fragment.minY + origin.y), from: textView).y
            let label = "\(line + 1)" as NSString
            let size = label.size(withAttributes: attributes)
            let y = top + (fragment.height - size.height) / 2
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y), withAttributes: attributes)
            line += 1
        }
    }

    private func firstLine(atOrBefore offset: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }
}
