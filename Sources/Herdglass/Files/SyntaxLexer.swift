import Foundation

/// What a run of source text is, as far as colouring it goes. Deliberately
/// coarse: these are the classes `bat --theme=ansi` paints with a terminal's
/// sixteen colours, which is the palette the Files card has to work with.
enum TokenKind: CaseIterable, Sendable {
    case keyword, type, function, string, number, comment, attribute, key, variable
    case heading, emphasis, strong, code, link
}

struct SyntaxToken: Equatable, Sendable {
    /// UTF-16, so it applies to an `NSTextStorage` as it stands.
    var range: NSRange
    var kind: TokenKind
}

/// How one language is lexed. A table rather than a grammar: a handful of
/// flags covers the curly-brace family, the scripting languages and the
/// config formats well enough to read by, which is all the card promises.
struct SyntaxLanguage: Sendable {
    enum Style: Sendable { case code, markdown, markup }

    struct StringRule: Sendable {
        var delimiter: [UInt16]
        var multiline = false
        var escapes = true
        /// A character literal, which only counts when it closes within a few
        /// characters — otherwise Rust's `'a` lifetime opens a string that runs
        /// to the end of the line.
        var short = false
    }

    struct BlockComment: Sendable {
        var open: [UInt16]
        var close: [UInt16]
    }

    var name: String
    var style: Style = .code
    var lineComments: [[UInt16]] = []
    /// `#` only starts a comment at the start of a word: `$#`, `a#b` and a URL
    /// fragment are not comments in a shell script or a YAML value.
    var commentNeedsWordStart = false
    var blockComments: [BlockComment] = []
    var strings: [StringRule] = []
    var keywords: Set<String> = []
    var caseInsensitiveKeywords = false
    var capitalizedIsType = false
    var callIsFunction = false
    /// `@decorator`, `@Annotation`, `#available`, `@builtin`.
    var attributeSigils: Set<UInt16> = []
    /// C's `#include` and friends: a `#` that is the first thing on its line.
    var preprocessor = false
    /// Rust's `#[derive(…)]` and `#![…]`.
    var bracketAttributes = false
    var shellVariables = false
    /// Make's `$(VAR)` as well as `${VAR}`.
    var parenVariables = false
    /// Characters an identifier may continue with besides letters, digits and
    /// `_` — the `-` in a CSS property or a YAML key.
    var identifierExtras: Set<UInt16> = []
    /// A word (or, with `stringKeys`, a string) followed by this is a key.
    var keyBefore: UInt16?
    /// …and only when it is the first thing on its line, give or take a YAML
    /// list dash.
    var keyStartsLine = false
    var stringKeys = false
    /// TOML's `[section]` and `[[array]]` at the start of a line.
    var sectionHeaders = false
}

enum SyntaxLexer {
    static func tokens(in text: String, language: SyntaxLanguage) -> [SyntaxToken] {
        let units = Array(text.utf16)
        switch language.style {
        case .code:
            var lexer = CodeLexer(units: units, language: language)
            return lexer.run()
        case .markdown:
            var lexer = MarkdownLexer(units: units)
            return lexer.run()
        case .markup:
            var lexer = MarkupLexer(units: units)
            return lexer.run()
        }
    }
}

// MARK: - Character classes

private enum Unit {
    static let tab: UInt16 = 9, lf: UInt16 = 10, cr: UInt16 = 13, space: UInt16 = 32
    static let bang: UInt16 = 33, quote: UInt16 = 34, hash: UInt16 = 35, dollar: UInt16 = 36
    static let ampersand: UInt16 = 38, apostrophe: UInt16 = 39, lparen: UInt16 = 40, rparen: UInt16 = 41
    static let star: UInt16 = 42, plus: UInt16 = 43, minus: UInt16 = 45, dot: UInt16 = 46, slash: UInt16 = 47
    static let colon: UInt16 = 58, semicolon: UInt16 = 59, lt: UInt16 = 60, equals: UInt16 = 61, gt: UInt16 = 62
    static let question: UInt16 = 63, at: UInt16 = 64, lbracket: UInt16 = 91, backslash: UInt16 = 92
    static let rbracket: UInt16 = 93, underscore: UInt16 = 95, backtick: UInt16 = 96
    static let lbrace: UInt16 = 123, pipe: UInt16 = 124, rbrace: UInt16 = 125, tilde: UInt16 = 126

