import Foundation

extension String {
    /// `/Users/me/src/app` reads as `~/src/app` in a 200pt sidebar row.
    ///
    /// Lives here rather than in the UI target because `PaneInfo.cwdName` needs
    /// it too, and that is where it is unit-testable.
    public var abbreviatingHome: String {
        (self as NSString).abbreviatingWithTildeInPath
    }
}

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
    /// One entry per tab that has a live layout. Cheap to read on every poll,
    /// and the only way to notice a split appeared without asking for the tree.
    public var layouts: [LayoutSummary]

    enum CodingKeys: String, CodingKey {
        case version
        case protocolVersion = "protocol"
        case focusedPaneId = "focused_pane_id"
        case focusedTabId = "focused_tab_id"
        case focusedWorkspaceId = "focused_workspace_id"
        case workspaces, tabs, panes, agents, layouts
    }

    /// Written by hand so a server (or a fixture) that omits a collection
    /// decodes to an empty one instead of failing the whole snapshot.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? ""
        protocolVersion = try container.decodeIfPresent(UInt32.self, forKey: .protocolVersion) ?? 0
        focusedPaneId = try container.decodeIfPresent(String.self, forKey: .focusedPaneId)
        focusedTabId = try container.decodeIfPresent(String.self, forKey: .focusedTabId)
        focusedWorkspaceId = try container.decodeIfPresent(String.self, forKey: .focusedWorkspaceId)
        workspaces = try container.decodeIfPresent([WorkspaceInfo].self, forKey: .workspaces) ?? []
        tabs = try container.decodeIfPresent([TabInfo].self, forKey: .tabs) ?? []
        panes = try container.decodeIfPresent([PaneInfo].self, forKey: .panes) ?? []
        agents = try container.decodeIfPresent([AgentInfo].self, forKey: .agents) ?? []
        layouts = try container.decodeIfPresent([LayoutSummary].self, forKey: .layouts) ?? []
    }

    public func tabs(in workspaceId: String) -> [TabInfo] {
        tabs.filter { $0.workspaceId == workspaceId }.sorted { $0.number < $1.number }
    }

    public func panes(in tabId: String) -> [PaneInfo] {
        panes.filter { $0.tabId == tabId }
    }

    public func layout(forTab tabId: String) -> LayoutSummary? {
        layouts.first { $0.tabId == tabId }
    }

    public func tab(_ tabId: String) -> TabInfo? {
        tabs.first { $0.tabId == tabId }
    }

    public func workspace(_ workspaceId: String) -> WorkspaceInfo? {
        workspaces.first { $0.workspaceId == workspaceId }
    }

    public func pane(_ paneId: String) -> PaneInfo? {
        panes.first { $0.paneId == paneId }
    }

    // MARK: - Titles

    /// What a running agent calls itself, if a pane is hosting one.
    ///
    /// It has to be looked up in `agents` rather than read off `PaneInfo`: a
    /// pane carries only the agent *kind* (`agent: "claude"`), and the name
    /// somebody gave it — `herdr agent start reviewer …`, `herdr agent rename` —
    /// lives on `AgentInfo` alone, keyed by pane.
    public func agentName(forPane paneId: String) -> String? {
        guard let agent = agents.first(where: { $0.paneId == paneId }) else { return nil }
        return [agent.name, agent.displayAgent, agent.agent]
            .compactMap { $0 }
            .first { !$0.isEmpty }
    }

    /// What to call a pane: its agent's name if it has one, otherwise the
    /// pane's own chain.
    public func paneTitle(_ pane: PaneInfo) -> String {
        agentName(forPane: pane.paneId) ?? pane.displayName
    }

    /// The pane a tab is named after — the one holding the keyboard, else the
    /// first it has.
    public func representativePane(inTab tabId: String) -> PaneInfo? {
        let panes = self.panes(in: tabId)
        return panes.first { $0.focused } ?? panes.first
    }

    /// The pane a space is named after: the representative pane of the tab the
    /// space is actually on, falling back to any pane it has at all.
    public func representativePane(inWorkspace workspaceId: String) -> PaneInfo? {
        if let activeTabId = workspace(workspaceId)?.activeTabId,
           let pane = representativePane(inTab: activeTabId) {
            return pane
        }
        return panes.first { $0.workspaceId == workspaceId && $0.focused }
            ?? panes.first { $0.workspaceId == workspaceId }
    }

    /// Where a tab sits in its space, 1-based.
    ///
    /// **Not** `TabInfo.number`, which is a stable ordinal with gaps: close the
    /// first of three tabs and the survivors read 3 and 4, while their labels
    /// renumber to 1 and 2. Position is what the strip shows, what ⌘1…⌘9 mean,
    /// and what Herdr puts in the label of a tab nobody has named — so it is
    /// also the only thing `title(ofTab:)` can compare a label against.
    public func position(ofTab tab: TabInfo) -> Int {
        let ordered = tabs(in: tab.workspaceId)
        guard let index = ordered.firstIndex(where: { $0.tabId == tab.tabId }) else {
            return Int(tab.number)
        }
        return index + 1
    }

    /// Herdr labels an unnamed tab with its position, which says nothing next to
    /// the number already on the row; name it after what is running instead.
    public func title(ofTab tab: TabInfo) -> String {
        if !tab.label.isEmpty, tab.label != "\(position(ofTab: tab))" { return tab.label }
        guard let pane = representativePane(inTab: tab.tabId) else { return tab.label }
        return paneTitle(pane)
    }

    /// Every tab in a space, shortest useful form, in strip order: the position
    /// the user would press and what is running there.
    ///
    /// A space name can only ever be one thing, and a space is usually several —
    /// this is what makes a sidebar row say where its work actually is.
    public func tabSummaries(inWorkspace workspaceId: String) -> [String] {
        tabs(in: workspaceId).enumerated().map { index, tab in
            let position = "\(index + 1)"
            let name = title(ofTab: tab)
            // An unnamed tab with nothing to be named after falls back to its
            // own label, which *is* the position — do not print it twice.
            return name.isEmpty || name == position ? position : "\(position) \(name)"
        }
    }

    /// Whether a space's label looks like one somebody chose, as opposed to the
    /// one Herdr gave it.
    ///
    /// Herdr names a new space after the directory it was created in and never
    /// revisits it — `/Users/me/projects/app` becomes `app`, a home directory
    /// becomes `~` — so a label that still matches a directory the space is
    /// sitting in is Herdr's, and anything else was typed. The test is only as
    /// good as the panes not having moved: a space still on its default label
    /// that has `cd`'d elsewhere reads as hand-named, and keeps showing the
    /// directory it started in.
    ///
    /// That is the safe way round. Getting it wrong here costs the auto-update
    /// this space would otherwise have had, which is where it already was;
    /// guessing the other way would throw away a name the user typed and give
    /// them no way to get it back.
    func labelLooksChosen(_ workspace: WorkspaceInfo) -> Bool {
        let label = workspace.label
        guard !label.isEmpty, label != "\(workspace.number)" else { return false }
        var directories = panes
            .filter { $0.workspaceId == workspace.workspaceId }
            .flatMap { [$0.cwd, $0.foregroundCwd] }
        // Clients may report where a space was created, which is the label's
        // actual source when a pane has since moved on.
        directories.append(workspace.tokens?["cwd"])
        for case let directory? in directories where !directory.isEmpty {
            let abbreviated = directory.abbreviatingHome
            if label == abbreviated || label == (abbreviated as NSString).lastPathComponent {
                return false
            }
        }
        return true
    }

    /// A space says **where**, never what — the agent belongs to a tab, and a
    /// space usually has several.
    ///
    /// Naming a space after the agent inside it was the first thing tried here
    /// and it reads badly: the one row that should anchor you in a host turns
    /// into a second copy of the tab strip, and a space with three tabs picks
    /// one of them arbitrarily. `tabSummaries(inWorkspace:)` is where what-is-
    /// running goes.
    ///
    /// So: a name somebody typed, else the directory the space is actually in,
    /// else the label Herdr gave it.
    public func title(ofWorkspace workspace: WorkspaceInfo) -> String {
        if labelLooksChosen(workspace) { return workspace.label }
        if let directory = representativePane(inWorkspace: workspace.workspaceId)?.cwdName {
            return directory
        }
        if !workspace.label.isEmpty { return workspace.label }
        return representativePane(inWorkspace: workspace.workspaceId)
            .map { paneTitle($0) } ?? workspace.label
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

    /// The directory the pane is in, as a name rather than a path: the last
    /// component of where the foreground program is, `~` for a home directory.
    ///
    /// Ahead of `terminalTitleStripped` in `displayName` because a shell's own
    /// OSC title is `user@host:~`, which says nothing a window does not already
    /// say — while the directory is the closest thing an agentless pane has to a
    /// name.
    public var cwdName: String? {
        guard let cwd = [foregroundCwd, self.cwd].compactMap({ $0 }).first(where: { !$0.isEmpty })
        else { return nil }
        let abbreviated = cwd.abbreviatingHome
        // Home itself abbreviates to `~`, which has no last component worth
        // taking. A *remote* home does not abbreviate at all — this Mac's home
        // is the only one `abbreviatingWithTildeInPath` knows — so that case
        // falls through to the last component, which is the user's name.
        if abbreviated == "~" { return "~" }
        let tail = (abbreviated as NSString).lastPathComponent
        return tail.isEmpty ? nil : tail
    }

    public var displayName: String {
        if let displayAgent, !displayAgent.isEmpty { return displayAgent }
        if let agent, !agent.isEmpty { return agent }
        if let label, !label.isEmpty { return label }
        if let title, !title.isEmpty { return title }
        if let cwdName { return cwdName }
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
