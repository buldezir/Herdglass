import Darwin
import Foundation

enum UnixSocketError: Error, LocalizedError {
    case pathTooLong(String)
    case connectFailed(String)
    case closed

    var errorDescription: String? {
        switch self {
        case .pathTooLong(let path):
            return "Socket path is too long for a Unix domain socket: \(path)"
        case .connectFailed(let message):
            return "Could not reach the Herdr socket: \(message)"
        case .closed:
            return "The Herdr socket closed."
        }
    }
}

/// Line-oriented JSON client over a Unix domain socket.
final class UnixJSONSocket: @unchecked Sendable {
    private let fd: Int32
    private let lines = LineBuffer()
    private let closeLock = NSLock()
    private var closed = false

    init(path: String) throws {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard pathBytes.count < maxLen else { throw UnixSocketError.pathTooLong(path) }

        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: maxLen) { dest in
                for (offset, byte) in pathBytes.enumerated() {
                    dest[offset] = byte
                }
                dest[pathBytes.count] = 0
            }
        }

        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else {
            throw UnixSocketError.connectFailed(String(cString: strerror(errno)))
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                connect(sock, sap, size)
            }
        }
        if result != 0 {
            let message = String(cString: strerror(errno))
            Darwin.close(sock)
            throw UnixSocketError.connectFailed(message)
        }
        fd = sock
    }

    deinit {
        closeQuietly()
    }

    func closeQuietly() {
        closeLock.lock()
        defer { closeLock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }

    func sendLine(_ object: [String: Any]) throws {
        var payload = try JSONSerialization.data(withJSONObject: object)
        payload.append(0x0A)
        try writeAll(payload)
    }

    /// Blocks until a full newline-terminated record is available.
    func readLine() throws -> Data {
        while true {
            if let line = lines.popLine() { return line }
            var chunk = [UInt8](repeating: 0, count: 8192)
            let n = chunk.withUnsafeMutableBytes { buffer in
                Darwin.read(fd, buffer.baseAddress, buffer.count)
            }
            if n == 0 { throw UnixSocketError.closed }
            if n < 0 {
                if errno == EINTR { continue }
                throw UnixSocketError.connectFailed(String(cString: strerror(errno)))
            }
            lines.append(Data(chunk.prefix(n)))
        }
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(fd, base.advanced(by: sent), raw.count - sent)
                if n < 0 && errno == EINTR { continue }
                if n == 0 { throw UnixSocketError.closed }
                if n < 0 { throw UnixSocketError.connectFailed(String(cString: strerror(errno))) }
                sent += n
            }
        }
    }
}
