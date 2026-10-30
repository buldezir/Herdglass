import Foundation

extension SyntaxLanguage {
    /// The language a file is written in, from its name and, for a script
    /// with no extension, its `#!` line. Nil means plain text.
    static func detect(filename: String, firstLine: Substring? = nil) -> SyntaxLanguage? {
        let name = filename.lowercased()
        if let language = byName[name] { return language }
        if name.hasPrefix(".env") || name.hasSuffix(".env") { return .ini }
        if name.hasPrefix("dockerfile") || name.hasSuffix(".dockerfile") { return .dockerfile }
        let ext = (name as NSString).pathExtension
        if !ext.isEmpty, let language = byExtension[ext] { return language }
        guard let firstLine, firstLine.hasPrefix("#!") else { return nil }
        let interpreter = firstLine.split(whereSeparator: { $0 == " " || $0 == "/" }).last { !$0.hasPrefix("-") }
        switch interpreter.map(String.init) ?? "" {
        case let word where word.hasPrefix("python"): return .python
        case "bash", "sh", "zsh", "dash", "ksh": return .shell
        case "node", "deno", "bun": return .javascript
        case "ruby": return .ruby
        case "lua": return .lua
        default: return nil
        }
    }

    private static let byName: [String: SyntaxLanguage] = [
        "makefile": .makefile, "gnumakefile": .makefile, "justfile": .makefile,
        "containerfile": .dockerfile,
        "gemfile": .ruby, "rakefile": .ruby, "podfile": .ruby, "brewfile": .ruby,
        ".bashrc": .shell, ".bash_profile": .shell, ".zshrc": .shell, ".zprofile": .shell, ".zshenv": .shell,
        ".profile": .shell, ".envrc": .shell,
        ".gitconfig": .ini, ".editorconfig": .ini, ".npmrc": .ini,
        "cargo.lock": .toml, "pipfile": .toml,
    ]

    private static let byExtension: [String: SyntaxLanguage] = {
        var table: [String: SyntaxLanguage] = [:]
        for (extensions, language) in [
            (["swift"], SyntaxLanguage.swift),
            (["py", "pyi", "pyw"], .python),
            (["js", "mjs", "cjs", "jsx", "ts", "tsx", "mts", "cts"], .javascript),
            (["go"], .go),
            (["rs"], .rust),
            (["c", "h", "cc", "cpp", "cxx", "hpp", "hh", "hxx", "m", "mm"], .c),
            (["java", "kt", "kts", "scala", "groovy", "gradle"], .java),
            (["rb", "rake", "gemspec"], .ruby),
            (["lua"], .lua),
            (["zig", "zon"], .zig),
            (["sql"], .sql),
            (["sh", "bash", "zsh", "ksh", "command"], .shell),
            (["mk", "make"], .makefile),
            (["json", "jsonc", "json5", "geojson", "jsonl", "ndjson"], .json),
            (["yml", "yaml"], .yaml),
            (["toml"], .toml),
            (["ini", "cfg", "conf", "properties", "service", "desktop"], .ini),
            (["md", "markdown", "mdx", "mdown"], .markdown),
            (["html", "htm", "xhtml", "xml", "svg", "plist", "xib", "storyboard", "vue", "svelte"], .markup),
            (["css", "scss", "sass", "less"], .css),
        ] {
            for ext in extensions { table[ext] = language }
        }
        return table
    }()
}

// MARK: - The languages

private func units(_ text: String) -> [UInt16] { Array(text.utf16) }

private func string(_ delimiter: String, multiline: Bool = false, escapes: Bool = true, short: Bool = false)
    -> SyntaxLanguage.StringRule {
    SyntaxLanguage.StringRule(delimiter: units(delimiter), multiline: multiline, escapes: escapes, short: short)
}

private func words(_ text: String) -> Set<String> {
    Set(text.split(whereSeparator: \.isWhitespace).map(String.init))
}

private let slashComments = [units("//")]
private let cBlockComment = [SyntaxLanguage.BlockComment(open: units("/*"), close: units("*/"))]

extension SyntaxLanguage {
    static let swift = SyntaxLanguage(
        name: "Swift",
        lineComments: slashComments,
        blockComments: cBlockComment,
        strings: [string("\"\"\"", multiline: true), string("\"")],
        keywords: words("""
        associatedtype class deinit enum extension fileprivate func import init inout internal let open operator
        private precedencegroup protocol public rethrows static struct subscript typealias var break case catch
        continue default defer do else fallthrough for guard if in repeat return throw switch where while as
        Any await async catch false is nil self Self super throws true try actor nonisolated isolated some any
        convenience dynamic final lazy mutating nonmutating optional override required unowned weak willSet didSet
        get set consume borrowing consuming package macro
        """),
        capitalizedIsType: true,
        callIsFunction: true,
        attributeSigils: [64, 35]
    )

