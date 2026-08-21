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
    /// before anything is connected. Nothing is dialled here — a row is dialled
    /// when it is selected, or by `restore()` at launch.
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

    /// Any connection with something unread, including a host the window is not
    /// currently showing — which is what makes ⇧⌘U able to jump to one.
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
            // Into its place in the order, not onto the end: the sidebar's order
            // is a rule (`local` first, then remotes by name), and a host added
            // mid-session has to obey it now rather than after a restart.
            let index = connections.firstIndex {
                ConnectTarget.precedes(target, $0.target)
            } ?? connections.count
            connections.insert(new, at: index)
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
        guard let selected = connections.first(where: { $0.id == id }) else { return }
        selectedConnectionId = id
        // Only one host renders, so which one it is has to be remembered as well
        // as where it was: without this a relaunch restores every host's
        // selection and then shows the first host in the sidebar.
        RecentsStore.rememberSelectedHost(selected.target)
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

    /// Detach a host because the user asked. That is also what takes it off the
    /// list of hosts the next launch dials — `disconnectAll` deliberately does
    /// not, because a window closing is not the user saying "leave this one
    /// alone".
    func disconnect(_ id: String) {
        guard let connection = connection(id: id) else { return }
        connection.session.disconnect()
        RecentsStore.markDetached(connection.target)
        delegate?.connectionsDidChange(self)
    }

    /// Dial the hosts that were attached when the app was last running, and land
    /// on one of them, so a restart comes back to the sessions it left rather
    /// than to a sidebar of dimmed rows.
    ///
    /// Every dial carries a completion, empty on purpose: a host that has gone
    /// away since is reported by its own sidebar row going to `failed`, and a
    /// restore of four hosts must not open four modal sheets over a window the
    /// user has not touched yet.
    func restore() {
        let restoring = RecentsStore.attached()
        let rows = connections.filter { restoring.contains($0.target) }
        guard let first = rows.first else { return }
        for row in rows where !row.isAttached {
            row.session.connect(row.target) { _ in }
        }
        if selectedConnectionId == nil {
            // The host the window was showing, if it is one of the ones coming
            // back; otherwise the first, which is now a stable order rather than
            // whichever host was connected to most recently.
            let last = RecentsStore.selectedHost().flatMap { target in rows.first { $0.target == target } }
            select((last ?? first).id, dial: false)
        }
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
