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

@Test func unreachableSocketThrowsRatherThanHanging() {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("absent.sock").path
    #expect(throws: (any Error).self) {
        try HerdrRPC(socketPath: path).snapshot()
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
