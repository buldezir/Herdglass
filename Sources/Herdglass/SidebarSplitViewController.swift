import AppKit

/// The split view behind the window, with the sidebar width persisted by hand.
///
/// `NSSplitViewController` ignores `splitView.autosaveName`: it lays the sidebar
/// out at AppKit's default thickness on launch and then autosaves *that*, so a
/// dragged width was written on quit and overwritten by the next start.
///
/// Doing it by hand needs care in two places:
///
/// - The first layout pass runs before the window has restored its saved frame,
///   and a stored width that does not fit in that smaller frame would be clamped
///   to the sidebar's minimum. So the restore waits for a layout wide enough to
///   honour it.
/// - `didResizeSubviewsNotification` fires for every layout, not just for drags.
///   Saving on all of them writes back whatever squeezing the window did, which
///   is how the clamped minimum used to reach disk. Only a gesture on the divider
///   itself counts as the user picking a width: the mouse is down and the pointer
///   is on the divider. Dragging a window edge moves the sidebar too, but the
///   pointer is a pane's width away from the divider, and layout-driven resizes
///   have no button held at all.
@MainActor
final class SidebarSplitViewController: NSSplitViewController {
    /// How far the pointer may sit from the divider and still count as dragging
    /// it — a drag keeps whatever offset it was grabbed with.
    private static let dividerGrabSlop: CGFloat = 20

    private var desiredWidth: CGFloat? = SidebarWidthStore.load()
    private var hasRestoredWidth = false
    private var isRestoringWidth = false

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(splitViewDidResize),
            name: NSSplitView.didResizeSubviewsNotification,
            object: splitView
        )
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !hasRestoredWidth, let item = sidebarItem, let width = desiredWidth else { return }
        let target = min(max(width, item.minimumThickness), item.maximumThickness)
        // Too narrow to honour yet: leave `hasRestoredWidth` false and try again
        // on a later pass, once the window has a frame that fits it.
        guard fits(target) else { return }
        hasRestoredWidth = true
        isRestoringWidth = true
        splitView.setPosition(target, ofDividerAt: 0)
        isRestoringWidth = false
    }

    @objc private func splitViewDidResize(_ notification: Notification) {
        guard !isRestoringWidth,
              let item = sidebarItem, !item.isCollapsed,
              let container = sidebarContainer,
              isDraggingDivider(at: container)
        else { return }
        let width = container.frame.width
        guard width >= item.minimumThickness else { return }
        desiredWidth = width
        // A width the user dragged to is also a width we no longer need to restore.
        hasRestoredWidth = true
        SidebarWidthStore.save(width)
    }

    private func isDraggingDivider(at container: NSView) -> Bool {
        guard NSEvent.pressedMouseButtons != 0, let window = view.window else { return false }
        let edge = splitView.convert(CGPoint(x: container.frame.maxX, y: 0), to: nil).x
        return abs(NSEvent.mouseLocation.x - (window.frame.minX + edge)) <= Self.dividerGrabSlop
    }

    /// The split view's own child that holds the sidebar. Neither
    /// `splitView.subviews[0]` nor the sidebar view controller's view will do:
    /// the split view has more children than the two items and in no useful
    /// order, and the item's own view is inset and lags a pass behind a drag.
    private var sidebarContainer: NSView? {
        guard var container = sidebarItem?.viewController.view else { return nil }
        while let parent = container.superview, parent !== splitView {
            container = parent
        }
        return container.superview === splitView ? container : nil
    }

    /// Whether the split view is wide enough to give the sidebar `width` without
    /// the content pane pushing it back.
    private func fits(_ width: CGFloat) -> Bool {
        guard let pane = splitViewItems.dropFirst().first else { return false }
        return splitView.bounds.width - width >= pane.minimumThickness
    }

    private var sidebarItem: NSSplitViewItem? {
        splitViewItems.first
    }
}

/// Sidebar width across launches. Separate from AppKit's split view autosave,
/// which cannot be used here.
enum SidebarWidthStore {
    // Persisted under the pre-Herdglass name on purpose: renaming the key would
    // drop the saved value on existing installs.
    private static let key = "herdr-term.sidebarWidth"

    static func load() -> CGFloat? {
        let width = UserDefaults.standard.double(forKey: key)
        return width > 0 ? CGFloat(width) : nil
    }

    static func save(_ width: CGFloat) {
        UserDefaults.standard.set(Double(width), forKey: key)
    }
}
