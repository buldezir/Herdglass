import Foundation

/// Herdr's NDJSON socket API.
///
/// Requests are one-shot: the server answers a single request and closes the
/// connection, so each call dials its own socket. Subscriptions are the
/// exception — that connection stays open and streams events.
public final class HerdrRPC: @unchecked Sendable {
    private let socketPath: String
    private let queue = DispatchQueue(label: "herdr.rpc")
    private var nextId = 1

    /// Every session-wide event that can change a workspace, tab or pane row.
    ///
    /// Deliberately excludes the pane-scoped subscriptions
    /// (`pane.agent_status_changed`, `pane.scroll_changed`,
    /// `pane.output_matched`): they require a `pane_id`, and including one
    /// without it makes Herdr reject the *whole* `events.subscribe` call, which
    /// leaves the client with no events at all.
    public static let eventTypes = [
        "workspace.created", "workspace.updated", "workspace.metadata_updated",
        "workspace.renamed", "workspace.moved", "workspace.reordered",
        "workspace.closed", "workspace.focused",
        "worktree.created", "worktree.opened", "worktree.removed",
        "tab.created", "tab.closed", "tab.focused", "tab.renamed", "tab.moved",
        "pane.created", "pane.closed", "pane.updated", "pane.focused", "pane.moved",
        "pane.exited", "pane.agent_detected",
        "layout.updated",
    ]

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func snapshot() throws -> SessionSnapshot {
        let result = try request(method: "session.snapshot", params: [:])
        guard
            result["type"] as? String == "session_snapshot",
            let payload = result["snapshot"]
        else {
            throw HerdrRPCError(code: "bad_snapshot", message: "Unexpected session.snapshot payload.")
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(SessionSnapshot.self, from: data)
    }

    public func focusPane(_ paneId: String) throws {
        _ = try request(method: "pane.focus", params: ["pane_id": paneId])
    }

    public func subscribe(onEvent: @escaping @Sendable () -> Void) throws -> EventSubscription {
        let socket = try UnixJSONSocket(path: socketPath)
        try socket.sendLine([
            "id": "sub",
            "method": "events.subscribe",
            "params": ["subscriptions": Self.eventTypes.map { ["type": $0] }],
        ])
        // Consume the acknowledgement here so a rejected subscription throws
        // instead of handing back a stream that will never deliver anything.
        do {
            try Self.checkSubscriptionAck(socket.readLine())
        } catch {
            socket.closeQuietly()
            throw error
        }

        let stopped = StopFlag()
        let thread = Thread {
            while !stopped.value {
                do {
                    let line = try socket.readLine()
                    guard !line.isEmpty else { continue }
                    onEvent()
                } catch {
                    // A dropped subscription is itself news: let the caller
                    // re-snapshot and notice the connection is gone.
                    if !stopped.value { onEvent() }
                    break
                }
            }
            socket.closeQuietly()
        }
        thread.name = "herdr.events"
        thread.start()
        return EventSubscription(stop: stopped, socket: socket)
    }

    /// Herdr answers `events.subscribe` with `subscription_started`, or with an
    /// error naming the offending subscription.
    static func checkSubscriptionAck(_ line: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw HerdrRPCError(code: "bad_subscription_ack", message: "Unreadable events.subscribe reply.")
        }
        if let error = object["error"] as? [String: Any] {
            throw HerdrRPCError(
                code: error["code"] as? String ?? "error",
                message: error["message"] as? String ?? "events.subscribe was rejected"
            )
        }
        guard (object["result"] as? [String: Any])?["type"] as? String == "subscription_started" else {
            throw HerdrRPCError(code: "bad_subscription_ack", message: "events.subscribe was not acknowledged.")
        }
    }

    private func request(method: String, params: [String: Any]) throws -> [String: Any] {
        try queue.sync {
            // A fresh socket per call: Herdr hangs up after answering, so a
            // cached connection makes every request after the first fail — and
            // the caller read that as a dropped session and reconnected in a loop.
            let socket = try UnixJSONSocket(path: socketPath)
            defer { socket.closeQuietly() }

            let id = "rpc-\(nextId)"
            nextId += 1
            try socket.sendLine(["id": id, "method": method, "params": params])

            while true {
                let line = try socket.readLine()
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                // Ignore anything not addressed to this request.
                guard object["id"] as? String == id else { continue }
                if let error = object["error"] as? [String: Any] {
                    throw HerdrRPCError(
                        code: error["code"] as? String ?? "error",
                        message: error["message"] as? String ?? "unknown error"
                    )
                }
                return object["result"] as? [String: Any] ?? [:]
            }
        }
    }
}

public final class EventSubscription: @unchecked Sendable {
    private let stop: StopFlag
    private let socket: UnixJSONSocket

    init(stop: StopFlag, socket: UnixJSONSocket) {
        self.stop = stop
        self.socket = socket
    }

    public func cancel() {
        stop.value = true
        socket.closeQuietly()
    }

    deinit { cancel() }
}

final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}
