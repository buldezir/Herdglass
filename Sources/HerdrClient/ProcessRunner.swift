import Darwin
import Foundation

public enum HerdrPaths {
    /// Install locations we check before falling back to `which`, because a GUI
    /// app inherits launchd's `PATH`, which has no Homebrew.
    static let binaryCandidates = [
        "/opt/homebrew/bin/herdr",
        "/usr/local/bin/herdr",
        "~/.local/bin/herdr",
        "~/.local/share/mise/shims/herdr",
        "~/.nix-profile/bin/herdr",
        "/nix/var/nix/profiles/default/bin/herdr",
    ]

    public static func localHerdrBinary() -> String {
        localHerdrBinaries().first ?? "/opt/homebrew/bin/herdr"
    }

    /// Every herdr installed on this Mac, in `binaryCandidates` order and once
    /// each: the Homebrew symlink and the Cellar binary behind it are one
    /// install, not two.
    public static func localHerdrBinaries() -> [String] {
        let fm = FileManager.default
        var seen: Set<String> = []
        var found: [String] = []
        for candidate in binaryCandidates {
            let path = (candidate as NSString).expandingTildeInPath
            guard fm.isExecutableFile(atPath: path) else { continue }
            // Keep the path as found: a mise shim resolves to `mise` itself and
            // only works when run under its own name.
            if seen.insert(URL(fileURLWithPath: path).resolvingSymlinksInPath().path).inserted {
                found.append(path)
            }
        }
        if found.isEmpty {
            let which = ProcessRunner.run(executable: "/usr/bin/which", arguments: ["herdr"], extraEnv: [:])
                .stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !which.isEmpty { found.append(which) }
        }
        return found
    }

    /// The herdr that attaches the panes of the server that sent `snapshot`;
    /// `host` is the host's display name, or nil for the server on this Mac.
    ///
    /// Attaching is `herdr terminal session control`, which speaks herdr's
    /// *private* terminal protocol to the server's client socket, and that has
    /// to match the server's exactly — herdr 0.8 speaks 20 and 0.9 speaks 22.
    /// A mismatch fails nowhere the API can see: the snapshot, the events and
    /// every request work, the server hangs up on the bridge's handshake, and
    /// the window fills in around panes that never draw.
    ///
    /// So a remote host attaches with its own release (`HerdrRelease`), never
    /// with whatever is installed here — one install cannot match a 0.8 host
    /// and a 0.9 host at once. The server on this Mac was started by a herdr
    /// installed here, so one of those normally speaks its protocol already;
    /// its release is only fetched for a server left running across an upgrade.
    public static func terminalClient(for snapshot: SessionSnapshot, host: String?) throws -> String {
        if host == nil {
            let installed = localHerdrBinaries().map { path in
                let status = ProcessRunner.run(executable: path, arguments: ["status", "client"], extraEnv: [:], timeout: 5)
                return HerdrStatus.client(at: path, from: status.terminationStatus == 0 ? status.stdout : "")
            }
            if let match = matchingClient(serverProtocol: snapshot.protocolVersion, among: installed) {
                return match
            }
        }
        do {
            return try HerdrRelease.binary(version: snapshot.version)
        } catch {
            let server = host.map { "\($0) runs herdr \(snapshot.version)" }
                ?? "The herdr server on this Mac is \(snapshot.version)"
            throw HerdrRPCError(
                code: "herdr_client",
                message: "\(server). Herdglass attaches to its panes with that same release, "
                    + "and could not get it: \(error.localizedDescription)."
            )
        }
    }

    /// The first install that speaks `serverProtocol` — by protocol, not by
    /// which path comes first, because a stale Homebrew herdr ahead of a
    /// current `~/.local/bin` one is exactly the trap. A server too old to
    /// report its protocol (0) leaves nothing to choose by.
    public static func matchingClient(serverProtocol: UInt32, among installed: [HerdrClientInfo]) -> String? {
        guard serverProtocol != 0 else { return installed.first?.path }
        return installed.first { $0.protocolVersion == serverProtocol }?.path
    }

    public static func loginPathEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extras = "/opt/homebrew/bin:/usr/local/bin:\(home)/.local/bin"
        if let path = env["PATH"], !path.isEmpty {
            env["PATH"] = extras + ":" + path
        } else {
            env["PATH"] = extras + ":/usr/bin:/bin"
        }
        if env["SSH_AUTH_SOCK"] == nil || !FileManager.default.fileExists(atPath: env["SSH_AUTH_SOCK"] ?? "") {
            if let sock = SSHEnvironment.authSock() {
                env["SSH_AUTH_SOCK"] = sock
            }
        }
        return env
    }
}

