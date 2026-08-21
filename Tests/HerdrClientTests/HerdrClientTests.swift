import Foundation
import HerdrClient
import Testing

// MARK: - ssh_config

@Test func parseSSHConfigHosts() {
    let config = """
    Host workbox
      HostName example.com
    Host *
      Compression yes
    Host dev staging
      User sasha
    """
    #expect(SSHConfig.hostAliases(from: config) == ["workbox", "dev", "staging"])
}

@Test func parseSSHConfigTolerateTabsEqualsAndComments() {
    let config = """
    # Host commented
    Host\tworkbox
    Host=onefield
    host lowercase
    Host !negated allowed
    Host wild?card
    Host workbox
    """
    #expect(SSHConfig.hostAliases(from: config) == ["workbox", "onefield", "lowercase", "allowed"])
}

@Test func parseSSHURL() {
    let target = SSHTarget(host: "ssh://you@server:2222")
    #expect(target.destination == "you@server")
    #expect(target.extraArgs == ["-p", "2222"])
}

@Test func plainHostNeedsNoExtraArgs() {
    let target = SSHTarget(host: "workbox")
    #expect(target.destination == "workbox")
    #expect(target.extraArgs.isEmpty)
}

// MARK: - Snapshot decoding

@Test func decodeSnapshot() throws {
    let json = """
    {
      "version": "0.8.2",
      "protocol": 20,
      "focused_pane_id": "w4:p1",
      "focused_tab_id": "w4:t1",
      "focused_workspace_id": "w4",
      "workspaces": [{
        "workspace_id": "w4", "number": 1, "label": "~", "focused": true,
        "pane_count": 1, "tab_count": 1, "active_tab_id": "w4:t1", "agent_status": "blocked"
      }],
      "tabs": [{
        "tab_id": "w4:t1", "workspace_id": "w4", "number": 1, "label": "1",
        "focused": true, "pane_count": 1, "agent_status": "blocked"
      }],
      "panes": [{
        "pane_id": "w4:p1", "terminal_id": "term_1", "workspace_id": "w4", "tab_id": "w4:t1",
        "focused": true, "agent_status": "blocked", "revision": 1, "cwd": "/tmp",
        "display_agent": "codex"
      }],
      "agents": []
    }
    """
    let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
    #expect(snapshot.workspaces.first?.agentStatus == .blocked)
    #expect(snapshot.panes.first?.displayName == "codex")
    #expect(snapshot.protocolVersion == 20)
}

@Test func paneDisplayNameFallsBackThroughTitles() throws {
    func pane(_ json: String) throws -> PaneInfo {
        try JSONDecoder().decode(PaneInfo.self, from: Data(json.utf8))
    }
    let base = """
    "pane_id": "w1:p1", "terminal_id": "t", "workspace_id": "w1", "tab_id": "w1:t1",
    "focused": false, "agent_status": "idle", "revision": 1
    """
    #expect(try pane("{\(base), \"label\": \"build\"}").displayName == "build")
    #expect(try pane("{\(base), \"terminal_title_stripped\": \"zsh\"}").displayName == "zsh")
    // Empty strings must not win over a later, populated field.
    #expect(try pane("{\(base), \"agent\": \"\", \"title\": \"vim\"}").displayName == "vim")
    #expect(try pane("{\(base)}").displayName == "w1:p1")
}

/// The directory beats the shell's own OSC title, which is `user@host:~` and
/// says nothing a window does not already say.
@Test func paneDisplayNamePrefersTheDirectoryOverTheTerminalTitle() throws {
    func pane(_ json: String) throws -> PaneInfo {
        try JSONDecoder().decode(PaneInfo.self, from: Data(json.utf8))
    }
    let base = """
    "pane_id": "w1:p1", "terminal_id": "t", "workspace_id": "w1", "tab_id": "w1:t1",
    "focused": false, "agent_status": "idle", "revision": 1
    """
    let home = NSHomeDirectory()

    #expect(
        try pane("""
        {\(base), "cwd": "/Users/x/projects/app",
         "terminal_title_stripped": "x@mac:~/app"}
        """).displayName == "app"
    )
    // Where the foreground program is, not where the shell started.
    #expect(
        try pane("""
        {\(base), "cwd": "/Users/x/projects/app", "foreground_cwd": "/Users/x/scratch"}
        """).displayName == "scratch"
    )
    // Home itself has no last component worth taking.
    #expect(try pane("{\(base), \"cwd\": \"\(home)\"}").displayName == "~")
    // A remote home does not abbreviate — only this Mac's does — so it falls
    // through to the last component rather than inventing a `~`.
    #expect(try pane("{\(base), \"cwd\": \"/home/sasha\"}").displayName == "sasha")
    // An explicit name still outranks the directory.
    #expect(
        try pane("{\(base), \"cwd\": \"/Users/x/app\", \"label\": \"build\"}")
            .displayName == "build"
    )
    // And the OSC title is still the last resort when there is no directory.
    #expect(
        try pane("{\(base), \"terminal_title_stripped\": \"vim\"}").displayName == "vim"
    )
}

// MARK: - Space and tab titles

