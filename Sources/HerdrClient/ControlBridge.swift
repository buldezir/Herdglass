import Darwin
import Foundation

/// Everything the bridge needs to know, on its own argv.
///
/// It cannot come from the environment: libghostty does not pass a surface's
/// `env_vars` (or its `command`) through to the PTY child, so the GUI has to
/// hand the pane over as arguments baked into the command it configures. The
/// environment is still read as a fallback so `--bridge` stays runnable by
/// hand, and so an older GUI keeps working against a newer bridge.
public struct BridgeOptions: Equatable, Sendable {
    public var target: String
    public var socketPath: String?
    public var herdrBinary: String?
    public var controlPipe: String?

    public init(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) {
        var values: [String: String] = [:]
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let flag = arguments[index]
            guard flag.hasPrefix("--"), arguments.indices.contains(index + 1) else {
                index += 1
                continue
            }
            let value = arguments[index + 1]
            guard !value.hasPrefix("--") else {
                index += 1
                continue
            }
            values[flag] = value
            index += 2
        }

        func pick(_ flag: String, _ variable: String) -> String? {
            if let value = values[flag], !value.isEmpty { return value }
            if let value = environment[variable], !value.isEmpty { return value }
            return nil
        }

        target = pick("--target", "HERDR_TERM_TARGET") ?? ""
        socketPath = pick("--socket", "HERDR_SOCKET_PATH")
        herdrBinary = pick("--herdr-bin", "HERDR_BIN")
        controlPipe = pick("--control-pipe", PaneControlChannel.environmentKey)
    }

    /// The argv the GUI configures libghostty to run for a pane.
    public static func argv(
        executablePath: String,
        target: String,
        socketPath: String,
        herdrBinary: String,
        controlPipe: String?
    ) -> [String] {
        var argv = [
            executablePath, "--bridge",
            "--target", target,
            "--socket", socketPath,
            "--herdr-bin", herdrBinary,
        ]
        if let controlPipe, !controlPipe.isEmpty {
            argv += ["--control-pipe", controlPipe]
        }
        return argv
    }
}

/// A PTY's size in cells, which is the only size herdr deals in.
public struct PTYSize: Equatable, Sendable {
    public var cols: Int
    public var rows: Int

    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }
}

/// PTY child for libghostty: translates Herdr `terminal session control` NDJSON
/// into raw ANSI on stdout / keystrokes on stdin.
public enum ControlBridge {
    public static func run(arguments: [String] = Array(CommandLine.arguments.dropFirst())) {
        HerdrProcess.setUp()
        setvbuf(stdout, nil, _IONBF, 0)
        setvbuf(stdin, nil, _IONBF, 0)

        let options = BridgeOptions(arguments: arguments)
        let target = options.target
        guard !target.isEmpty else {
            fputs("herdglass-bridge: --target <pane> is required\n", stderr)
            exit(2)
        }
        let herdr = options.herdrBinary ?? HerdrPaths.localHerdrBinary()
        let socket = options.socketPath
        let cookedTerminal = enterRawMode()
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
            fputs("herdglass-bridge: failed to spawn herdr: \(error)\n", stderr)
            exit(1)
        }

        let io = BridgeIO(process: proc, herdrIn: toHerdr.fileHandleForWriting)
        io.startStdin()
        io.startWinch()
        // Read the size again now that the signal source exists, because the
        // one resize a pane cannot afford to miss is the one that lands here.
        // libghostty creates every surface at its own 800x600 and only hears
        // the real size once the pane view has been laid out, so a new pane's
        // PTY is always resized a moment after this process is forked — and a
        // SIGWINCH delivered before the source is armed is gone for good, since
        // the default action for SIGWINCH is to discard it. herdr then keeps
        // the `--cols/--rows` it was spawned with above, and the pane draws a
        // 400x300pt terminal in the corner of a full-size one until something
        // resizes the window: "switching spaces sometimes shrinks the
        // terminal". A change earlier than this read is caught by the read, a
        // change later than it by the source.
        if let resize = startupResize(spawned: size, current: currentWinSize()) {
            io.send(["type": "terminal.resize", "cols": resize.cols, "rows": resize.rows])
        }
        io.startHerdrOutput(fromHerdr.fileHandleForReading)
        if let controlPipe = options.controlPipe {
            io.startControlPipe(at: controlPipe)
        }