    static func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
    static func isUpper(_ c: UInt16) -> Bool { c >= 65 && c <= 90 }
    static func isLetter(_ c: UInt16) -> Bool { isUpper(c) || (c >= 97 && c <= 122) }
    static func isAlnum(_ c: UInt16) -> Bool { isLetter(c) || isDigit(c) }
    /// Anything outside ASCII is taken to be a letter, so a non-English
    /// identifier is one word rather than a run of punctuation.
    static func isIdentStart(_ c: UInt16) -> Bool { isLetter(c) || c == underscore || c >= 0x80 }
    static func isIdentPart(_ c: UInt16) -> Bool { isIdentStart(c) || isDigit(c) }
    static func isBlank(_ c: UInt16) -> Bool { c == space || c == tab }
    static func isSpace(_ c: UInt16) -> Bool { isBlank(c) || c == lf || c == cr }
}

/// Shared by the three lexers: the text, the tokens so far, and the questions
/// all of them ask about the line they are on.
private struct Scanner {
    let units: [UInt16]
    var tokens: [SyntaxToken] = []

    init(units: [UInt16]) { self.units = units }

    var count: Int { units.count }

    mutating func add(_ start: Int, _ end: Int, _ kind: TokenKind) {
        guard end > start else { return }
        tokens.append(SyntaxToken(range: NSRange(location: start, length: end - start), kind: kind))
    }

    func matches(_ needle: [UInt16], at index: Int) -> Bool {
        guard !needle.isEmpty, index + needle.count <= units.count else { return false }
        for offset in 0..<needle.count where units[index + offset] != needle[offset] { return false }
        return true
    }

    /// Where `needle` next starts at or after `index`, or nil.
    func find(_ needle: [UInt16], from index: Int, sameLine: Bool = false) -> Int? {
        var i = index
        while i < units.count {
            if sameLine && units[i] == Unit.lf { return nil }
            if matches(needle, at: i) { return i }
            i += 1
        }
        return nil
    }

    func lineEnd(from index: Int) -> Int {
        var i = index
        while i < units.count && units[i] != Unit.lf { i += 1 }
        return i
    }

    func lineStart(of index: Int) -> Int {
        var i = index
        while i > 0 && units[i - 1] != Unit.lf { i -= 1 }
        return i
    }

    /// Only blanks — and, if `allowDash`, YAML's list dashes — between the
    /// start of the line and `index`.
    func startsLine(_ index: Int, allowDash: Bool = false) -> Bool {
        var i = index - 1
        while i >= 0 && units[i] != Unit.lf {
            let c = units[i]
            guard Unit.isBlank(c) || (allowDash && c == Unit.minus) else { return false }
            i -= 1
        }
        return true
    }

    func nextNonBlank(from index: Int) -> Int {
        var i = index
        while i < units.count && Unit.isBlank(units[i]) { i += 1 }
        return i
    }

    func scanIdentifier(from index: Int, extras: Set<UInt16> = []) -> Int {
        var i = index
        while i < units.count && (Unit.isIdentPart(units[i]) || extras.contains(units[i])) { i += 1 }
        return i
    }

    func string(_ start: Int, _ end: Int) -> String {
        String(utf16CodeUnits: Array(units[start..<end]), count: end - start)
    }
}

// MARK: - Code

private struct CodeLexer {
    var scanner: Scanner
    let language: SyntaxLanguage

    init(units: [UInt16], language: SyntaxLanguage) {
        scanner = Scanner(units: units)
        self.language = language
    }

