import Darwin
import Foundation

public final class RemoteConnection: @unchecked Sendable {
    public let target: ConnectTarget
    public let herdrBinary: String
    public private(set) var localSocketPath: String

    private let workDir: URL
    private let controlPath: String
    private let lock = NSLock()
    private var isClosed = false

    public init(target: ConnectTarget, herdrBinary: String = HerdrPaths.localHerdrBinary()) throws {
        self.target = target
        self.herdrBinary = herdrBinary
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ht-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(6))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        workDir = dir
        controlPath = dir.appendingPathComponent("cm.sock").path
        localSocketPath = dir.appendingPathComponent("herdr.sock").path
    }

    deinit {
        close()
    }

    /// Work dirs are named `ht-<pid>-<random>`. A kill or a crash skips `close()`,
    /// so sweep the ones whose owner is gone instead of growing `$TMPDIR`.
    public static func pruneStaleWorkDirs() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        guard let entries = try? fm.contentsOfDirectory(atPath: tmp.path) else { return }
        let ownPid = ProcessInfo.processInfo.processIdentifier
        for name in entries where name.hasPrefix("ht-") {
            guard
                let pid = name.dropFirst("ht-".count).split(separator: "-").first.flatMap({ Int32($0) }),
                pid != ownPid,
                kill(pid, 0) != 0, errno == ESRCH
            else { continue }
            try? fm.removeItem(at: tmp.appendingPathComponent(name))
        }
    }

    public func open() throws {
        if target.isLocal {
            try openLocal()
            return
        }
        try startSSHMaster()
        let remoteSock = try ensureRemoteServer()
        // Both sockets: `HERDR_SOCKET_PATH=.../herdr.sock` makes
        // `herdr terminal session control` open `.../herdr-client.sock`, so
        // forwarding only the API socket fails at attach time, not connect time.
        try forwardSocket(localPath: localSocketPath, remotePath: remoteSock)
        try waitForLocalSocket(localSocketPath)
        let remoteClient = HerdrStatus.clientSocketPath(from: remoteSock)
        let localClient = HerdrStatus.clientSocketPath(from: localSocketPath)
        try forwardSocket(localPath: localClient, remotePath: remoteClient)
        try waitForLocalSocket(localClient)
    }

    public func close() {
        lock.lock()
        let alreadyClosed = isClosed
        isClosed = true
        lock.unlock()
        guard !alreadyClosed else { return }

        if !target.isLocal {
            // Bounded, because this is called from `windowWillClose` on the main
            // thread: asking the master to go now is worth a moment, but not
            // worth a window that will not close. `ControlPersist` reaps the
            // master anyway if the request does not get through.
            _ = ssh(["-O", "exit"], timeout: Self.controlExitTimeout)
        }
        try? FileManager.default.removeItem(at: workDir)
    }

    private func openLocal() throws {
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/herdr", isDirectory: true)
        let sessionDir = target.session.map { configDir.appendingPathComponent("sessions/\($0)", isDirectory: true) }
        localSocketPath = (sessionDir ?? configDir).appendingPathComponent("herdr.sock").path
        try ensureLocalServer()
        guard FileManager.default.fileExists(atPath: localSocketPath) else {
            throw HerdrRPCError(
                code: "local_socket",
                message: "No herdr socket at \(localSocketPath). Start one with `herdr server`."
            )
        }
    }

    private func ensureLocalServer() throws {
        let sessionArgs = target.session.map { ["--session", $0] } ?? []
        let status = ProcessRunner.run(
            executable: herdrBinary,
            arguments: sessionArgs + ["status", "server"],
            extraEnv: [:]
        )
        if HerdrStatus.isRunning(from: status.stdout) { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: herdrBinary)
        proc.arguments = sessionArgs + ["server"]
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.environment = HerdrPaths.loginPathEnv()
        try proc.run()
        // `openLocal` reports a better error than a bare timeout if this fails.
        try? waitForLocalSocket(localSocketPath, timeout: 3)
    }

    private func startSSHMaster() throws {
        let sshTarget = SSHTarget(host: target.host)
        let result = ProcessRunner.run(
            executable: "/usr/bin/ssh",
            arguments: [
                "-N", "-f",
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=15",
                "-o", "ControlMaster=yes",
                "-o", "ControlPersist=600",
                "-o", "ControlPath=\(controlPath)",
                "-o", "StreamLocalBindUnlink=yes",
                "-o", "ServerAliveInterval=30",
                "-o", "ServerAliveCountMax=3",
            ] + sshTarget.extraArgs + [sshTarget.destination],
            extraEnv: [:],
            timeout: Self.sshTimeout
        )
        if result.terminationStatus != 0 {
            throw HerdrRPCError(code: "ssh_failed", message: Self.sshError(result, host: target.host))
        }
    }

    /// Locate the remote herdr binary (Homebrew is not on non-interactive PATH)
    /// and return the API socket path from `herdr status server`.
    private func ensureRemoteServer() throws -> String {
        let result = ssh(["bash", "-s"], stdin: Self.remoteBootstrapScript(session: target.session))
        if result.terminationStatus != 0 {
            throw HerdrRPCError(
                code: "remote_server",
                message: result.combined.isEmpty ? "Could not start herdr server on \(target.host)." : result.combined
            )
        }
        guard let socket = HerdrStatus.socketPath(from: result.stdout) else {
            throw HerdrRPCError(
                code: "socket_path",
                message: "`herdr status server` on \(target.host) did not report a socket path:\n\(result.stdout)"
            )
        }
        return socket
    }

    /// Find herdr, make sure a server is *running*, and print its status.
    ///
    /// "Running" is the `status:` line and nothing else — see
    /// `HerdrStatus.isRunning`. A server that crashed leaves its socket file
    /// behind and `herdr status server` still exits 0, so the old exit-code test
    /// meant a crashed host never got its server restarted and every reconnect
    /// went on forwarding a dead socket: the only way back was `herdr --remote`.
    /// The script waits for the server it started and fails loudly with the log
    /// if it never comes up, rather than handing back a socket path that will
    /// only fail at the first request. The log is per-uid because `/tmp` on a
    /// remote box is shared: a path another user owns is a redirect that fails,
    /// so the server never starts and the log we quote belongs to someone else.
    static func remoteBootstrapScript(session: String?) -> String {
        let sessionArgs = session.map { "--session " + $0.shellEscaped } ?? ""
        let candidates = HerdrPaths.binaryCandidates
            .map { "\"" + $0.replacingOccurrences(of: "~/", with: "$HOME/") + "\"" }
            .joined(separator: " ")
        return """
        set -e
        HERDR=""
        for candidate in \(candidates)
        do
          if [ -x "$candidate" ]; then HERDR="$candidate"; break; fi
        done
        if [ -z "$HERDR" ]; then
          export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
          if command -v herdr >/dev/null 2>&1; then HERDR="$(command -v herdr)"; fi
        fi
        if [ -z "$HERDR" ]; then
          echo "herdr not found (checked Homebrew, mise, Nix, ~/.local/bin)" >&2
          exit 1
        fi
        running() {
          "$HERDR" \(sessionArgs) status server 2>/dev/null \\
            | grep -qE '^[[:space:]]*status:[[:space:]]*running[[:space:]]*$'
        }
        LOG="/tmp/herdglass-server-$(id -u).log"
        if ! running; then
          nohup "$HERDR" \(sessionArgs) server >"$LOG" 2>&1 &
          for _ in 1 2 3 4 5 6 7 8 9 10; do
            sleep 0.4
            if running; then break; fi
          done
        fi
        if ! running; then
          echo "herdr server would not start:" >&2
          "$HERDR" \(sessionArgs) status server >&2 || true
          tail -n 20 "$LOG" >&2 2>/dev/null || true
          exit 1
        fi
        "$HERDR" \(sessionArgs) status server
        """
    }

    private func forwardSocket(localPath: String, remotePath: String) throws {
        if FileManager.default.fileExists(atPath: localPath) {
            try FileManager.default.removeItem(atPath: localPath)
        }
        let result = ssh(["-O", "forward", "-L", "\(localPath):\(remotePath)"])
        if result.terminationStatus != 0 {
            throw HerdrRPCError(
                code: "forward_failed",
                message: result.combined.isEmpty
                    ? "Unix socket forward failed for \(remotePath)."
                    : result.combined
            )
        }
    }

    private func waitForLocalSocket(_ path: String, timeout: TimeInterval = 5) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw HerdrRPCError(code: "forward_timeout", message: "Herdr socket did not appear: \(path)")
    }

    /// How long `ssh -O exit` may take before the app stops waiting for it.
    private static let controlExitTimeout: TimeInterval = 3
    /// A dial that has not answered by now is not going to.
    private static let sshTimeout: TimeInterval = 30

    @discardableResult
    private func ssh(
        _ extra: [String],
        stdin: String? = nil,
        timeout: TimeInterval? = sshTimeout
    ) -> ProcessRunner.Result {
        let sshTarget = SSHTarget(host: target.host)
        var args = [
            "-o", "ControlPath=\(controlPath)",
            "-o", "ControlMaster=no",
            "-o", "BatchMode=yes",
        ] + sshTarget.extraArgs
        if extra.first == "-O" {
            // `-O` is a control-master command: options, then the destination.
            args += extra
            args.append(sshTarget.destination)
        } else {
            // Everything after the destination is joined with spaces and run by
            // the login shell, so remote scripts must arrive on stdin instead.
            args.append(sshTarget.destination)
            args += extra
        }
        return ProcessRunner.run(
            executable: "/usr/bin/ssh",
            arguments: args,
            extraEnv: [:],
            stdin: stdin,
            timeout: timeout
        )
    }

    private static func sshError(_ result: ProcessRunner.Result, host: String) -> String {
        var message = result.combined.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty {
            message = "SSH to \(host) failed."
        }
        if message.contains("Permission denied") || message.lowercased().contains("publickey") {
            message += "\n\nLoad your key with `ssh-add` first — Herdglass connects with BatchMode, so there is no passphrase prompt."
        }
        return message
    }
}