        proc.waitUntilExit()
        io.close()
        if var cookedTerminal { tcsetattr(STDIN_FILENO, TCSAFLUSH, &cookedTerminal) }
        // Keep pipes alive until herdr has fully exited.
        withExtendedLifetime(toHerdr) {}
        withExtendedLifetime(fromHerdr) {}
        exit(proc.terminationStatus == 0 ? 0 : max(Int32(proc.terminationStatus), 1))
    }

    /// The resize a starting bridge owes herdr, or nil when the PTY still has
    /// the size herdr was spawned with. See the call site for why a bridge is
    /// born owing one.
    public static func startupResize(spawned: PTYSize, current: PTYSize) -> PTYSize? {
        guard current.cols > 0, current.rows > 0, current != spawned else { return nil }
        return current
    }

    /// What tells libghostty whether the program in the pane has taken the
    /// mouse. Herdr strips the program's own mouse modes out of its frames and
    /// says so in a `terminal.mouse_capture` record instead, so the bridge
    /// writes a mode of its own into the surface: libghostty then stops
    /// selecting on a plain drag, keeps Shift for selection, and answers the
    /// GUI's `ghostty_surface_mouse_captured`. Press and release only, in SGR,
    /// because what libghostty reports back is thrown away (`MouseReportFilter`)
    /// — the GUI sends herdr the same click as `terminal.mouse`, which herdr
    /// encodes for the mode the program really asked for.
    public static func libghosttyMouseMode(capturing: Bool) -> Data {
        Data((capturing ? "\u{1B}[?1000h\u{1B}[?1006h" : "\u{1B}[?1000l\u{1B}[?1006l").utf8)
    }
}

/// Takes libghostty's own mouse reports out of what it types into the bridge.
///
/// They exist only while the bridge has put libghostty in a mouse mode (see
/// `ControlBridge.libghosttyMouseMode`), and by then the GUI has already sent
/// herdr the same event as `terminal.mouse`; passed on as `terminal.input` they
/// would reach the program twice, the second time in an encoding it may not
/// have asked for. An SGR report is `ESC [ <` digits `;` digits `;` digits and
/// `M` or `m`, which no key produces — keys never put `<` after `ESC [` — so
/// removing it cannot eat a keystroke. libghostty writes each report whole;
/// one cut by the end of a read is held for the next, but only from its `<`
/// on, because a bare `ESC` or `ESC [` at the end of a read is a key that must
/// not wait.
public struct MouseReportFilter {
    private var pending: [UInt8] = []

    public init() {}

    public mutating func filter(_ chunk: Data) -> Data {
        let bytes = pending + chunk
        pending = []
        var output = Data()
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x1B else {
                output.append(bytes[index])
                index += 1
                continue
            }
            switch Self.report(in: bytes, at: index) {
            case .complete(let end):
                index = end
            case .truncated:
                pending = Array(bytes[index...])
                return output
            case .none:
                output.append(bytes[index])
                index += 1
            }
        }
        return output
    }

    private enum Match {
        case complete(end: Int)
        case truncated
        case none
    }

    /// Whether an SGR mouse report starts at `start`, an `ESC`.
    private static func report(in bytes: [UInt8], at start: Int) -> Match {
        let introducer: [UInt8] = [0x1B, 0x5B, 0x3C] // ESC [ <
        var index = start
        for byte in introducer {
            guard index < bytes.count, bytes[index] == byte else { return .none }
            index += 1
        }
        var separators = 0
        var digits = 0
        while index < bytes.count {
            switch bytes[index] {
            case 0x30...0x39:
                digits += 1
            case 0x3B:
                guard digits > 0, separators < 2 else { return .none }
                separators += 1
                digits = 0
            case 0x4D, 0x6D:
                guard digits > 0, separators == 2 else { return .none }
                return .complete(end: index + 1)
            default:
                return .none
            }
            index += 1
        }
        return .truncated
    }
}