    mutating func run() -> [SyntaxToken] {
        let units = scanner.units
        let n = units.count
        var i = 0
        scan: while i < n {
            let c = units[i]
            if Unit.isSpace(c) {
                i += 1
                continue
            }
            if lineComment(at: i) {
                let end = scanner.lineEnd(from: i)
                scanner.add(i, end, .comment)
                i = end
                continue
            }
            for block in language.blockComments where scanner.matches(block.open, at: i) {
                let close = scanner.find(block.close, from: i + block.open.count)
                let end = close.map { $0 + block.close.count } ?? n
                scanner.add(i, end, .comment)
                i = end
                continue scan
            }
            for rule in language.strings where scanner.matches(rule.delimiter, at: i) {
                guard let end = stringEnd(rule, from: i) else { break }
                scanner.add(i, end, language.stringKeys && isKey(start: i, end: end) ? .key : .string)
                i = end
                continue scan
            }
            if language.sectionHeaders && c == Unit.lbracket && scanner.startsLine(i),
               let close = scanner.find([Unit.rbracket], from: i + 1, sameLine: true) {
                var end = close + 1
                if end < n && units[end] == Unit.rbracket { end += 1 }
                scanner.add(i, end, .type)
                i = end
                continue
            }
            if c == Unit.dollar && (language.shellVariables || language.parenVariables), let end = variableEnd(from: i) {
                scanner.add(i, end, .variable)
                i = end
                continue
            }
            if c == Unit.hash && language.preprocessor && scanner.startsLine(i) {
                let word = scanner.nextNonBlank(from: i + 1)
                let end = scanner.scanIdentifier(from: word)
                scanner.add(i, end, .attribute)
                i = end
                continue
            }
            if c == Unit.hash && language.bracketAttributes, i + 1 < n,
               units[i + 1] == Unit.lbracket || (units[i + 1] == Unit.bang && i + 2 < n && units[i + 2] == Unit.lbracket),
               let close = scanner.find([Unit.rbracket], from: i + 1, sameLine: true) {
                scanner.add(i, close + 1, .attribute)
                i = close + 1
                continue
            }
            if language.attributeSigils.contains(c), i + 1 < n, Unit.isIdentStart(units[i + 1]) {
                let end = scanner.scanIdentifier(from: i + 1, extras: language.identifierExtras)
                scanner.add(i, end, .attribute)
                i = end
                continue
            }
            if Unit.isDigit(c) || (c == Unit.dot && i + 1 < n && Unit.isDigit(units[i + 1])) {
                let end = numberEnd(from: i)
                scanner.add(i, end, .number)
                i = end
                continue
            }
            if Unit.isIdentStart(c) {
                let end = scanner.scanIdentifier(from: i, extras: language.identifierExtras)
                if let kind = classify(start: i, end: end) { scanner.add(i, end, kind) }
                i = end
                continue
            }
            i += 1
        }
        return scanner.tokens
    }

    private func lineComment(at index: Int) -> Bool {
        guard language.lineComments.contains(where: { scanner.matches($0, at: index) }) else { return false }
        guard language.commentNeedsWordStart, index > 0 else { return true }
        let previous = scanner.units[index - 1]
        return Unit.isSpace(previous) || [Unit.semicolon, Unit.lparen, Unit.pipe, Unit.ampersand].contains(previous)
    }

    /// One past the closing delimiter; the end of the line for a string that
    /// may not span lines and never closes; nil for a character literal that
    /// is not one.
    private func stringEnd(_ rule: SyntaxLanguage.StringRule, from start: Int) -> Int? {
        let units = scanner.units
        var i = start + rule.delimiter.count
        // A character literal holds one character, or an escape: `'x'`,
        // `'😀'`, `'\n'`, `'\u{1F600}'`. Anything else is a lifetime, a
        // label or a stray apostrophe.
        if rule.short, i < units.count, units[i] != Unit.backslash {
            let close = i + (UTF16.isLeadSurrogate(units[i]) ? 2 : 1)
            return scanner.matches(rule.delimiter, at: close) ? close + rule.delimiter.count : nil
        }
        while i < units.count {
            if rule.short && i - start > 12 { return nil }
            let c = units[i]
            if rule.escapes && c == Unit.backslash {
                i += 2
                continue
            }
            if scanner.matches(rule.delimiter, at: i) { return i + rule.delimiter.count }
            if c == Unit.lf && !rule.multiline { return rule.short ? nil : i }
            i += 1
        }
        return rule.short ? nil : units.count
    }