/// Herdr reports the agent *kind* on the pane and the name somebody gave it on
/// `agents` alone, so a title that ignores `agents` can only ever say "claude".
private func titleSnapshot(
    workspaceLabel: String = "herdr-term",
    workspaceTokens: String = "",
    tabLabel: String = "1",
    tabs: String? = nil,
    panes: String,
    agents: String = ""
) throws -> SessionSnapshot {
    let tabsJSON = tabs ?? """
    {"tab_id": "w8:t1", "workspace_id": "w8", "number": 1, "label": "\(tabLabel)",
     "focused": true, "pane_count": 1, "agent_status": "idle"}
    """
    let json = """
    {
      "version": "0.8.2", "protocol": 20,
      "workspaces": [{
        "workspace_id": "w8", "number": 3, "label": "\(workspaceLabel)", "focused": true,
        "pane_count": 1, "tab_count": 1, "active_tab_id": "w8:t1", "agent_status": "idle",
        "tokens": {\(workspaceTokens)}
      }],
      "tabs": [\(tabsJSON)],
      "panes": [\(panes)],
      "agents": [\(agents)]
    }
    """
    return try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
}

/// A pane at a shell prompt: a directory and the shell's own OSC title, which
/// is the thing the directory has to beat.
private func shellPane(cwd: String = "/Users/x/projects/herdr-term") -> String {
    """
    {"pane_id": "w8:p1", "terminal_id": "t", "workspace_id": "w8", "tab_id": "w8:t1",
     "focused": true, "agent_status": "idle", "revision": 1,
     "cwd": "\(cwd)", "terminal_title_stripped": "x@mac:~/projects/herdr-term"}
    """
}

/// A pane hosting an agent, as Herdr really reports it: the *kind* only.
private func agentPane(cwd: String = "/Users/x/projects/herdr-term") -> String {
    """
    {"pane_id": "w8:p1", "terminal_id": "t", "workspace_id": "w8", "tab_id": "w8:t1",
     "focused": true, "agent_status": "idle", "revision": 1, "agent": "claude",
     "cwd": "\(cwd)", "terminal_title_stripped": "Claude Code"}
    """
}

/// The name lives here and nowhere else — `panes` carries only `agent`.
private let namedAgent = """
{"terminal_id": "t", "agent_status": "idle", "workspace_id": "w8", "tab_id": "w8:t1",
 "pane_id": "w8:p1", "focused": true, "revision": 1, "agent": "claude", "name": "reviewer"}
"""

@Test func anUnnamedTabIsNamedAfterWhatIsRunningInIt() throws {
    let shell = try titleSnapshot(panes: shellPane())
    #expect(shell.title(ofTab: shell.tabs[0]) == "herdr-term")

    let agent = try titleSnapshot(panes: agentPane(), agents: namedAgent)
    #expect(agent.title(ofTab: agent.tabs[0]) == "reviewer")

    // Without a name on `agents`, the kind is all there is.
    let unnamed = try titleSnapshot(panes: agentPane())
    #expect(unnamed.title(ofTab: unnamed.tabs[0]) == "claude")
}

@Test func aRenamedTabKeepsItsLabel() throws {
    let renamed = try titleSnapshot(tabLabel: "build", panes: agentPane(), agents: namedAgent)
    #expect(renamed.title(ofTab: renamed.tabs[0]) == "build")

    // A tab with no panes left has nothing else to be called.
    let empty = try titleSnapshot(tabLabel: "1", panes: "")
    #expect(empty.title(ofTab: empty.tabs[0]) == "1")
}

@Test func aSpaceIsNamedAfterWhereItIs() throws {
    // The agent belongs to a tab. A space says where, so the row still anchors
    // you in the host when three tabs are doing three different things.
    let agent = try titleSnapshot(panes: agentPane(), agents: namedAgent)
    #expect(agent.title(ofWorkspace: agent.workspaces[0]) == "herdr-term")

    // A home directory reads as `~`.
    let home = try titleSnapshot(
        workspaceLabel: "~",
        panes: agentPane(cwd: NSHomeDirectory()),
        agents: namedAgent
    )
    #expect(home.title(ofWorkspace: home.workspaces[0]) == "~")
}

/// A name somebody typed is not Herdr's to lose — and unlike a tab's, a space's
/// default label is a directory, so "chosen" means "matches no directory this
/// space is in".
@Test func aChosenSpaceLabelOutranksTheDirectory() throws {
    let named = try titleSnapshot(workspaceLabel: "backend", panes: agentPane(cwd: "/tmp/scratch"))
    #expect(named.title(ofWorkspace: named.workspaces[0]) == "backend")

    // The full abbreviated path counts as Herdr's too, not just the tail.
    let path = try titleSnapshot(
        workspaceLabel: "~/projects/app",
        panes: agentPane(cwd: "\(NSHomeDirectory())/projects/app")
    )
    #expect(path.title(ofWorkspace: path.workspaces[0]) == "app")

    // And so does a directory reported only as the space's creation cwd, which
    // is the label's real source once a pane has moved on.
    let token = try titleSnapshot(
        workspaceLabel: "herdr-term",
        workspaceTokens: #""cwd": "/Users/x/projects/herdr-term""#,
        panes: agentPane(cwd: "/tmp/scratch")
    )
    #expect(token.title(ofWorkspace: token.workspaces[0]) == "scratch")

    // Nothing to go on but the label.
    let empty = try titleSnapshot(workspaceLabel: "herdr-term", panes: "")
    #expect(empty.title(ofWorkspace: empty.workspaces[0]) == "herdr-term")
}

