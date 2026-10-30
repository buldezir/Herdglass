import Darwin
import Foundation

/// Out-of-band GUI → bridge channel, one FIFO per attached pane.
///
/// Scrolling and the mouse cannot ride the PTY. Everything the surface writes
/// to the bridge's stdin becomes `terminal.input`, which herdr hands to the
/// program in the pane; the scrollback belongs to herdr and only moves for an
/// explicit `terminal.scroll`, and a click only reaches a program that asked
/// for the mouse as a `terminal.mouse`. So the GUI makes a FIFO, passes its
/// path to the bridge as `--control-pipe`, and writes NDJSON control commands
/// to it.
public final class PaneControlChannel {
    /// Environment variable the bridge reads the FIFO path from.
    public static let environmentKey = "HERDR_TERM_CONTROL_PIPE"

    /// The most commands one scroll writes. Each line is a command of its own
    /// (see `scroll`) of about a hundred bytes, so this keeps a flung trackpad
    /// well inside the FIFO's buffer: a write that does not fit is cut short,
    /// and a torn line loses the command after it too.
    public static let maximumScrollLines = 64

    public enum ScrollDirection: String {
        case up
        case down
    }

    public enum MouseAction: String {
        case down
        case up
        case drag
        case move
    }

    /// The buttons herdr can encode; it has no report for any other.
    public enum MouseButton: String {
        case left
        case right
        case middle
    }

    /// A cell of the pane's viewport, zero-based. Herdr takes a mouse position
    /// in nothing else.
    public struct Cell: Equatable, Sendable {
        public var column: Int
        public var row: Int

        public init(column: Int, row: Int) {
            self.column = column
            self.row = row
        }
    }

    /// Herdr's modifier bits, which are crossterm's. It reads no others.
    public struct Modifiers: OptionSet, Equatable, Sendable {
        public let rawValue: UInt8

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        public static let shift = Modifiers(rawValue: 1)
        public static let control = Modifiers(rawValue: 2)
        public static let alt = Modifiers(rawValue: 4)
    }

    private struct MouseReport: Equatable {
        var action: MouseAction
        var button: MouseButton
        var cell: Cell
        var modifiers: Modifiers
    }

    public let path: String
    private var fd: Int32 = -1
    private var lastMouseReport: MouseReport?

    /// Returns nil when the FIFO cannot be made; the pane then simply has no
    /// control channel, which costs scrolling and the mouse and nothing else.
    public init?(directory: URL = FileManager.default.temporaryDirectory) {
        let name = "herdglass-\(UUID().uuidString.prefix(8)).ctl"
        let url = directory.appendingPathComponent(name)
        guard mkfifo(url.path, 0o600) == 0 else { return nil }
        // O_RDWR, not O_WRONLY: the bridge has not opened its end yet, and a
        // write-only open of a readerless FIFO fails with ENXIO. Holding the
        // read end open also keeps the bridge from seeing EOF whenever the GUI
        // happens to have nothing to say.
        let descriptor = open(url.path, O_RDWR | O_NONBLOCK)
        guard descriptor >= 0 else {
            unlink(url.path)
            return nil
        }
        path = url.path
        fd = descriptor
    }

    deinit { close() }

    /// A wheel turned `lines` lines over `cell`.
    ///
    /// Herdr decides what a wheel means for the pane: its own scrollback moves
    /// by `lines`, but a program that has taken the mouse gets exactly one wheel
    /// report per command whatever `lines` says (and alternate scroll one arrow
    /// key), at `cell` — the top-left cell when there is none. Ghostty reports
    /// one wheel event per line, so a scroll of N lines is N commands of one,
    /// in a single write.
    public func scroll(_ direction: ScrollDirection, lines: Int, at cell: Cell? = nil, modifiers: Modifiers = []) {
        guard lines > 0 else { return }
        var command: [String: Any] = [
            "type": "terminal.scroll",
            "direction": direction.rawValue,
            "lines": 1,
            "source": "wheel",
        ]
        if let cell {
            command["column"] = cell.column
            command["row"] = cell.row
        }
        if !modifiers.isEmpty {
            command["modifiers"] = Int(modifiers.rawValue)
        }
        send(Array(repeating: command, count: min(lines, Self.maximumScrollLines)))
    }

    /// A click, drag or move at `cell`. Herdr encodes it for the mouse mode the
    /// program in the pane asked for and drops it when it asked for none — the
    /// frames herdr sends carry no mouse modes, so this side cannot know which,
    /// and sends it either way. `button` means nothing to a `move`.
    ///
    /// AppKit reports the pointer per point and herdr addresses it per cell, so
    /// a drag or move that has not left the cell of the last one is not sent.
    public func mouse(_ action: MouseAction, button: MouseButton = .left, at cell: Cell, modifiers: Modifiers = []) {
        let report = MouseReport(
            action: action,
            button: action == .move ? .left : button,
            cell: cell,
            modifiers: modifiers
        )
        if action == .drag || action == .move, report == lastMouseReport { return }
        lastMouseReport = report

        var command: [String: Any] = [
            "type": "terminal.mouse",
            "action": action.rawValue,
            "column": cell.column,
            "row": cell.row,
        ]
        if action != .move {
            command["button"] = button.rawValue
        }
        if !modifiers.isEmpty {
            command["modifiers"] = Int(modifiers.rawValue)
        }
        send(command)
    }

    public func send(_ command: [String: Any]) {
        send([command])
    }

    private func send(_ commands: [[String: Any]]) {
        guard fd >= 0 else { return }
        var payload = Data()
        for command in commands {
            guard let data = try? JSONSerialization.data(withJSONObject: command) else { continue }
            payload.append(data)
            payload.append(0x0A)
        }
        guard !payload.isEmpty else { return }
        writeIgnoringBrokenPipe(fd, payload)
    }

    public func close() {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
        unlink(path)
    }
}