    static let python = SyntaxLanguage(
        name: "Python",
        lineComments: [units("#")],
        strings: [string("\"\"\"", multiline: true), string("'''", multiline: true), string("\""), string("'")],
        keywords: words("""
        False None True and as assert async await break class continue def del elif else except finally for from
        global if import in is lambda nonlocal not or pass raise return try while with yield match case self cls
        """),
        capitalizedIsType: true,
        callIsFunction: true,
        attributeSigils: [64]
    )

    static let javascript = SyntaxLanguage(
        name: "JavaScript",
        lineComments: slashComments,
        blockComments: cBlockComment,
        strings: [string("`", multiline: true), string("\""), string("'")],
        keywords: words("""
        abstract as async await break case catch class const continue debugger declare default delete do else enum
        export extends false finally for from function get if implements import in instanceof interface is keyof
        let new null of package private protected public readonly return satisfies set static super switch this
        throw true try type typeof undefined var void while with yield
        """),
        capitalizedIsType: true,
        callIsFunction: true,
        attributeSigils: [64]
    )

    static let go = SyntaxLanguage(
        name: "Go",
        lineComments: slashComments,
        blockComments: cBlockComment,
        strings: [string("`", multiline: true, escapes: false), string("\""), string("'", short: true)],
        keywords: words("""
        break case chan const continue default defer else fallthrough for func go goto if import interface map
        package range return select struct switch type var true false nil iota any error string int int8 int16
        int32 int64 uint uint8 uint16 uint32 uint64 uintptr float32 float64 bool byte rune
        """),
        capitalizedIsType: true,
        callIsFunction: true
    )

    static let rust = SyntaxLanguage(
        name: "Rust",
        lineComments: slashComments,
        blockComments: cBlockComment,
        strings: [string("\""), string("'", short: true)],
        keywords: words("""
        as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod
        move mut pub ref return self Self static struct super trait true type unsafe use where while macro_rules
        i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str
        """),
        capitalizedIsType: true,
        callIsFunction: true,
        bracketAttributes: true
    )

    static let c = SyntaxLanguage(
        name: "C",
        lineComments: slashComments,
        blockComments: cBlockComment,
        strings: [string("\""), string("'", short: true)],
        keywords: words("""
        auto break case char const continue default do double else enum extern float for goto if inline int long
        register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while
        bool true false NULL nullptr class namespace template typename public private protected virtual override
        new delete this using try catch throw constexpr noexcept operator friend explicit mutable auto decltype
        nil YES NO self super id instancetype
        """),
        callIsFunction: true,
        attributeSigils: [64],
        preprocessor: true
    )

    static let java = SyntaxLanguage(
        name: "Java",
        lineComments: slashComments,
        blockComments: cBlockComment,
        strings: [string("\"\"\"", multiline: true), string("\""), string("'", short: true)],
        keywords: words("""
        abstract assert boolean break byte case catch char class const continue default do double else enum extends
        final finally float for goto if implements import instanceof int interface long native new package private
        protected public return short static strictfp super switch synchronized this throw throws transient try
        void volatile while true false null var record sealed permits yield fun val when object companion data
        is in out internal open override lateinit suspend inline typealias def trait
        """),
        capitalizedIsType: true,
        callIsFunction: true,
        attributeSigils: [64]
    )

    static let ruby = SyntaxLanguage(
        name: "Ruby",
        lineComments: [units("#")],
        blockComments: [BlockComment(open: units("=begin"), close: units("=end"))],
        strings: [string("\"", multiline: true), string("'", multiline: true)],
        keywords: words("""
        BEGIN END alias and begin break case class def defined do else elsif end ensure false for if in module next
        nil not or redo rescue retry return self super then true undef unless until when while yield require
        require_relative attr_accessor attr_reader attr_writer private protected public lambda proc
        """),
        capitalizedIsType: true,
        attributeSigils: [64]
    )

    static let lua = SyntaxLanguage(
        name: "Lua",
        lineComments: [units("--")],
        blockComments: [BlockComment(open: units("--[["), close: units("]]"))],
        strings: [string("[[", multiline: true, escapes: false), string("\""), string("'")],
        keywords: words("""
        and break do else elseif end false for function goto if in local nil not or repeat return then true until
        while self
        """),
        callIsFunction: true
    )