// MARK: - Tab position

/// Two tabs of a space Herdr has renumbered: `number` keeps the gap a closed
/// tab left behind, `label` does not. Reading a label against `number` is how
/// every tab but the first stopped following what was running in it.
private let gappyTabs = """
{"tab_id": "w8:t1", "workspace_id": "w8", "number": 1, "label": "1",
 "focused": false, "pane_count": 1, "agent_status": "idle"},
{"tab_id": "w8:t3", "workspace_id": "w8", "number": 3, "label": "2",
 "focused": true, "pane_count": 1, "agent_status": "idle"},
{"tab_id": "w8:t4", "workspace_id": "w8", "number": 4, "label": "docs",
 "focused": false, "pane_count": 1, "agent_status": "idle"}
"""

private let gappyPanes = """
{"pane_id": "w8:p1", "terminal_id": "t1", "workspace_id": "w8", "tab_id": "w8:t1",
 "focused": true, "agent_status": "idle", "revision": 1, "agent": "claude",
 "cwd": "/Users/x/projects/herdr-term"},
{"pane_id": "w8:p3", "terminal_id": "t3", "workspace_id": "w8", "tab_id": "w8:t3",
 "focused": true, "agent_status": "idle", "revision": 1, "cwd": "/tmp/scratch"},
{"pane_id": "w8:p4", "terminal_id": "t4", "workspace_id": "w8", "tab_id": "w8:t4",
 "focused": true, "agent_status": "idle", "revision": 1, "cwd": "/Users/x/notes"}
"""

@Test func tabPositionIgnoresTheGapsInHerdrsNumbering() throws {
    let snapshot = try titleSnapshot(tabs: gappyTabs, panes: gappyPanes)
    let tabs = snapshot.tabs(in: "w8")
    #expect(tabs.map { snapshot.position(ofTab: $0) } == [1, 2, 3])
    // Position is what Herdr's own labels say, which is the whole point.
    #expect(tabs.prefix(2).map(\.label) == ["1", "2"])
    #expect(tabs.map(\.number) == [1, 3, 4])
}

/// The bug this fixes: `w8:t3` is labelled "2" and numbered 3, so comparing the
/// two read as "somebody named this tab" and it never took a title again.
@Test func aTabPastTheFirstStillFollowsWhatIsRunningInIt() throws {
    let snapshot = try titleSnapshot(tabs: gappyTabs, panes: gappyPanes, agents: namedAgent)
    let tabs = snapshot.tabs(in: "w8")
    #expect(snapshot.title(ofTab: tabs[0]) == "reviewer")
    #expect(snapshot.title(ofTab: tabs[1]) == "scratch")
    // A label that is not the position is a name, and still wins.
    #expect(snapshot.title(ofTab: tabs[2]) == "docs")
}

@Test func aSpaceRowListsEveryTab() throws {
    let snapshot = try titleSnapshot(tabs: gappyTabs, panes: gappyPanes, agents: namedAgent)
    #expect(
        snapshot.tabSummaries(inWorkspace: "w8") == ["1 reviewer", "2 scratch", "3 docs"]
    )
    // A space with nothing in it lists nothing, rather than a stray number.
    let empty = try titleSnapshot(panes: "")
    #expect(empty.tabSummaries(inWorkspace: "w8") == ["1"])
    #expect(empty.tabSummaries(inWorkspace: "nope").isEmpty)
}

/// The tab follows the keyboard; the space still says where it is.
@Test func aSplitNamesTheTabAfterTheFocusedPane() throws {
    let panes = """
    {"pane_id": "w8:p1", "terminal_id": "t1", "workspace_id": "w8", "tab_id": "w8:t1",
     "focused": false, "agent_status": "idle", "revision": 1, "agent": "claude",
     "cwd": "/Users/x/projects/herdr-term"},
    {"pane_id": "w8:p2", "terminal_id": "t2", "workspace_id": "w8", "tab_id": "w8:t1",
     "focused": true, "agent_status": "idle", "revision": 1, "agent": "cursor",
     "cwd": "/Users/x/projects/herdr-term"}
    """
    let agents = """
    {"terminal_id": "t1", "agent_status": "idle", "workspace_id": "w8", "tab_id": "w8:t1",
     "pane_id": "w8:p1", "focused": false, "revision": 1, "agent": "claude", "name": "reviewer"},
    {"terminal_id": "t2", "agent_status": "idle", "workspace_id": "w8", "tab_id": "w8:t1",
     "pane_id": "w8:p2", "focused": true, "revision": 1, "agent": "cursor", "name": "second"}
    """
    let snapshot = try titleSnapshot(panes: panes, agents: agents)
    #expect(snapshot.title(ofTab: snapshot.tabs[0]) == "second")
    #expect(snapshot.title(ofWorkspace: snapshot.workspaces[0]) == "herdr-term")
}

