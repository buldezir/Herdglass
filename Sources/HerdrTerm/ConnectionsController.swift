import Foundation
import HerdrClient

@MainActor
protocol ConnectionsControllerDelegate: AnyObject {
    func connectionsDidChange(_ controller: ConnectionsController)
    func connections(
        _ controller: ConnectionsController,
        didFail error: Error,
        on connection: ConnectionsController.Connection
    )
}

/// The hosts a window knows about, connected or not.
///
/// One window can hold several live Herdr servers at once — each is a sidebar
/// folder, each has its own SSH master, event stream and selection. Only the
/// selected one renders panes, so only its bridges are running.
@MainActor
final class ConnectionsController: SessionControllerDelegate {
    /// One host row: a target, plus the session that may or may not be attached
    /// to it. A parked row (remembered from a previous launch, or disconnected by
    /// hand) keeps its identity so selecting it again reconnects in place.
    @MainActor
    final class Connection {
        let id: String
        var target: ConnectTarget
        let session = SessionController()

        init(target: ConnectTarget) {
            id = UUID().uuidString
            self.target = target
        }

        var isAttached: Bool { session.state != .disconnected }
    }

    weak var delegate: ConnectionsControllerDelegate?

    private(set) var connections: [Connection] = []
    private(set) var selectedConnectionId: String?

    /// Hosts the user has used before, so the sidebar has something to show
    /// before anything is connected. Nothing is dialled until it is selected.
    init(remembering recents: [ConnectTarget] = RecentsStore.load()) {
        for target in recents {
            connections.append(makeConnection(target))
        }
    }

    var selected: Connection? {
        guard let selectedConnectionId else { return nil }
        return connections.first { $0.id == selectedConnectionId }
    }

    var selectedSession: SessionController? { selected?.session }

    func connection(id: String) -> Connection? {
        connections.first { $0.id == id }
    }

    /// Any connection with something unread, so the toolbar bell can light up
    /// for a host the window is not currently showing.
    var hasAttention: Bool {
        connections.contains { $0.session.hasAttention }
    }

    var firstConnectionNeedingAttention: Connection? {
        connections.first { $0.session.hasAttention }
    }

    // MARK: - Mutating the list

    /// Attach to a host. An existing row for the same target is reused rather
    /// than duplicated — connecting to `workbox` twice is one folder, not two.
    @discardableResult
    func connect(_ target: ConnectTarget, completion: ((Error?) -> Void)? = nil) -> Connection {
        let connection = connections.first { $0.target == target } ?? {
            let new = makeConnection(target)
            connections.append(new)
            return new
        }()
        select(connection.id, dial: false)
        if connection.session.state.isConnected {
            completion?(nil)
        } else {
            connection.session.connect(target, completion: completion)
        }
        delegate?.connectionsDidChange(self)
        return connection
    }

    /// Selecting a parked host is also how the user asks for it to be dialled —
    /// except when the caller is about to dial it itself with a completion to
    /// report into, which is what `dial: false` is for.
    func select(_ id: String, dial: Bool = true) {
        guard connections.contains(where: { $0.id == id }) else { return }
        selectedConnectionId = id
        for connection in connections {
            connection.session.isVisible = connection.id == id
        }
        if dial, let connection = self.connection(id: id), connection.session.state == .disconnected {
            connection.session.connect(connection.target)
        }
        delegate?.connectionsDidChange(self)
    }

    func reconnect(_ id: String) {
        guard let connection = connection(id: id) else { return }
        if connection.session.target == nil {
            connection.session.connect(connection.target)
        } else {
            connection.session.reconnect()
        }
    }

    func disconnect(_ id: String) {
        guard let connection = connection(id: id) else { return }
        connection.session.disconnect()
        delegate?.connectionsDidChange(self)
    }

    /// Drop the host from this window and from the remembered list; the row is
    /// only ever removed on an explicit ask.
    func forget(_ id: String) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        let connection = connections.remove(at: index)
        connection.session.disconnect()
        RecentsStore.forget(connection.target)
        if selectedConnectionId == id {
            selectedConnectionId = nil
            if let next = connections.first(where: { $0.isAttached }) ?? connections.first {
                select(next.id)
            }
        }
        delegate?.connectionsDidChange(self)
    }

    /// Every SSH master, event thread and bridge, torn down now rather than
    /// waiting for `ControlPersist` to expire.
    func disconnectAll() {
        for connection in connections {
            connection.session.disconnect()
        }
    }

    private func makeConnection(_ target: ConnectTarget) -> Connection {
        let connection = Connection(target: target)
        connection.session.delegate = self
        return connection
    }

    // MARK: - SessionControllerDelegate

    func sessionDidUpdate(_ session: SessionController) {
        delegate?.connectionsDidChange(self)
    }

    func sessionDidFail(_ session: SessionController, error: Error) {
        guard let connection = connections.first(where: { $0.session === session }) else { return }
        delegate?.connections(self, didFail: error, on: connection)
    }
}
