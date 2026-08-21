import AppKit

/// How big this app draws its own chrome — the sidebar, the tab strip, the
/// placeholders — as a multiple of one number the user can move.
///
/// The terminal's font is ghostty's (`font-size`) and a pane's contents are the
/// server's; what neither can express is the size of the *frame* around them,
/// which is the one thing a GUI client owns outright. So it is a single setting,
/// a base point size, and everything in the chrome is expressed relative to it:
/// every font goes through `font(_:weight:)` and every length that has to keep
/// step with one — a sidebar row's height, a tab's width, a status dot — goes
/// through `length(_:)`. Both halves matter. Scaling the text on its own gives a
/// 20pt title in a 42pt row that clips its own subtitle, which is exactly what
/// makes a font-size setting look broken.
///
/// Views that live for the whole session re-read this on
/// `didChangeNotification`; ones that are rebuilt anyway (the connect sheet, a
/// pane placeholder) read it as they are built.
@MainActor
enum ChromeMetrics {
    /// The size the chrome was drawn at before this was a setting, and what
    /// every call site's number is still relative to: the sidebar row's title,
    /// which is the primary text of the window's chrome.
    static let defaultFontSize: Double = 12

    /// Small enough to be dense on a 5K display, large enough to be read across
    /// a desk, and bounded at both ends because the tab strip's fixed widths
    /// cannot absorb an arbitrary multiple.
    static let range: ClosedRange<Double> = 9...20

    static let didChangeNotification = Notification.Name("herdglass.chrome-metrics-did-change")

    // Persisted under the pre-Herdglass name on purpose: renaming the key would
    // drop the saved value on existing installs.
    private static let key = "herdr-term.ui-font-size"

    /// The base point size. Never unset: an absent or out-of-range preference
    /// reads as the default rather than as zero.
    static var fontSize: Double {
        get {
            let stored = UserDefaults.standard.double(forKey: key)
            guard stored > 0 else { return defaultFontSize }
            return min(max(stored, range.lowerBound), range.upperBound)
        }
        set {
            let clamped = min(max(newValue, range.lowerBound), range.upperBound)
            guard clamped != fontSize else { return }
            UserDefaults.standard.set(clamped, forKey: key)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    private static var scale: CGFloat { CGFloat(fontSize / defaultFontSize) }

    /// A chrome font, sized relative to the base. `size` is what the call site
    /// used before this existed, so the type scale the app was designed with is
    /// still visible in the code.
    static func font(_ size: Double, weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: (CGFloat(size) * scale).rounded(), weight: weight)
    }

    /// A length that has to keep step with the text sitting in it.
    static func length(_ points: CGFloat) -> CGFloat {
        (points * scale).rounded()
    }

    /// An SF Symbol drawn alongside chrome text, so an icon does not stay
    /// 11pt beside a 20pt label.
    static func symbol(_ pointSize: CGFloat, weight: NSFont.Weight = .regular) -> NSImage.SymbolConfiguration {
        .init(pointSize: length(pointSize), weight: weight)
    }
}