@Test func homePathsAbbreviate() {
    #expect(NSHomeDirectory().abbreviatingHome == "~")
    #expect("\(NSHomeDirectory())/src/app".abbreviatingHome == "~/src/app")
    #expect("/opt/homebrew/bin".abbreviatingHome == "/opt/homebrew/bin")
}

// MARK: - Split layouts

private let splitTreeJSON = """
{
  "workspace_id": "w4", "tab_id": "w4:t1", "zoomed": false, "focused_pane_id": "w4:p1",
  "root": {
    "type": "split", "direction": "right", "ratio": 0.3,
    "first": {
      "type": "split", "direction": "down", "ratio": 0.75,
      "first": {"type": "pane", "pane_id": "w4:p1", "cwd": "/tmp"},
      "second": {"type": "pane", "pane_id": "w4:p3"}
    },
    "second": {"type": "pane", "pane_id": "w4:p2"}
  }
}
"""

@Test func decodeSplitTreeInDisplayOrder() throws {
    let tree = try JSONDecoder().decode(LayoutTree.self, from: Data(splitTreeJSON.utf8))
    #expect(tree.tabId == "w4:t1")
    #expect(tree.focusedPaneId == "w4:p1")
    #expect(tree.paneIds == ["w4:p1", "w4:p3", "w4:p2"])
    guard case .split(let direction, let ratio, _, _) = tree.root else {
        Issue.record("root should be a split")
        return
    }
    #expect(direction == .right)
    #expect(abs(ratio - 0.3) < 0.0001)
}

@Test func focusingANeighbourSaysWhichPaneItLandedOn() throws {
    // The GUI's selection follows this id, not the server's own focus, so a
    // reply that decodes to the wrong pane is a keystroke that moves the border
    // somewhere the user did not ask for. `no_neighbor` answers with the pane it
    // started from, which is what makes an edge press a no-op.
    let moved = try JSONDecoder().decode(PaneFocus.self, from: Data("""
    {"changed": true, "focused_pane_id": "w4:p1B", "source_pane_id": "w4:p1C"}
    """.utf8))
    #expect(moved.changed)
    #expect(moved.focusedPaneId == "w4:p1B")

    let edge = try JSONDecoder().decode(PaneFocus.self, from: Data("""
    {"changed": false, "focused_pane_id": "w4:p1C", "reason": "no_neighbor"}
    """.utf8))
    #expect(!edge.changed)
    #expect(edge.focusedPaneId == "w4:p1C")
    #expect(edge.reason == "no_neighbor")
}

@Test func splitRatioPathsAreFirstFalseSecondTrue() throws {
    // `layout.set_split_ratio` addresses a divider by the descent that reaches
    // it: false into `first`, true into `second`. A wrong path silently resizes
    // the wrong divider, so this is the mapping the GUI drags depend on.
    let tree = try JSONDecoder().decode(LayoutTree.self, from: Data(splitTreeJSON.utf8))
    #expect(tree.root.path(toPane: "w4:p1") == [false, false])
    #expect(tree.root.path(toPane: "w4:p3") == [false, true])
    #expect(tree.root.path(toPane: "w4:p2") == [true])
    #expect(tree.root.path(toPane: "w4:p9") == nil)
}

@Test func structureSignatureIgnoresRatiosOnly() throws {
    // The view hierarchy is only rebuilt when this changes; a dragged divider
    // must not tear down and respawn every bridge in the tab.
    let tree = try JSONDecoder().decode(LayoutTree.self, from: Data(splitTreeJSON.utf8))
    let moved = try JSONDecoder().decode(
        LayoutTree.self,
        from: Data(splitTreeJSON.replacingOccurrences(of: "0.3", with: "0.8").utf8)
    )
    #expect(tree.root.structureSignature == moved.root.structureSignature)

    let restructured = try JSONDecoder().decode(
        LayoutTree.self,
        from: Data(splitTreeJSON.replacingOccurrences(of: "\"direction\": \"right\"", with: "\"direction\": \"down\"").utf8)
    )
    #expect(tree.root.structureSignature != restructured.root.structureSignature)
}