public enum HerdrStatus {
    /// Whether `herdr status server` reports a live server.
    ///
    /// It has to be the value of the `status:` line, exactly: `herdr status
    /// server` exits **0** whether the server is running or not — a crashed
    /// server still prints `status: not running` and a socket path, because the
    /// socket file it left behind is still there. Testing the exit code says
    /// "running" forever after a crash, and so does a `contains("running")`,
    /// which "not running" satisfies too. Either way nothing restarts the
    /// server and every reconnect forwards a dead socket.
    public static func isRunning(from status: String) -> Bool {
        for line in status.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("status:") else { continue }
            return trimmed.dropFirst("status:".count).trimmingCharacters(in: .whitespaces) == "running"
        }
        return false
    }

    public static func socketPath(from status: String) -> String? {
        for line in status.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("socket:") else { continue }
            let path = trimmed.dropFirst("socket:".count).trimmingCharacters(in: .whitespaces)
            if path.hasPrefix("/") { return path }
        }
        return nil
    }

    /// Herdr's direct-attach socket sits beside the API socket.
    public static func clientSocketPath(from apiSocket: String) -> String {
        if apiSocket.hasSuffix(".sock") {
            return String(apiSocket.dropLast(".sock".count)) + "-client.sock"
        }
        return apiSocket + "-client.sock"
    }
}
