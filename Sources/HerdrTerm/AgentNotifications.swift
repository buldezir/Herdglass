import Foundation
import HerdrClient
import UserNotifications

/// Herdr's notifications, delivered as macOS ones.
///
/// An agent changing state in a workspace the user is not watching is what Herdr
/// calls a notification, and its own config picks one of four ways to deliver it
/// (`[ui.toast] delivery`): an in-app toast, the outer terminal, the OS, or
/// nothing at all. A GUI client has no toast layer and no outer terminal to ask,
/// so this app takes the OS route on Herdr's behalf — a pane that asks for input
/// or finishes off screen becomes a notification from this app, with that pane
/// behind it.
///
/// One notification per pane, and it is withdrawn as soon as the pane is read:
/// the same rule the sidebar's unread state follows, so Notification Center
/// never holds a request the user has already answered.
@MainActor
enum AgentNotifications {
    /// Why a pane is asking for the user — the two states Herdr itself
    /// distinguishes (its `request` and `done` sounds).
    enum Reason {
        case blocked
        case done

        init?(_ status: AgentStatus) {
            switch status {
            case .blocked: self = .blocked
            case .done: self = .done
            case .idle, .working, .unknown: return nil
            }
        }

        var body: String {
            switch self {
            case .blocked: return "Waiting for input"
            case .done: return "Finished"
            }
        }
    }

    /// The pane a delivered notification came from, so clicking it can select
    /// that pane rather than just raising the app. Read where the click lands,
    /// which is off the main actor.
    nonisolated static let paneIdKey = "paneId"

    private static let enabledKey = "NotificationsEnabled"

    /// On unless the user has turned it off. Read straight from defaults rather
    /// than cached, so `Settings` and every session see the same answer.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set {
            guard newValue != isEnabled else { return }
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            if newValue {
                requestAuthorization()
            } else {
                // Nothing left in Notification Center from a feature that is off.
                center?.removeAllDeliveredNotifications()
            }
        }
    }

    /// Point the notification centre at the delegate that opens panes, and ask
    /// for permission if we are going to post anything.
    static func prepare(delegate: any UNUserNotificationCenterDelegate) {
        center?.delegate = delegate
        guard isEnabled else { return }
        requestAuthorization()
    }

    static func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Whether macOS will actually show what we post — the toggle in Settings
    /// would otherwise be lying about a permission the user revoked.
    static func authorizationStatus(_ completion: @escaping @Sendable @MainActor (UNAuthorizationStatus) -> Void) {
        guard let center else { return completion(.notDetermined) }
        center.getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor in completion(status) }
        }
    }

    static func post(paneId: String, title: String, subtitle: String, reason: Reason) {
        guard isEnabled, let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = reason.body
        content.sound = .default
        // Grouped by host, so a busy server is one stack rather than a column.
        content.threadIdentifier = subtitle
        content.userInfo = [paneIdKey: paneId]
        center.add(UNNotificationRequest(identifier: identifier(paneId: paneId), content: content, trigger: nil))
    }

    /// The pane has been seen, or is gone; whatever it was asking for is over.
    static func withdraw(paneId: String) {
        guard let center else { return }
        center.removePendingNotificationRequests(withIdentifiers: [identifier(paneId: paneId)])
        center.removeDeliveredNotifications(withIdentifiers: [identifier(paneId: paneId)])
    }

    /// One identifier per pane: a pane that goes `blocked` and later `done`
    /// replaces its own banner instead of stacking a second one, and reading it
    /// only has one thing to withdraw.
    private static func identifier(paneId: String) -> String { "pane-\(paneId)" }

    /// `UNUserNotificationCenter.current()` traps in a process that is not an
    /// app bundle, and `swift run HerdrTerm` is one of the documented ways to
    /// launch this app. Nil there means notifications are simply unavailable.
    private static var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return .current()
    }
}