@Test func layoutNodeRejectsAnUnknownKind() {
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(LayoutNode.self, from: Data(#"{"type":"tabgroup"}"#.utf8))
    }
}

@Test func snapshotCarriesPerTabLayoutsAndSignsThem() throws {
    let json = """
    {
      "version": "0.8.2", "protocol": 20,
      "focused_pane_id": "w4:p1", "focused_tab_id": "w4:t1", "focused_workspace_id": "w4",
      "workspaces": [{
        "workspace_id": "w4", "number": 1, "label": "~", "focused": true,
        "pane_count": 2, "tab_count": 1, "active_tab_id": "w4:t1", "agent_status": "idle"
      }],
      "tabs": [{
        "tab_id": "w4:t1", "workspace_id": "w4", "number": 1, "label": "1",
        "focused": true, "pane_count": 2, "agent_status": "idle"
      }],
      "panes": [
        {"pane_id": "w4:p1", "terminal_id": "t1", "workspace_id": "w4", "tab_id": "w4:t1",
         "focused": true, "agent_status": "idle", "revision": 1},
        {"pane_id": "w4:p2", "terminal_id": "t2", "workspace_id": "w4", "tab_id": "w4:t1",
         "focused": false, "agent_status": "working", "revision": 1}
      ],
      "agents": [],
      "layouts": [{
        "workspace_id": "w4", "tab_id": "w4:t1", "zoomed": false, "focused_pane_id": "w4:p1",
        "area": {"x": 0, "y": 0, "width": 80, "height": 24},
        "panes": [
          {"pane_id": "w4:p1", "focused": true, "rect": {"x": 0, "y": 0, "width": 40, "height": 24}},
          {"pane_id": "w4:p2", "focused": false, "rect": {"x": 41, "y": 0, "width": 39, "height": 24}}
        ],
        "splits": [{
          "id": "split_0_root", "direction": "right", "ratio": 0.5,
          "rect": {"x": 0, "y": 0, "width": 80, "height": 24}
        }]
      }]
    }
    """
    let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
    #expect(snapshot.tabs(in: "w4").map(\.tabId) == ["w4:t1"])
    #expect(snapshot.panes(in: "w4:t1").count == 2)
    let layout = try #require(snapshot.layout(forTab: "w4:t1"))
    #expect(layout.panes.count == 2)

    // The signature is what decides whether the tree is re-fetched: a moved
    // divider has to change it, a pane that only changed status must not.
    var moved = layout
    moved.splits[0].ratio = 0.8
    #expect(moved.signature != layout.signature)
    #expect(layout.signature == snapshot.layout(forTab: "w4:t1")?.signature)
}

@Test func snapshotToleratesAServerThatOmitsLayouts() throws {
    // 0.8.2 sends `layouts`, but a snapshot without it is still a snapshot; the
    // GUI falls back to a single pane rather than failing to decode.
    let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data(emptySnapshotJSON.utf8))
    #expect(snapshot.layouts.isEmpty)
    #expect(snapshot.panes.isEmpty)
}

@Test func agentStatusNeedsAttention() {
    #expect(AgentStatus.blocked.needsAttention)
    #expect(AgentStatus.done.needsAttention)
    #expect(!AgentStatus.working.needsAttention)
    #expect(!AgentStatus.idle.needsAttention)
    #expect(!AgentStatus.unknown.needsAttention)
}

// MARK: - Connect targets

@Test func connectTargetLocal() {
    #expect(ConnectTarget(host: "local").isLocal)
    #expect(ConnectTarget(host: "localhost").isLocal)
    #expect(ConnectTarget(host: "workbox").isLocal == false)
}

@Test func connectTargetTrimsAndDropsEmptySession() {
    let target = ConnectTarget(host: "  workbox \n", session: "   ")
    #expect(target.host == "workbox")
    #expect(target.session == nil)
    #expect(target.displayName == "workbox")
    #expect(ConnectTarget(host: "workbox", session: " agents ").displayName == "workbox · agents")
}

// MARK: - herdr status

@Test func parseHerdrStatusSocket() {
    let status = """
    status: running
    version: 0.8.2
    socket: /Users/sasha/.config/herdr/herdr.sock
    """
    #expect(HerdrStatus.socketPath(from: status) == "/Users/sasha/.config/herdr/herdr.sock")
}

@Test func ignoreNonAbsoluteSocketPaths() {
    #expect(HerdrStatus.socketPath(from: "socket: (none)") == nil)
    #expect(HerdrStatus.socketPath(from: "status: not running") == nil)
}

@Test func clientSocketSitsBesideAPISocket() {
    #expect(HerdrStatus.clientSocketPath(from: "/tmp/herdr.sock") == "/tmp/herdr-client.sock")
    #expect(HerdrStatus.clientSocketPath(from: "/tmp/herdr") == "/tmp/herdr-client.sock")
}

// MARK: - Framing

@Test func lineBufferSplitsOnNewlines() {
    let buffer = LineBuffer()
    buffer.append(Data("one\ntw".utf8))
    #expect(buffer.popLine().map { String(decoding: $0, as: UTF8.self) } == "one")
    #expect(buffer.popLine() == nil)
    buffer.append(Data("o\nthree\n".utf8))
    #expect(buffer.popLine().map { String(decoding: $0, as: UTF8.self) } == "two")
    #expect(buffer.popLine().map { String(decoding: $0, as: UTF8.self) } == "three")
    #expect(buffer.popLine() == nil)
}

@Test func lineBufferKeepsDrainingPastUndecodableBytes() {
    // A frame carrying raw non-UTF-8 bytes must not hide the records behind it.
    let buffer = LineBuffer()
    buffer.append(Data([0xFF, 0xFE]) + Data("\nafter\n".utf8))
    #expect(buffer.popLine() == Data([0xFF, 0xFE]))
    #expect(buffer.popLine().map { String(decoding: $0, as: UTF8.self) } == "after")
}

@Test func lineBufferEmitsEmptyLines() {
    let buffer = LineBuffer()
    buffer.append(Data("\n\n".utf8))
    #expect(buffer.popLine() == Data())
    #expect(buffer.popLine() == Data())
    #expect(buffer.popLine() == nil)
}