    private func numberEnd(from start: Int) -> Int {
        let units = scanner.units
        var i = start
        while i < units.count {
            let c = units[i]
            if Unit.isAlnum(c) || c == Unit.underscore {
                i += 1
            } else if c == Unit.dot, i + 1 < units.count, Unit.isDigit(units[i + 1]) {
                // `1.5`, but not the `..` of a range.
                i += 1
            } else {
                break
            }
        }
        return i
    }

    private func variableEnd(from start: Int) -> Int? {
        let units = scanner.units
        guard start + 1 < units.count else { return nil }
        let next = units[start + 1]
        if next == Unit.lbrace {
            return scanner.find([Unit.rbrace], from: start + 2, sameLine: true).map { $0 + 1 }
        }
        if next == Unit.lparen {
            guard language.parenVariables else { return nil }
            return scanner.find([Unit.rparen], from: start + 2, sameLine: true).map { $0 + 1 }
        }
        guard language.shellVariables else { return nil }
        if Unit.isIdentStart(next) { return scanner.scanIdentifier(from: start + 1) }
        if Unit.isDigit(next) || [Unit.at, Unit.star, Unit.hash, Unit.question, Unit.dollar, Unit.bang, Unit.minus].contains(next) {
            return start + 2
        }
        return nil
    }

    private func isKey(start: Int, end: Int) -> Bool {
        guard let keyBefore = language.keyBefore else { return false }
        let next = scanner.nextNonBlank(from: end)
        guard next < scanner.count, scanner.units[next] == keyBefore else { return false }
        // `std::vector` and `a ::= b` are not keys.
        if keyBefore == Unit.colon, next + 1 < scanner.count, scanner.units[next + 1] == Unit.colon { return false }
        return !language.keyStartsLine || scanner.startsLine(start, allowDash: true)
    }

    private func classify(start: Int, end: Int) -> TokenKind? {
        let word = scanner.string(start, end)
        if language.keywords.contains(language.caseInsensitiveKeywords ? word.lowercased() : word) { return .keyword }
        if isKey(start: start, end: end) { return .key }
        if language.capitalizedIsType && Unit.isUpper(scanner.units[start]) { return .type }
        if language.callIsFunction && end < scanner.count && scanner.units[end] == Unit.lparen { return .function }
        return nil
    }
}

// MARK: - Markdown

private struct MarkdownLexer {
    var scanner: Scanner

    init(units: [UInt16]) { scanner = Scanner(units: units) }

    mutating func run() -> [SyntaxToken] {
        let units = scanner.units
        var lineStart = 0
        var inFence = false
        while lineStart < units.count {
            let lineEnd = scanner.lineEnd(from: lineStart)
            let text = scanner.nextNonBlank(from: lineStart)
            let fence = text + 3 <= lineEnd
                && (scanner.matches(Array("```".utf16), at: text) || scanner.matches(Array("~~~".utf16), at: text))
            if fence || inFence {
                scanner.add(lineStart, lineEnd, .code)
                if fence { inFence.toggle() }
            } else if text < lineEnd && units[text] == Unit.hash && isHeading(from: text, to: lineEnd) {
                scanner.add(text, lineEnd, .heading)
            } else {
                inline(from: marker(at: text, lineEnd: lineEnd), to: lineEnd)
            }
            lineStart = lineEnd + 1
        }
        return scanner.tokens
    }

    private func isHeading(from start: Int, to end: Int) -> Bool {
        var i = start
        while i < end && scanner.units[i] == Unit.hash { i += 1 }
        return i - start <= 6 && (i == end || Unit.isBlank(scanner.units[i]))
    }

    /// A list bullet, an ordered list's number or a blockquote's `>`: coloured
    /// as a keyword, and the inline scan starts after it.
    private mutating func marker(at start: Int, lineEnd: Int) -> Int {
        let units = scanner.units
        guard start < lineEnd else { return start }
        let c = units[start]
        if [Unit.minus, Unit.star, Unit.plus].contains(c), start + 1 < lineEnd, Unit.isBlank(units[start + 1]) {
            scanner.add(start, start + 1, .keyword)
            return start + 2
        }
        if c == Unit.gt {
            scanner.add(start, start + 1, .keyword)
            return start + 1
        }
        var i = start
        while i < lineEnd && Unit.isDigit(units[i]) { i += 1 }
        if i > start, i + 1 < lineEnd, units[i] == Unit.dot || units[i] == Unit.rparen, Unit.isBlank(units[i + 1]) {
            scanner.add(start, i + 1, .keyword)
            return i + 2
        }
        return start
    }

