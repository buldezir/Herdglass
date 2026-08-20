import AppKit
import GhosttyKit

/// Owns libghostty's app tick. The tick only has work to do while a surface
/// exists, so it is reference counted by attached panes rather than left
/// running at 60 Hz for the lifetime of the process.
@MainActor
enum GhosttyRuntime {
    private static var timer: Timer?
    private static var attachedPanes = 0

    static var host: GhosttyTerminalHost? { GhosttyTerminalHost.shared }

    static var unavailableReason: String? {
        host == nil ? "libghostty failed to initialize. Check `ghostty +show-config` for a bad config." : nil
    }

    static func paneAttached() {
        attachedPanes += 1
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            MainActor.assumeIsolated { host?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    static func paneDetached() {
        attachedPanes = max(0, attachedPanes - 1)
        guard attachedPanes == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    static func reloadConfig() {
        host?.reloadConfig()
    }

    static func openConfig() {
        host?.openConfig()
    }
}