// MARK: - Subprocesses

@Test func processRunnerCapturesBothStreams() {
    let result = ProcessRunner.run(
        executable: "/bin/sh",
        arguments: ["-c", "printf out; printf err >&2; exit 3"],
        extraEnv: [:]
    )
    #expect(result.terminationStatus == 3)
    #expect(result.stdout == "out")
    #expect(result.stderr == "err")
    #expect(result.combined == "out\nerr")
}

@Test func processRunnerSurvivesOutputLargerThanThePipeBuffer() {
    // Reading only after `waitUntilExit()` deadlocks here at around 64 KB.
    let result = ProcessRunner.run(
        executable: "/bin/sh",
        arguments: ["-c", "yes herdr | head -c 400000"],
        extraEnv: [:]
    )
    #expect(result.terminationStatus == 0)
    #expect(result.stdout.utf8.count == 400_000)
}

@Test func processRunnerFeedsStdin() {
    let result = ProcessRunner.run(
        executable: "/bin/bash",
        arguments: ["-s"],
        extraEnv: [:],
        stdin: "echo from-stdin\n"
    )
    #expect(result.terminationStatus == 0)
    #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "from-stdin")
}

@Test func processRunnerReportsMissingExecutable() {
    let result = ProcessRunner.run(executable: "/nope/herdr", arguments: [], extraEnv: [:])
    #expect(result.terminationStatus == 127)
}

@Test func loginPathEnvPrependsHomebrew() {
    let path = HerdrPaths.loginPathEnv()["PATH"] ?? ""
    #expect(path.hasPrefix("/opt/homebrew/bin:/usr/local/bin:"))
}

// MARK: - RPC transport

/// Minimal stand-in for Herdr's API socket: answers one request, then hangs up,
/// which is what made a cached connection fail on every call after the first.
private final class OneShotJSONServer: @unchecked Sendable {
    let path: String
    private let listener: Int32
    private let accepted = Counter()

    var requestsServed: Int { accepted.value }

    init(reply: @escaping @Sendable (String) -> String) throws {
        path = FileManager.default.temporaryDirectory
            .appendingPathComponent("rpc-\(UUID().uuidString.prefix(8)).sock").path

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: bytes.count + 1) { destination in
                for (offset, byte) in bytes.enumerated() { destination[offset] = byte }
                destination[bytes.count] = 0
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw HerdrRPCError(code: "bind", message: "could not bind \(path)")
        }
        listener = fd

        let listener = fd
        let accepted = self.accepted
        let thread = Thread {
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 { return }
                var request = [UInt8](repeating: 0, count: 8192)
                let n = read(client, &request, request.count)
                if n > 0 {
                    accepted.increment()
                    let line = String(decoding: request.prefix(n), as: UTF8.self)
                    let response = Data((reply(line) + "\n").utf8)
                    response.withUnsafeBytes { _ = write(client, $0.baseAddress, $0.count) }
                }
                close(client) // Hang up, exactly like herdr does.
            }
        }
        thread.start()
    }

    func stop() {
        close(listener)
        try? FileManager.default.removeItem(atPath: path)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return storage }
        func increment() { lock.lock(); storage += 1; lock.unlock() }
    }
}

private let emptySnapshotJSON = """
{"version":"0.8.2","protocol":20,"workspaces":[],"tabs":[],"panes":[],"agents":[]}
"""

@Test func repeatedRequestsSurviveAServerThatHangsUpEachTime() throws {
    let server = try OneShotJSONServer { request in
        let id = request
            .split(separator: "\"")
            .drop(while: { $0 != "id" })
            .dropFirst(2)
            .first ?? "rpc-1"
        return #"{"id":"\#(id)","result":{"type":"session_snapshot","snapshot":\#(emptySnapshotJSON)}}"#
    }
    defer { server.stop() }

    let rpc = HerdrRPC(socketPath: server.path)
    for _ in 1...3 {
        #expect(try rpc.snapshot().protocolVersion == 20)
    }
    #expect(server.requestsServed == 3)
}

@Test func rpcErrorsSurfaceCodeAndMessage() throws {
    let server = try OneShotJSONServer { request in
        let id = request.split(separator: "\"").drop(while: { $0 != "id" }).dropFirst(2).first ?? "rpc-1"
        return #"{"id":"\#(id)","error":{"code":"no_such_pane","message":"unknown pane"}}"#
    }
    defer { server.stop() }

    let error = #expect(throws: HerdrRPCError.self) {
        try HerdrRPC(socketPath: server.path).focusPane("w9:p9")
    }
    #expect(error?.code == "no_such_pane")
    #expect(error?.message == "unknown pane")
}

@Test func aCommandThatOutlivesItsTimeoutIsKilledRatherThanWaitedOut() {
    // `ssh` runs on the main thread at quit; a network command with no deadline
    // is a window that will not close.
    let started = Date()
    let result = ProcessRunner.run(
        executable: "/bin/sleep",
        arguments: ["30"],
        extraEnv: [:],
        timeout: 0.4
    )
    #expect(Date().timeIntervalSince(started) < 5)
    #expect(result.terminationStatus != 0)
}