    private mutating func inline(from start: Int, to end: Int) {
        let units = scanner.units
        var i = start
        while i < end {
            let c = units[i]
            if c == Unit.backslash {
                i += 2
                continue
            }
            if c == Unit.backtick, let close = scanner.find([Unit.backtick], from: i + 1, sameLine: true) {
                scanner.add(i, close + 1, .code)
                i = close + 1
                continue
            }
            if c == Unit.star || c == Unit.underscore {
                let double = i + 1 < end && units[i + 1] == c
                let delimiter = double ? [c, c] : [c]
                let opens = i + delimiter.count < end && !Unit.isSpace(units[i + delimiter.count])
                // `snake_case` is not emphasis.
                let wordInside = c == Unit.underscore && i > 0 && Unit.isAlnum(units[i - 1])
                if opens && !wordInside, let close = scanner.find(delimiter, from: i + delimiter.count, sameLine: true) {
                    scanner.add(i, close + delimiter.count, double ? .strong : .emphasis)
                    i = close + delimiter.count
                    continue
                }
                i += delimiter.count
                continue
            }
            if c == Unit.lbracket, let close = scanner.find([Unit.rbracket], from: i + 1, sameLine: true),
               close + 1 < end, units[close + 1] == Unit.lparen,
               let paren = scanner.find([Unit.rparen], from: close + 2, sameLine: true) {
                scanner.add(i, paren + 1, .link)
                i = paren + 1
                continue
            }
            if c == Unit.lt, scanner.matches(Array("http".utf16), at: i + 1),
               let close = scanner.find([Unit.gt], from: i + 1, sameLine: true) {
                scanner.add(i, close + 1, .link)
                i = close + 1
                continue
            }
            i += 1
        }
    }
}

// MARK: - HTML and XML

private struct MarkupLexer {
    var scanner: Scanner

    init(units: [UInt16]) { scanner = Scanner(units: units) }

    mutating func run() -> [SyntaxToken] {
        let units = scanner.units
        let n = units.count
        var i = 0
        while i < n {
            let c = units[i]
            if scanner.matches(Array("<!--".utf16), at: i) {
                let end = scanner.find(Array("-->".utf16), from: i + 4).map { $0 + 3 } ?? n
                scanner.add(i, end, .comment)
                i = end
                continue
            }
            if c == Unit.lt, i + 1 < n,
               Unit.isLetter(units[i + 1]) || [Unit.slash, Unit.question, Unit.bang].contains(units[i + 1]) {
                i = tag(from: i)
                continue
            }
            if c == Unit.ampersand, let close = scanner.find([Unit.semicolon], from: i + 1, sameLine: true), close - i <= 10 {
                scanner.add(i, close + 1, .variable)
                i = close + 1
                continue
            }
            i += 1
        }
        return scanner.tokens
    }

    /// The tag's name as a keyword, its attributes as keys and their values as
    /// strings; answers where the tag ends.
    private mutating func tag(from start: Int) -> Int {
        let units = scanner.units
        let nameChars: Set<UInt16> = [Unit.minus, Unit.colon, Unit.dot]
        var i = start + 1
        while i < units.count && [Unit.slash, Unit.question, Unit.bang].contains(units[i]) { i += 1 }
        let nameEnd = scanner.scanIdentifier(from: i, extras: nameChars)
        scanner.add(i, nameEnd, .keyword)
        i = nameEnd
        while i < units.count && units[i] != Unit.gt {
            let c = units[i]
            if c == Unit.quote || c == Unit.apostrophe {
                let end = scanner.find([c], from: i + 1).map { $0 + 1 } ?? units.count
                scanner.add(i, end, .string)
                i = end
            } else if Unit.isIdentStart(c) {
                let end = scanner.scanIdentifier(from: i, extras: nameChars)
                scanner.add(i, end, .key)
                i = end
            } else {
                i += 1
            }
        }
        return min(i + 1, units.count)
    }
}
