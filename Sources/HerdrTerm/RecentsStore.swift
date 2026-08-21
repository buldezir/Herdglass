import Foundation
import HerdrClient

enum RecentsStore {
    private static let key = "herdr-term.recents"
    private static let attachedKey = "herdr-term.attached"

    static func load() -> [ConnectTarget] {
        decode(key)
    }

    static func remember(_ target: ConnectTarget) {
        var items = load().filter { $0 != target }
        items.insert(target, at: 0)
        if items.count > 12 { items = Array(items.prefix(12)) }
        save(items, to: key)
    }

    /// Forgetting a host is what removes its sidebar folder for good; without
    /// this the next launch would seed it straight back in.
    static func forget(_ target: ConnectTarget) {
        save(load().filter { $0 != target }, to: key)
        markDetached(target)
    }

    // MARK: - Hosts to dial again

    /// The hosts that were attached when the app was last running, in the order
    /// they are remembered in, so the next launch can put them back.
    ///
    /// This is deliberately *not* "every remembered host": a host is here
    /// because it was attached, and it leaves only when the user detaches it by
    /// hand (Disconnect, or Remove Host). Closing the window and quitting the app
    /// both tear every session down, so a flag cleared by `disconnect()` itself
    /// would be cleared by the very quit it is meant to survive — which is the
    /// whole reason this is a separate list rather than a bit on the session.
    static func attached() -> [ConnectTarget] {
        let attached = Set(decode(attachedKey))
        return load().filter(attached.contains)
    }

    static func markAttached(_ target: ConnectTarget) {
        var items = decode(attachedKey)
        guard !items.contains(target) else { return }
        items.append(target)
        save(items, to: attachedKey)
    }

    static func markDetached(_ target: ConnectTarget) {
        let items = decode(attachedKey)
        guard items.contains(target) else { return }
        save(items.filter { $0 != target }, to: attachedKey)
    }

    private static func decode(_ key: String) -> [ConnectTarget] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([ConnectTarget].self, from: data)) ?? []
    }

    private static func save(_ items: [ConnectTarget], to key: String) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