/// libghostty hands the bridge a *cooked* PTY, which is wrong in every way for
/// a pane whose keyboard lives on another machine: `icanon` holds keystrokes
/// until Enter so a TUI never sees an arrow key, `echo` paints them locally on
/// top of Herdr's frames, and `isig` turns ^C into a signal that kills the
/// bridge instead of a byte for the program in the pane. Returns the previous
/// settings so they can be put back.
private func enterRawMode() -> termios? {
    var original = termios()
    guard isatty(STDIN_FILENO) == 1, tcgetattr(STDIN_FILENO, &original) == 0 else { return nil }
    var raw = original
    cfmakeraw(&raw)
    guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else { return nil }
    return original
}

private final class BridgeIO: @unchecked Sendable {
    private let process: Process
    private let herdrIn: FileHandle
    private let herdrInFD: Int32
    private let writeLock = NSLock()
    private let lines = LineBuffer()
    private var stdinSource: DispatchSourceRead?
    private var winchSource: DispatchSourceSignal?
    private var controlSource: DispatchSourceRead?
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
        controlSource?.cancel()
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
        // A read source runs its handler serially, so the filter needs no lock.
        var mouseReports = MouseReportFilter()
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
            let input = mouseReports.filter(Data(buffer.prefix(n)))
            guard !input.isEmpty else { return }
            send(["type": "terminal.input", "bytes": input.base64EncodedString()])
        }
        source.resume()
        stdinSource = source
    }

    /// Commands the GUI cannot express as keystrokes — scrolling herdr's own
    /// scrollback, which stdin cannot reach because stdin is the pane's
    /// keyboard. Forwarded verbatim; the FIFO is ours and per pane.
    func startControlPipe(at path: String) {
        // O_RDWR mirrors the GUI side: neither end may ever see EOF just
        // because the other is idle.
        let fd = open(path, O_RDWR | O_NONBLOCK)
        guard fd >= 0 else {
            fputs("herdglass-bridge: cannot open control pipe \(path)\n", stderr)
            return
        }
        let commands = LineBuffer()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInteractive))
        source.setEventHandler { [self] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { return }
            commands.append(Data(buffer.prefix(n)))
            while let line = commands.popLine() {
                guard
                    let command = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                    let type = command["type"] as? String,
                    type.hasPrefix("terminal.")
                else { continue }
                send(command)
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        controlSource = source
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
    guard !line.isEmpty, let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
    switch record["type"] as? String {
    case "terminal.frame":
        guard let encoded = record["bytes"] as? String,
              let bytes = Data(base64Encoded: encoded),
              !bytes.isEmpty
        else { return }
        writeIgnoringBrokenPipe(STDOUT_FILENO, bytes)
    case "terminal.mouse_capture":
        // Herdr sends this when the program in the pane turns mouse reporting
        // on or off, and once when the bridge attaches. A herdr from before it
        // did never sends it, and libghostty then simply never captures.
        guard let enabled = record["enabled"] as? Bool else { return }
        writeIgnoringBrokenPipe(STDOUT_FILENO, ControlBridge.libghosttyMouseMode(capturing: enabled))
    default:
        return
    }
}

private func currentWinSize() -> PTYSize {
    var ws = winsize()
    _ = ioctl(STDIN_FILENO, TIOCGWINSZ, &ws)
    return PTYSize(cols: Int(ws.ws_col), rows: Int(ws.ws_row))
}
