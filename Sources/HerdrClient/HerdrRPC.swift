import Foundation

/// Herdr's NDJSON socket API.
///
/// Requests are one-shot: the server answers a single request and closes the
/// connection, so each call dials its own socket. Subscriptions are the
/// exception — that connection stays open and streams events.
public final class HerdrRPC: @unchecked Sendable {
    private let socketPath: String
    private let requestTimeout: TimeInterval
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

    /// A request that never gets an answer must not park the caller for ever:
    /// every call a session makes runs on one queue, so one stuck read would
    /// stop the whole window updating.
    public static let defaultRequestTimeout: TimeInterval = 15

    public init(socketPath: String, requestTimeout: TimeInterval = HerdrRPC.defaultRequestTimeout) {
        self.socketPath = socketPath
        self.requestTimeout = requestTimeout
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

    public func focusTab(_ tabId: String) throws {
        _ = try request(method: "tab.focus", params: ["tab_id": tabId])
    }

    public func focusWorkspace(_ workspaceId: String) throws {
        _ = try request(method: "workspace.focus", params: ["workspace_id": workspaceId])
    }

    /// The split tree of one tab. `session.snapshot` carries cell rectangles and
    /// a flat split list, but not how they nest, so the tree comes from here.
    public func layout(tabId: String) throws -> LayoutTree {
        let result = try request(method: "layout.export", params: ["tab_id": tabId])
        return try decode(LayoutTree.self, from: result, key: "layout", expecting: "layout_export")
    }

    @discardableResult
    public func splitPane(_ paneId: String, direction: SplitDirection, focus: Bool = true) throws -> PaneInfo {
        let result = try request(
            method: "pane.split",
            params: ["target_pane_id": paneId, "direction": direction.rawValue, "focus": focus]
        )
        return try decode(PaneInfo.self, from: result, key: "pane", expecting: "pane_info")
    }

    /// Move a divider. `path` is one bool per descent from the tab's root split:
    /// `false` into `first`, `true` into `second`.
    public func setSplitRatio(tabId: String, path: [Bool], ratio: Double) throws {
        _ = try request(
            method: "layout.set_split_ratio",
            params: ["tab_id": tabId, "path": path, "ratio": ratio]
        )
    }

    /// Herdr owns which pane a direction leads to, splits and all; asking it
    /// avoids the GUI having a second opinion about its own geometry.
    public func focusPane(from paneId: String, direction: PaneDirection) throws {
        _ = try request(
            method: "pane.focus_direction",
            params: ["pane_id": paneId, "direction": direction.rawValue]
        )
    }

    @discardableResult
    public func createTab(workspaceId: String, focus: Bool = true) throws -> TabInfo {
        let result = try request(
            method: "tab.create",
            params: ["workspace_id": workspaceId, "focus": focus]
        )
        return try decode(TabInfo.self, from: result, key: "tab", expecting: "tab_created")
    }

    public func closeTab(_ tabId: String) throws {
        _ = try request(method: "tab.close", params: ["tab_id": tabId])
    }

    @discardableResult
    public func createWorkspace() throws -> WorkspaceInfo {
        let result = try request(method: "workspace.create", params: ["focus": true])
        return try decode(WorkspaceInfo.self, from: result, key: "workspace", expecting: "workspace_created")
    }

    private func decode<T: Decodable>(
        _ type: T.Type,
        from result: [String: Any],
        key: String,
        expecting resultType: String
    ) throws -> T {
        guard result["type"] as? String == resultType, let payload = result[key] else {
            throw HerdrRPCError(
                code: "bad_result",
                message: "Unexpected \(resultType) payload."
            )
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(type, from: data)
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
            let socket = try UnixJSONSocket(path: socketPath, readTimeout: requestTimeout)
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