    static let zig = SyntaxLanguage(
        name: "Zig",
        lineComments: slashComments,
        strings: [string("\""), string("'", short: true)],
        keywords: words("""
        addrspace align allowzero and anyframe anytype asm async await break callconv catch comptime const continue
        defer else enum errdefer error export extern fn for if inline linksection noalias noinline nosuspend opaque
        or orelse packed pub resume return struct suspend switch test threadlocal try union unreachable usingnamespace
        var volatile while true false null undefined void bool type anyerror u8 u16 u32 u64 usize i8 i16 i32 i64
        isize f16 f32 f64 c_int c_uint
        """),
        capitalizedIsType: true,
        callIsFunction: true,
        attributeSigils: [64]
    )

    static let sql = SyntaxLanguage(
        name: "SQL",
        lineComments: [units("--")],
        blockComments: cBlockComment,
        strings: [string("'", multiline: true, escapes: false), string("\"")],
        keywords: words("""
        add all alter and as asc begin between by case cascade check column commit constraint create cross database
        default delete desc distinct drop else end exists foreign from full group having if in index inner insert
        into is join key left like limit not null offset on or order outer primary references returning right
        rollback select set table then transaction union unique update using values view when where with
        integer int bigint text varchar boolean timestamp date serial real float true false
        """),
        caseInsensitiveKeywords: true,
        callIsFunction: true
    )

    static let shell = SyntaxLanguage(
        name: "Shell",
        lineComments: [units("#")],
        commentNeedsWordStart: true,
        strings: [string("\"", multiline: true), string("'", multiline: true, escapes: false), string("`", multiline: true)],
        keywords: words("""
        if then else elif fi for while until do done case esac in function return local export readonly declare
        typeset set unset shift exit break continue select time source alias eval exec trap echo printf read cd test
        """),
        callIsFunction: true,
        shellVariables: true
    )

    static let makefile = SyntaxLanguage(
        name: "Makefile",
        lineComments: [units("#")],
        commentNeedsWordStart: true,
        strings: [string("\""), string("'", escapes: false)],
        keywords: words("ifeq ifneq ifdef ifndef else endif include define endef export override"),
        shellVariables: true,
        parenVariables: true,
        identifierExtras: [45, 46],
        keyBefore: 58,
        keyStartsLine: true
    )

    static let dockerfile = SyntaxLanguage(
        name: "Dockerfile",
        lineComments: [units("#")],
        commentNeedsWordStart: true,
        strings: [string("\""), string("'", escapes: false)],
        keywords: words("""
        FROM AS RUN CMD LABEL EXPOSE ENV ADD COPY ENTRYPOINT VOLUME USER WORKDIR ARG ONBUILD STOPSIGNAL HEALTHCHECK
        SHELL MAINTAINER
        """),
        shellVariables: true
    )

    static let json = SyntaxLanguage(
        name: "JSON",
        lineComments: slashComments,
        blockComments: cBlockComment,
        strings: [string("\"")],
        keywords: words("true false null"),
        keyBefore: 58,
        stringKeys: true
    )

    static let yaml = SyntaxLanguage(
        name: "YAML",
        lineComments: [units("#")],
        commentNeedsWordStart: true,
        strings: [string("\""), string("'", escapes: false)],
        keywords: words("true false null yes no on off True False Null"),
        attributeSigils: [38, 42],
        identifierExtras: [45, 46, 47],
        keyBefore: 58,
        keyStartsLine: true,
        stringKeys: true
    )

    static let toml = SyntaxLanguage(
        name: "TOML",
        lineComments: [units("#")],
        strings: [string("\"\"\"", multiline: true), string("'''", multiline: true, escapes: false),
                  string("\""), string("'", escapes: false)],
        keywords: words("true false"),
        identifierExtras: [45, 46],
        keyBefore: 61,
        keyStartsLine: true,
        stringKeys: true,
        sectionHeaders: true
    )

    /// INI, `.env`, `.gitconfig`, `.properties`: TOML's shape with `;`
    /// comments as well, and no opinion on what a value is.
    static let ini = SyntaxLanguage(
        name: "INI",
        lineComments: [units("#"), units(";")],
        commentNeedsWordStart: true,
        strings: [string("\""), string("'", escapes: false)],
        keywords: words("true false yes no on off export"),
        identifierExtras: [45, 46],
        keyBefore: 61,
        keyStartsLine: true,
        sectionHeaders: true
    )

    static let css = SyntaxLanguage(
        name: "CSS",
        lineComments: slashComments,
        blockComments: cBlockComment,
        strings: [string("\""), string("'")],
        keywords: words("important inherit initial unset none auto revert"),
        callIsFunction: true,
        attributeSigils: [64, 36],
        identifierExtras: [45],
        keyBefore: 58
    )

    static let markdown = SyntaxLanguage(name: "Markdown", style: .markdown)
    static let markup = SyntaxLanguage(name: "HTML", style: .markup)
}
