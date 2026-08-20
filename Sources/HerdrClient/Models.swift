import Foundation

public enum AgentStatus: String, Codable, Sendable, CaseIterable {
    case idle
    case working
    case blocked
    case done
    case unknown

    public var needsAttention: Bool {
        self == .blocked || self == .done
    }
}

public struct SessionSnapshot: Codable, Sendable {
    public var version: String
    public var protocolVersion: UInt32
    public var focusedPaneId: String?
    public var focusedTabId: String?
    public var focusedWorkspaceId: String?
    public var workspaces: [WorkspaceInfo]
    public var tabs: [TabInfo]
    public var panes: [PaneInfo]
    public var agents: [AgentInfo]

    enum CodingKeys: String, CodingKey {
        case version
        case protocolVersion = "protocol"
        case focusedPaneId = "focused_pane_id"
        case focusedTabId = "focused_tab_id"
        case focusedWorkspaceId = "focused_workspace_id"
        case workspaces, tabs, panes, agents
    }
}

public struct WorkspaceInfo: Codable, Sendable, Identifiable {
    public var workspaceId: String
    public var number: UInt
    public var label: String
    public var focused: Bool
    public var paneCount: UInt
    public var tabCount: UInt
    public var activeTabId: String
    public var agentStatus: AgentStatus
    public var tokens: [String: String]?

    public var id: String { workspaceId }

    enum CodingKeys: String, CodingKey {
        case workspaceId = "workspace_id"
        case number, label, focused, tokens
        case paneCount = "pane_count"
        case tabCount = "tab_count"
        case activeTabId = "active_tab_id"
        case agentStatus = "agent_status"
    }
}

public struct TabInfo: Codable, Sendable, Identifiable {
    public var tabId: String
    public var workspaceId: String
    public var number: UInt
    public var label: String
    public var focused: Bool
    public var paneCount: UInt
    public var agentStatus: AgentStatus

    public var id: String { tabId }

    enum CodingKeys: String, CodingKey {
        case tabId = "tab_id"
        case workspaceId = "workspace_id"
        case number, label, focused
        case paneCount = "pane_count"
        case agentStatus = "agent_status"
    }
}

public struct PaneInfo: Codable, Sendable, Identifiable {
    public var paneId: String
    public var terminalId: String
    public var workspaceId: String
    public var tabId: String
    public var focused: Bool
    public var agentStatus: AgentStatus
    public var revision: UInt64
    public var cwd: String?
    public var foregroundCwd: String?
    public var agent: String?
    public var displayAgent: String?
    public var title: String?
    public var label: String?
    public var terminalTitle: String?
    public var terminalTitleStripped: String?

    public var id: String { paneId }

    public var displayName: String {
        if let displayAgent, !displayAgent.isEmpty { return displayAgent }
        if let agent, !agent.isEmpty { return agent }
        if let label, !label.isEmpty { return label }
        if let title, !title.isEmpty { return title }
        if let terminalTitleStripped, !terminalTitleStripped.isEmpty { return terminalTitleStripped }
        return paneId
    }

    enum CodingKeys: String, CodingKey {
        case paneId = "pane_id"
        case terminalId = "terminal_id"
        case workspaceId = "workspace_id"
        case tabId = "tab_id"
        case focused
        case agentStatus = "agent_status"
        case revision, cwd, agent, title, label
        case foregroundCwd = "foreground_cwd"
        case displayAgent = "display_agent"
        case terminalTitle = "terminal_title"
        case terminalTitleStripped = "terminal_title_stripped"
    }
}

public struct AgentInfo: Codable, Sendable {
    public var terminalId: String
    public var agentStatus: AgentStatus
    public var workspaceId: String
    public var tabId: String
    public var paneId: String
    public var focused: Bool
    public var revision: UInt64
    public var agent: String?
    public var displayAgent: String?
    public var name: String?
    public var title: String?
    public var stateChangeSeq: UInt64?

    enum CodingKeys: String, CodingKey {
        case terminalId = "terminal_id"
        case agentStatus = "agent_status"
        case workspaceId = "workspace_id"
        case tabId = "tab_id"
        case paneId = "pane_id"
        case focused, revision, agent, name, title
        case displayAgent = "display_agent"
        case stateChangeSeq = "state_change_seq"
    }
}

public struct HerdrRPCError: Error, LocalizedError, Sendable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }
}

public struct ConnectTarget: Codable, Equatable, Sendable, Hashable {
    public var host: String
    public var session: String?

    public init(host: String, session: String? = nil) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = session?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.session = trimmed.isEmpty ? nil : trimmed
    }

    public var displayName: String {
        if let session { return "\(host) · \(session)" }
        return host
    }

    public var isLocal: Bool {
        host.isEmpty || host == "local" || host == "localhost"
    }
}