public enum SSHEnvironment {
    /// GUI apps launched with `open` often lose `SSH_AUTH_SOCK`; recover it from launchd or tmp.
    public static func authSock() -> String? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"], fm.fileExists(atPath: env) {
            return env
        }
        if let fromLaunchctl = launchctlGetenv("SSH_AUTH_SOCK"), fm.fileExists(atPath: fromLaunchctl) {
            return fromLaunchctl
        }
        let tmp = "/private/tmp"
        if let entries = try? fm.contentsOfDirectory(atPath: tmp) {
            for name in entries where name.hasPrefix("com.apple.launchd.") {
                let listener = tmp + "/" + name + "/Listeners"
                if fm.fileExists(atPath: listener) { return listener }
            }
        }
        return nil
    }

    private static func launchctlGetenv(_ key: String) -> String? {
        let result = ProcessRunner.run(
            executable: "/bin/launchctl",
            arguments: ["getenv", key],
            extraEnv: [:],
            inheritLoginPath: false
        )
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

public enum ProcessRunner {
    public struct Result: Sendable {
        public var terminationStatus: Int32
        public var stdout: String
        public var stderr: String
        public var combined: String { [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n") }
    }

    /// Run a command and collect its output.
    ///
    /// `timeout` is not optional decoration: this runs `ssh` for everything from
    /// dialling a host to `-O exit` at quit, some of it on the main thread, and
    /// a network command with no deadline is a window that stops answering.
    @discardableResult
    public static func run(
        executable: String,
        arguments: [String],
        extraEnv: [String: String],
        currentDirectory: String? = nil,
        stdin: String? = nil,
        stdinFile: URL? = nil,
        inheritLoginPath: Bool = true,
        timeout: TimeInterval? = nil
    ) -> Result {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        var env = inheritLoginPath ? HerdrPaths.loginPathEnv() : ProcessInfo.processInfo.environment
        for (key, value) in extraEnv { env[key] = value }
        proc.environment = env
        if let currentDirectory {
            proc.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }

        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        let input = stdin.map { _ in Pipe() }
        let fileInput: FileHandle?
        do {
            fileInput = try stdinFile.map { try FileHandle(forReadingFrom: $0) }
        } catch {
            return Result(terminationStatus: 127, stdout: "", stderr: error.localizedDescription)
        }
        defer { try? fileInput?.close() }
        proc.standardInput = fileInput ?? input?.fileHandleForReading ?? FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            return Result(terminationStatus: 127, stdout: "", stderr: error.localizedDescription)
        }

        // Drain both pipes while the child runs. Calling `waitUntilExit()` first
        // deadlocks as soon as a child writes more than the ~64 KB pipe buffer.
        let stdoutBox = DataBox()
        let stderrBox = DataBox()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "herdr.process-runner", attributes: .concurrent)
        queue.async(group: group) { stdoutBox.value = out.fileHandleForReading.readDataToEndOfFile() }
        queue.async(group: group) { stderrBox.value = err.fileHandleForReading.readDataToEndOfFile() }
        if let input, let stdin {
            queue.async(group: group) {
                // POSIX write, not FileHandle.write: a child that exits early
                // closes the pipe, and FileHandle turns EPIPE into an
                // unrecoverable ObjC exception.
                writeIgnoringBrokenPipe(input.fileHandleForWriting.fileDescriptor, Data(stdin.utf8))
                try? input.fileHandleForWriting.close()
            }
        }

        if let timeout, !waitForExit(proc, timeout: timeout) {
            // Killed rather than waited out: the pipes then hit EOF, so the
            // drain below still finishes and we report what did arrive.
            proc.terminate()
            _ = waitForExit(proc, timeout: 1)
            if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
        }
        proc.waitUntilExit()
        group.wait()
        return Result(
            terminationStatus: proc.terminationStatus,
            stdout: String(decoding: stdoutBox.value, as: UTF8.self),
            stderr: String(decoding: stderrBox.value, as: UTF8.self)
        )
    }
}

/// Poll for the child rather than blocking in `waitUntilExit`, so a deadline
/// can be enforced without a second thread.
private func waitForExit(_ proc: Process, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while proc.isRunning {
        if Date() >= deadline { return false }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return true
}

/// Writes every byte, tolerating a reader that has already gone away.
/// Requires `SIGPIPE` to be ignored process-wide (see `HerdrProcess.setUp`).
func writeIgnoringBrokenPipe(_ fd: Int32, _ data: Data) {
    data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var sent = 0
        while sent < raw.count {
            let n = Darwin.write(fd, base.advanced(by: sent), raw.count - sent)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return }
            sent += n
        }
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var value: Data {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

public enum HerdrProcess {
    /// Every entry point needs this: `write` to a pipe whose reader has exited
    /// otherwise kills the process instead of returning `EPIPE`.
    public static func setUp() {
        signal(SIGPIPE, SIG_IGN)
    }
}

extension String {
    /// POSIX single-quote quoting, for a string that has to survive `/bin/sh -c`.
    public var shellEscaped: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