@Test func aServerThatNeverAnswersTimesOutRatherThanParkingTheCaller() throws {
    // Every request a session makes runs on one queue, so a read with no
    // deadline stops the whole window updating, not just this call.
    let server = try SilentJSONServer()
    defer { server.stop() }
    let rpc = HerdrRPC(socketPath: server.path, requestTimeout: 0.3)
    let started = Date()
    #expect(throws: (any Error).self) { try rpc.snapshot() }
    #expect(Date().timeIntervalSince(started) < 5)
}

@Test func unreachableSocketThrowsRatherThanHanging() {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("absent.sock").path
    #expect(throws: (any Error).self) {
        try HerdrRPC(socketPath: path).snapshot()
    }
}

@Test func layoutExportUnwrapsTheServerEnvelope() throws {
    let server = try OneShotJSONServer { request in
        let id = request.split(separator: "\"").drop(while: { $0 != "id" }).dropFirst(2).first ?? "rpc-1"
        // One line: the transport is NDJSON, so a pretty-printed payload would
        // arrive as several records and the last of them after a hang-up.
        let layout = splitTreeJSON.split(separator: "\n").joined()
        return #"{"id":"\#(id)","result":{"type":"layout_export","layout":\#(layout)}}"#
    }
    defer { server.stop() }

    let tree = try HerdrRPC(socketPath: server.path).layout(tabId: "w4:t1")
    #expect(tree.paneIds == ["w4:p1", "w4:p3", "w4:p2"])
}

@Test func creatingATabReadsTheTabCreatedResult() throws {
    // `tab.create` answers `tab_created`, not `tab_info`; expecting the wrong
    // one turns a working call into "Unexpected payload".
    let server = try OneShotJSONServer { request in
        let id = request.split(separator: "\"").drop(while: { $0 != "id" }).dropFirst(2).first ?? "rpc-1"
        let tab = #"{"tab_id":"w4:t2","workspace_id":"w4","number":2,"label":"2","#
            + #""focused":true,"pane_count":1,"agent_status":"unknown"}"#
        return #"{"id":"\#(id)","result":{"type":"tab_created","tab":\#(tab)}}"#
    }
    defer { server.stop() }

    let tab = try HerdrRPC(socketPath: server.path).createTab(workspaceId: "w4")
    #expect(tab.tabId == "w4:t2")
    #expect(tab.number == 2)
}

@Test func aWrongResultTypeIsReportedRatherThanDecoded() throws {
    let server = try OneShotJSONServer { request in
        let id = request.split(separator: "\"").drop(while: { $0 != "id" }).dropFirst(2).first ?? "rpc-1"
        return #"{"id":"\#(id)","result":{"type":"ok"}}"#
    }
    defer { server.stop() }

    #expect(throws: HerdrRPCError.self) {
        try HerdrRPC(socketPath: server.path).layout(tabId: "w4:t1")
    }
}

// MARK: - Event subscriptions

@Test func subscriptionListOmitsPaneScopedEvents() {
    // These require a `pane_id`; asking for one without it makes Herdr reject
    // the whole events.subscribe call, leaving the client with no events at all.
    let paneScoped = ["pane.agent_status_changed", "pane.scroll_changed", "pane.output_matched"]
    for type in paneScoped {
        #expect(!HerdrRPC.eventTypes.contains(type))
    }
    #expect(HerdrRPC.eventTypes.contains("pane.updated"))
    #expect(HerdrRPC.eventTypes.contains("workspace.closed"))
}

@Test func subscribeThrowsWhenTheServerRejectsTheSubscription() throws {
    let server = try OneShotJSONServer { _ in
        #"{"id":"sub","error":{"code":"invalid_request","message":"missing field `pane_id`"}}"#
    }
    defer { server.stop() }

    let error = #expect(throws: HerdrRPCError.self) {
        _ = try HerdrRPC(socketPath: server.path).subscribe {}
    }
    #expect(error?.message.contains("pane_id") == true)
}

@Test func subscribeSucceedsOnAnAcknowledgedSubscription() throws {
    let server = try OneShotJSONServer { _ in
        #"{"id":"sub","result":{"type":"subscription_started"}}"#
    }
    defer { server.stop() }

    let subscription = try HerdrRPC(socketPath: server.path).subscribe {}
    subscription.cancel()
}

// MARK: - Pane control channel

@Test func controlChannelFramesScrollCommandsAsNDJSON() throws {
    let channel = try #require(PaneControlChannel())
    defer { channel.close() }

    channel.scroll(.up, lines: 3)
    channel.scroll(.down, lines: 1)
    // Herdr rejects the whole command when `lines` is not positive, so the
    // channel must not put one on the wire at all.
    channel.scroll(.up, lines: 0)

    let fd = open(channel.path, O_RDONLY | O_NONBLOCK)
    try #require(fd >= 0)
    defer { close(fd) }
    var buffer = [UInt8](repeating: 0, count: 4096)
    let n = read(fd, &buffer, buffer.count)
    try #require(n > 0)

    let lines = LineBuffer()
    lines.append(Data(buffer.prefix(n)))
    var commands: [[String: String]] = []
    while let line = lines.popLine() {
        let object = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        commands.append(object.mapValues { "\($0)" })
    }

    #expect(commands.count == 2)
    #expect(commands.first == ["type": "terminal.scroll", "direction": "up", "lines": "3", "source": "wheel"])
    #expect(commands.last?["direction"] == "down")
}

