import AppKit

/// How the Files card's editor looks: the terminal's font size and face, the
/// terminal's background and foreground, and source code coloured from the
/// sixteen ANSI colours of the user's ghostty palette.
///
/// The palette rather than a theme of our own, for the same reason the
/// terminal area takes its colours from the ghostty config: an editor is
/// content, like a pane, and it sits beside panes whose programs paint with
/// exactly these colours. The mapping is `bat --theme=ansi`'s, so a file looks
/// in the card the way `bat` shows it in a pane.
///
/// With a light/dark `theme` pair the palette read through the C API is the
/// light half whatever is on screen — the trap `GhosttyConfig.hasLightDarkTheme`
/// describes — so the colours fall back to AppKit's semantic ones, which follow
/// the same appearance the terminal does.
@MainActor
struct SyntaxTheme {
    let font: NSFont
    let foreground: NSColor
    let background: NSColor
    /// The gutter's numbers: the foreground, quietly.
    let gutter: NSColor
    private let colors: [TokenKind: NSColor]
    private let bold: NSFont
    private let italic: NSFont

    init(_ config: GhosttyConfig = GhosttyRuntime.config) {
        let size = CGFloat(config.fontSize)
        font = config.fontFamily.flatMap {
            NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: size) ?? NSFont(name: $0, size: size)
        } ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        foreground = config.terminalForeground
        background = config.terminalBackground
        gutter = foreground.withAlphaComponent(0.4)

        let palette = config.palette
        if config.hasLightDarkTheme || palette.count < 16 {
            colors = [
                .comment: .secondaryLabelColor, .keyword: .systemPurple, .string: .systemGreen,
                .number: .systemOrange, .type: .systemTeal, .function: .systemBlue, .key: .systemBlue,
                .variable: .systemRed, .attribute: .systemOrange, .heading: .systemBlue, .code: .systemGreen,
                .link: .systemTeal,
            ]
        } else {
            colors = [
                .comment: palette[8], .keyword: palette[5], .string: palette[2], .number: palette[3],
                .type: palette[6], .function: palette[4], .key: palette[4], .variable: palette[1],
                .attribute: palette[3], .heading: palette[4], .code: palette[2], .link: palette[6],
            ]
        }
    }

    /// What every character starts as, before a token says otherwise. Tabs are
    /// four columns wide.
    var base: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        let column = (" " as NSString).size(withAttributes: [.font: font]).width
        paragraph.defaultTabInterval = column * 4
        paragraph.tabStops = []
        return [.font: font, .foregroundColor: foreground, .paragraphStyle: paragraph]
    }

    func attributes(for kind: TokenKind) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [:]
        if let color = colors[kind] { attributes[.foregroundColor] = color }
        switch kind {
        case .heading, .strong: attributes[.font] = bold
        case .emphasis: attributes[.font] = italic
        case .link: attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        default: break
        }
        return attributes
    }
}
