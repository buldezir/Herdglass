import AppKit
import Observation
import Sparkle

/// The app's updates, through Sparkle: it reads the latest release's feed
/// (SUFeedURL, which Scripts/appcast.sh writes) once a day, shows the new
/// version's notes and installs it. An update that a daily check finds while
/// the app is in the background doesn't put a window in front of the user's
/// work: it waits in the menu, where choosing it opens Sparkle's dialog. Only
/// release builds update; a local build is version 0.1.
@MainActor @Observable
final class AppUpdater: NSObject {
    static let shared = AppUpdater()

    let isRelease: Bool
    /// The version a daily check found, until the user looks at it.
    private(set) var available: String?
    /// False while a check or an update is under way.
    private(set) var canCheck = false

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    private override init() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        isRelease = Self.isRelease(version)
        super.init()
    }

    /// Starts the daily checks, once, when the app launches.
    func start() {
        guard isRelease, controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        self.controller = controller
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated { self?.canCheck = updater.canCheckForUpdates }
        }
    }

    func checkForUpdates() {
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    /// The menu item that offers the update a daily check found, or a check.
    var menuTitle: String {
        available.map { "Update to \($0)…" } ?? "Check for Updates…"
    }

    var checksAutomatically: Bool {
        get {
            access(keyPath: \.checksAutomatically)
            return controller?.updater.automaticallyChecksForUpdates ?? false
        }
        set {
            withMutation(keyPath: \.checksAutomatically) { controller?.updater.automaticallyChecksForUpdates = newValue }
        }
    }

    var downloadsAutomatically: Bool {
        get {
            access(keyPath: \.downloadsAutomatically)
            return controller?.updater.automaticallyDownloadsUpdates ?? false
        }
        set {
            withMutation(keyPath: \.downloadsAutomatically) { controller?.updater.automaticallyDownloadsUpdates = newValue }
        }
    }

    /// A release's version is X.Y.Z or X.Y.Z-pre. A local build's, such as
    /// "0.1" or git describe's "0.1.2-6-gd609b51", isn't.
    nonisolated static func isRelease(_ version: String) -> Bool {
        version.wholeMatch(of: #/\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?/#) != nil && !version.contains(#/-\d+-g[0-9a-f]+$/#)
    }
}

extension AppUpdater: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle shows an update itself when the app is in focus anyway, such
    /// as just after launch; otherwise the menu offers it.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if !handleShowingUpdate { available = update.displayVersionString }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        available = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        available = nil
    }
}
