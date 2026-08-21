import Darwin
import Foundation

/// Out-of-band GUI → bridge channel, one FIFO per attached pane.
///
/// Scrolling cannot ride the PTY. Everything the surface writes to the bridge's
/// stdin becomes `terminal.input`, which herdr hands to the program in the
/// pane; the scrollback belongs to herdr and only moves for an explicit
/// `terminal.scroll`. So the GUI makes a FIFO, passes its path to the bridge in
/// the environment, and writes NDJSON control commands to it.
public final class PaneControlChannel {
    /// Environment variable the bridge reads the FIFO path from.
    public static let environmentKey = "HERDR_TERM_CONTROL_PIPE"

    public enum ScrollDirection: String {
        case up
        case down
    }

    public let path: String
    private var fd: Int32 = -1

    /// Returns nil when the FIFO cannot be made; the pane then simply has no
    /// control channel, which costs scrolling and nothing else.
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

    public func scroll(_ direction: ScrollDirection, lines: Int) {
        guard lines > 0 else { return }
        send([
            "type": "terminal.scroll",
            "direction": direction.rawValue,
            "lines": lines,
            // Let herdr decide what a wheel means for this pane; a program that
            // has taken the mouse gets the event instead of the scrollback.
            "source": "wheel",
        ])
    }

    public func send(_ command: [String: Any]) {
        guard fd >= 0, let data = try? JSONSerialization.data(withJSONObject: command) else { return }
        var payload = data
        payload.append(0x0A)
        writeIgnoringBrokenPipe(fd, payload)
    }

    public func close() {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
        unlink(path)
    }
}
