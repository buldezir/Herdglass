import AppKit
import HerdrClient

/// One place that decides how an agent status looks and reads, so the sidebar
/// dot, the attention ring and the window subtitle can never drift apart.
enum StatusStyle {
    /// Fill for the status dot. System colors so light and dark both work.
    static func color(_ status: AgentStatus) -> NSColor {
        switch status {
        case .blocked: return .systemOrange
        case .done: return .systemBlue
        case .working: return .systemGreen
        case .idle: return .tertiaryLabelColor
        case .unknown: return .tertiaryLabelColor
        }
    }

    /// Ring drawn around whatever is asking to be looked at.
    static func attentionColor(_ status: AgentStatus) -> NSColor {
        status == .blocked ? .systemOrange : .systemBlue
    }

    static func label(_ status: AgentStatus) -> String {
        switch status {
        case .blocked: return "needs input"
        case .done: return "done"
        case .working: return "working"
        case .idle: return "idle"
        case .unknown: return "no agent"
        }
    }

    static func symbolName(_ status: AgentStatus) -> String {
        switch status {
        case .blocked: return "exclamationmark.bubble.fill"
        case .done: return "checkmark.circle.fill"
        case .working: return "circle.dotted"
        case .idle: return "circle"
        case .unknown: return "circle.dashed"
        }
    }
}