@Test func controlChannelRemovesItsFIFOOnClose() throws {
    let channel = try #require(PaneControlChannel())
    let path = channel.path
    #expect(FileManager.default.fileExists(atPath: path))
    channel.close()
    #expect(!FileManager.default.fileExists(atPath: path))
}

// MARK: - Bridge options

@Test func bridgeReadsThePaneFromItsArguments() {
    let options = BridgeOptions(
        arguments: [
            "--bridge",
            "--target", "w4:p1",
            "--socket", "/tmp/ht/herdr.sock",
            "--herdr-bin", "/opt/homebrew/bin/herdr",
            "--control-pipe", "/tmp/herdr-term-ab.ctl",
        ],
        environment: [:]
    )
    #expect(options.target == "w4:p1")
    #expect(options.socketPath == "/tmp/ht/herdr.sock")
    #expect(options.herdrBinary == "/opt/homebrew/bin/herdr")
    #expect(options.controlPipe == "/tmp/herdr-term-ab.ctl")
}

/// libghostty drops a surface's `env_vars`, which is why the arguments exist at
/// all — but a bridge started by hand still has only the environment.
@Test func bridgeFallsBackToTheEnvironment() {
    let options = BridgeOptions(
        arguments: ["--bridge"],
        environment: [
            "HERDR_TERM_TARGET": "w1:p2",
            "HERDR_SOCKET_PATH": "/tmp/env/herdr.sock",
            "HERDR_BIN": "/usr/local/bin/herdr",
            "HERDR_TERM_CONTROL_PIPE": "/tmp/env.ctl",
        ]
    )
    #expect(options.target == "w1:p2")
    #expect(options.socketPath == "/tmp/env/herdr.sock")
    #expect(options.herdrBinary == "/usr/local/bin/herdr")
    #expect(options.controlPipe == "/tmp/env.ctl")
}

@Test func bridgeArgumentsWinOverTheEnvironment() {
    let options = BridgeOptions(
        arguments: ["--bridge", "--target", "w9:p9"],
        environment: ["HERDR_TERM_TARGET": "stale", "HERDR_BIN": "/usr/local/bin/herdr"]
    )
    #expect(options.target == "w9:p9")
    #expect(options.herdrBinary == "/usr/local/bin/herdr")
}

@Test func bridgeTargetIsEmptyWhenNobodyNamedAPane() {
    #expect(BridgeOptions(arguments: ["--bridge"], environment: [:]).target.isEmpty)
    // A flag whose value is missing must not swallow the next flag.
    let options = BridgeOptions(arguments: ["--socket", "--target", "w2:p3"], environment: [:])
    #expect(options.target == "w2:p3")
    #expect(options.socketPath == nil)
}

/// The argv is handed to libghostty as one shell string, so every element has
/// to survive `/bin/sh -c` — including an app bundle somebody moved into a
/// directory with a space in it.
@Test func bridgeArgvQuotesForTheShell() {
    let argv = BridgeOptions.argv(
        executablePath: "/Applications/My Apps/HerdrTerm",
        target: "w4:p1",
        socketPath: "/tmp/ht 1/herdr.sock",
        herdrBinary: "/opt/homebrew/bin/herdr",
        controlPipe: nil
    )
    #expect(argv.first == "/Applications/My Apps/HerdrTerm")
    #expect(!argv.contains("--control-pipe"))
    let command = argv.map(\.shellEscaped).joined(separator: " ")
    #expect(command.hasPrefix("'/Applications/My Apps/HerdrTerm' '--bridge'"))
    #expect(command.contains("'/tmp/ht 1/herdr.sock'"))

    let round = BridgeOptions(arguments: argv, environment: [:])
    #expect(round.target == "w4:p1")
    #expect(round.socketPath == "/tmp/ht 1/herdr.sock")
}

/// Accepts a connection and then says nothing at all — a forwarded socket whose
/// far end has stopped answering looks exactly like this.
private final class SilentJSONServer: @unchecked Sendable {
    let path: String
    private let listener: Int32

    init() throws {
        path = FileManager.default.temporaryDirectory
            .appendingPathComponent("silent-\(UUID().uuidString.prefix(8)).sock").path

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: bytes.count + 1) { destination in
                for (offset, byte) in bytes.enumerated() { destination[offset] = byte }
                destination[bytes.count] = 0
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw HerdrRPCError(code: "bind", message: "could not bind \(path)")
        }
        listener = fd

        let listening = fd
        let thread = Thread {
            var clients: [Int32] = []
            while true {
                let client = accept(listening, nil, nil)
                if client < 0 { break }
                // Held open, unanswered, until the server is torn down.
                clients.append(client)
            }
            for client in clients { close(client) }
        }
        thread.start()
    }

    func stop() {
        close(listener)
        try? FileManager.default.removeItem(atPath: path)
    }
}
