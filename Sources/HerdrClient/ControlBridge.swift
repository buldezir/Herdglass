import Darwin
import Foundation

/// PTY child for libghostty: translates Herdr `terminal session control` NDJSON
/// into raw ANSI on stdout / keystrokes on stdin.
public enum ControlBridge {
    public static func run() {
        HerdrProcess.setUp()
        setvbuf(stdout, nil, _IONBF, 0)
        setvbuf(stdin, nil, _IONBF, 0)

        let env = ProcessInfo.processInfo.environment
        guard let target = env["HERDR_TERM_TARGET"], !target.isEmpty else {
            fputs("herdr-term-bridge: HERDR_TERM_TARGET is required\n", stderr)
            exit(2)
        }
        let herdr = env["HERDR_BIN"] ?? HerdrPaths.localHerdrBinary()
        let socket = env["HERDR_SOCKET_PATH"]
        var size = currentWinSize()
        if size.cols == 0 { size.cols = 80 }
        if size.rows == 0 { size.rows = 24 }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: herdr)
        proc.arguments = [
            "terminal", "session", "control", target, "--takeover",
            "--cols", "\(size.cols)", "--rows", "\(size.rows)",
        ]
        var processEnv = HerdrPaths.loginPathEnv()
        if let socket { processEnv["HERDR_SOCKET_PATH"] = socket }
        proc.environment = processEnv

        let toHerdr = Pipe()
        let fromHerdr = Pipe()
        proc.standardInput = toHerdr
        proc.standardOutput = fromHerdr
        proc.standardError = FileHandle.standardError

        do {
            try proc.run()
        } catch {
            fputs("herdr-term-bridge: failed to spawn herdr: \(error)\n", stderr)
            exit(1)
        }

        let io = BridgeIO(process: proc, herdrIn: toHerdr.fileHandleForWriting)
        io.startStdin()
        io.startWinch()
        io.startHerdrOutput(fromHerdr.fileHandleForReading)

        proc.waitUntilExit()
        io.close()
        // Keep pipes alive until herdr has fully exited.
        withExtendedLifetime(toHerdr) {}
        withExtendedLifetime(fromHerdr) {}
        exit(proc.terminationStatus == 0 ? 0 : max(Int32(proc.terminationStatus), 1))
    }
}

private final class BridgeIO: @unchecked Sendable {
    private let process: Process
    private let herdrIn: FileHandle
    private let herdrInFD: Int32
    private let writeLock = NSLock()
    private let lines = LineBuffer()
    private var stdinSource: DispatchSourceRead?
    private var winchSource: DispatchSourceSignal?
    private var closed = false

    init(process: Process, herdrIn: FileHandle) {
        self.process = process
        self.herdrIn = herdrIn
        self.herdrInFD = herdrIn.fileDescriptor
    }

    func close() {
        writeLock.lock()
        closed = true
        writeLock.unlock()
        stdinSource?.cancel()
        winchSource?.cancel()
    }

    func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        var payload = data
        payload.append(0x0A)
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !closed else { return }
        writeIgnoringBrokenPipe(herdrInFD, payload)
    }

    func startStdin() {
        let stdinFD = STDIN_FILENO
        let source = DispatchSource.makeReadSource(fileDescriptor: stdinFD, queue: .global(qos: .userInteractive))
        source.setEventHandler { [self] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            let n = read(stdinFD, &buffer, buffer.count)
            if n <= 0 {
                send(["type": "terminal.release"])
                source.cancel()
                if process.isRunning {
                    process.terminate()
                }
                return
            }
            send(["type": "terminal.input", "bytes": Data(buffer.prefix(n)).base64EncodedString()])
        }
        source.resume()
        stdinSource = source
    }

    func startWinch() {
        signal(SIGWINCH, SIG_IGN)
        let winch = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global(qos: .userInteractive))
        winch.setEventHandler { [self] in
            let ws = currentWinSize()
            guard ws.cols > 0, ws.rows > 0 else { return }
            send(["type": "terminal.resize", "cols": ws.cols, "rows": ws.rows])
        }
        winch.resume()
        winchSource = winch
    }

    func startHerdrOutput(_ herdrOut: FileHandle) {
        herdrOut.readabilityHandler = { [self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                if process.isRunning {
                    process.terminate()
                }
                return
            }
            lines.append(data)
            while let line = lines.popLine() {
                handleHerdrLine(line)
            }
        }
    }
}

private func handleHerdrLine(_ line: Data) {
    guard !line.isEmpty,
          let frame = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
          frame["type"] as? String == "terminal.frame",
          let encoded = frame["bytes"] as? String,
          let bytes = Data(base64Encoded: encoded),
          !bytes.isEmpty
    else { return }
    writeIgnoringBrokenPipe(STDOUT_FILENO, bytes)
}

private struct WinSize {
    var cols: Int
    var rows: Int
}

private func currentWinSize() -> WinSize {
    var ws = winsize()
    _ = ioctl(STDIN_FILENO, TIOCGWINSZ, &ws)
    return WinSize(cols: Int(ws.ws_col), rows: Int(ws.ws_row))
}
