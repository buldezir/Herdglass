import Foundation

/// Splits a byte stream into newline-delimited records.
///
/// Records come back as `Data`, not `String`: a single non-UTF-8 byte in one
/// frame must not stall the drain loop (`while let line = buffer.popLine()`),
/// which is what happens when an undecodable line reports itself as "no more
/// input" while complete records are still queued behind it.
public final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    public init() {}

    public func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        pending.append(data)
    }

    /// Removes and returns the next complete record, without its newline.
    public func popLine() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let newline = pending.firstIndex(of: 0x0A) else { return nil }
        let line = pending.subdata(in: pending.startIndex..<newline)
        pending.removeSubrange(pending.startIndex...newline)
        return line
    }
}
