import Foundation
import Testing
@testable import Herdglass

/// The tokens of `text` as (source text, kind) pairs, which reads far better in
/// a failed expectation than a list of ranges.
private func lex(_ text: String, _ language: SyntaxLanguage) -> [(String, TokenKind)] {
    let string = text as NSString
    return SyntaxLexer.tokens(in: text, language: language).map { (string.substring(with: $0.range), $0.kind) }
}

private func kinds(_ text: String, _ language: SyntaxLanguage, of kind: TokenKind) -> [String] {
    lex(text, language).filter { $0.1 == kind }.map(\.0)
}

struct SyntaxLexerTests {

    @Test func stringsKeepTheirEscapedQuotesAndCommentsRunToTheirEnd() {
        let swift = """
        let s = "say \\"hi\\"" // trailing
        /* block
           comment */ func go() {}
        """
        #expect(kinds(swift, .swift, of: .string) == ["\"say \\\"hi\\\"\""])
        #expect(kinds(swift, .swift, of: .comment) == ["// trailing", "/* block\n   comment */"])
        #expect(kinds(swift, .swift, of: .keyword) == ["let", "func"])
        #expect(kinds(swift, .swift, of: .function) == ["go"])
    }

    @Test func pythonTripleQuotesSpanLinesAndHashesInsideThemAreNotComments() {
        let python = "def f():\n    '''doc # not a comment\n    more'''\n    return 1.5  # yes\n"
        #expect(kinds(python, .python, of: .string) == ["'''doc # not a comment\n    more'''"])
        #expect(kinds(python, .python, of: .comment) == ["# yes"])
        #expect(kinds(python, .python, of: .number) == ["1.5"])
    }

    @Test func aRangeIsNotADecimalPoint() {
        #expect(kinds("for i in 0..<10 {}", .swift, of: .number) == ["0", "10"])
    }

    @Test func aRustLifetimeIsNotAString() {
        let rust = "fn first<'a>(x: &'a str) -> char { 'x' }"
        #expect(kinds(rust, .rust, of: .string) == ["'x'"])
        #expect(kinds(rust, .rust, of: .keyword).contains("fn"))
    }

    @Test func jsonKeysAreToldApartFromStringValues() {
        let json = #"{"name": "herdglass", "tags": ["a", "b"], "ok": true, "n": -2}"#
        #expect(kinds(json, .json, of: .key) == [#""name""#, #""tags""#, #""ok""#, #""n""#])
        #expect(kinds(json, .json, of: .string) == [#""herdglass""#, #""a""#, #""b""#])
        #expect(kinds(json, .json, of: .keyword) == ["true"])
    }

    @Test func yamlKeysStartTheirLineAndUrlsInValuesAreNotKeysOrComments() {
        let yaml = "name: app\nitems:\n  - image: http://example.com/a#frag  # note\n"
        #expect(kinds(yaml, .yaml, of: .key) == ["name", "items", "image"])
        #expect(kinds(yaml, .yaml, of: .comment) == ["# note"])
    }

    @Test func tomlSectionsAndKeys() {
        let toml = "[package]\nname = \"x\"\n[[bin]]\npath = 'src/main.rs'\n"
        #expect(kinds(toml, .toml, of: .type) == ["[package]", "[[bin]]"])
        #expect(kinds(toml, .toml, of: .key) == ["name", "path"])
    }

    @Test func shellVariablesAndWordStartComments() {
        let shell = "echo \"$HOME\" ${PATH} $# $1 # comment\nurl=a#b\n"
        #expect(kinds(shell, .shell, of: .variable) == ["${PATH}", "$#", "$1"])
        #expect(kinds(shell, .shell, of: .comment) == ["# comment"])
        #expect(kinds(shell, .shell, of: .string) == ["\"$HOME\""])
    }

