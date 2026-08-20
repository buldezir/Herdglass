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
        let fm = FileManager.default
        for candidate in binaryCandidates {
            let path = (candidate as NSString).expandingTildeInPath
            if fm.isExecutableFile(atPath: path) { return path }
        }
        let found = ProcessRunner.run(executable: "/usr/bin/which", arguments: ["herdr"], extraEnv: [:])
            .stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !found.isEmpty { return found }
        return "/opt/homebrew/bin/herdr"
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

    @discardableResult
    public static func run(
        executable: String,
        arguments: [String],
        extraEnv: [String: String],
        currentDirectory: String? = nil,
        stdin: String? = nil,
        inheritLoginPath: Bool = true
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
        proc.standardInput = input ?? FileHandle.nullDevice

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

        proc.waitUntilExit()
        group.wait()
        return Result(
            terminationStatus: proc.terminationStatus,
            stdout: String(decoding: stdoutBox.value, as: UTF8.self),
            stderr: String(decoding: stderrBox.value, as: UTF8.self)
        )
    }
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
    var shellEscaped: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