    @Test func cPreprocessorAndSQLKeywordsInAnyCase() {
        #expect(kinds("#include <stdio.h>\nint x;", .c, of: .attribute) == ["#include"])
        #expect(kinds("Select id FROM t where x = 'it''s'", .sql, of: .keyword) == ["Select", "FROM", "where"])
    }

    @Test func markdownHeadingsFencesAndInlineMarks() {
        let markdown = """
        # Title
        Some *em* and **strong** and `code` and [link](http://x) and snake_case_name.
        - item
        ```swift
        let x = 1 # inside
        ```
        """
        let tokens = lex(markdown, .markdown)
        #expect(tokens.contains { $0 == ("# Title", .heading) })
        #expect(tokens.contains { $0 == ("*em*", .emphasis) })
        #expect(tokens.contains { $0 == ("**strong**", .strong) })
        #expect(tokens.contains { $0 == ("`code`", .code) })
        #expect(tokens.contains { $0 == ("[link](http://x)", .link) })
        #expect(tokens.contains { $0 == ("-", .keyword) })
        #expect(tokens.contains { $0 == ("let x = 1 # inside", .code) })
        #expect(!tokens.contains { $0.0.contains("case") })
    }

    @Test func markupTagsAttributesAndComments() {
        let html = #"<!-- c --><a href="x" data-id='1'>text &amp; more</a>"#
        #expect(kinds(html, .markup, of: .keyword) == ["a", "a"])
        #expect(kinds(html, .markup, of: .key) == ["href", "data-id"])
        #expect(kinds(html, .markup, of: .string) == [#""x""#, "'1'"])
        #expect(kinds(html, .markup, of: .comment) == ["<!-- c -->"])
        #expect(kinds(html, .markup, of: .variable) == ["&amp;"])
    }

    @Test func languagesAreFoundByExtensionByNameAndByShebang() {
        #expect(SyntaxLanguage.detect(filename: "main.swift")?.name == "Swift")
        #expect(SyntaxLanguage.detect(filename: "App.TSX")?.name == "JavaScript")
        #expect(SyntaxLanguage.detect(filename: "Makefile")?.name == "Makefile")
        #expect(SyntaxLanguage.detect(filename: "Dockerfile.dev")?.name == "Dockerfile")
        #expect(SyntaxLanguage.detect(filename: ".env.local")?.name == "INI")
        #expect(SyntaxLanguage.detect(filename: "deploy", firstLine: "#!/usr/bin/env bash")?.name == "Shell")
        #expect(SyntaxLanguage.detect(filename: "tool", firstLine: "#!/usr/bin/env -S python3 -u")?.name == "Python")
        #expect(SyntaxLanguage.detect(filename: "notes.txt") == nil)
        #expect(SyntaxLanguage.detect(filename: "LICENSE", firstLine: "MIT License") == nil)
    }

    /// Whatever the input, the tokens must be in bounds, in order and apart:
    /// they are applied straight to a text storage, where an overlap repaints
    /// and an out-of-bounds range raises.
    @Test func tokensAreOrderedDisjointAndInBoundsForAnyInput() {
        let alphabet = Array("abcXY_09 \t\n\"'`\\/*#$@{}[]()<>:=-.;!?&~—é😀")
        var generator = SystemRandomNumberGenerator()
        let languages: [SyntaxLanguage] = [
            .swift, .python, .javascript, .go, .rust, .c, .java, .ruby, .lua, .zig, .sql, .shell, .makefile,
            .dockerfile, .json, .yaml, .toml, .ini, .css, .markdown, .markup,
        ]
        for _ in 0..<300 {
            let length = Int.random(in: 0..<120, using: &generator)
            let text = String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
            let count = (text as NSString).length
            for language in languages {
                var end = 0
                for token in SyntaxLexer.tokens(in: text, language: language) {
                    #expect(token.range.length > 0)
                    #expect(token.range.location >= end, "\(language.name): \(text.debugDescription)")
                    end = token.range.location + token.range.length
                    #expect(end <= count, "\(language.name): \(text.debugDescription)")
                }
            }
        }
    }
}
