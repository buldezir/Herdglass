import Foundation
import HerdrClient

enum RecentsStore {
    private static let key = "herdr-term.recents"
    private static let attachedKey = "herdr-term.attached"
    private static let selectionKey = "herdr-term.selection"
    private static let selectedHostKey = "herdr-term.selected-host"

    /// The hosts the sidebar shows, in the order it shows them: `local` first,
    /// then every remote by name (`ConnectTarget.inHostOrder`).
    ///
    /// The order is computed on the way out rather than stored, so it is the same
    /// on every launch whatever order the hosts were added in. What *is* stored
    /// is the order they were added (`stored()`), and that is only ever used to
    /// decide which one falls off the end of a full list.
    static func load() -> [ConnectTarget] {
        stored().inHostOrder
    }

    /// Add a host. A host already known is left alone — this runs on every
    /// `finishConnect`, including the dials a launch makes by itself, and the
    /// list has nothing to learn from a reconnect.
    static func remember(_ target: ConnectTarget) {
        var items = stored()
        guard !items.contains(target) else { return }
        items.append(target)
        // Appended, and capped from the front, because the *stored* list is in
        // the order hosts were added: the one to lose is the one used longest
        // ago, which is a question the sidebar's own order can no longer answer.
        if items.count > 12 { items = Array(items.suffix(12)) }
        save(items, to: key)
    }

    /// Forgetting a host is what removes its sidebar folder for good; without
    /// this the next launch would seed it straight back in.
    static func forget(_ target: ConnectTarget) {
        save(stored().filter { $0 != target }, to: key)
        markDetached(target)
        var selections = decodeSelections()
        selections[storageKey(target)] = nil
        saveSelections(selections)
        if selectedHost() == target {
            UserDefaults.standard.removeObject(forKey: selectedHostKey)
        }
    }

    // MARK: - Hosts to dial again

    /// The hosts that were attached when the app was last running, in sidebar
    /// order, so the next launch can put them back.
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

    // MARK: - Where the window was

    /// The space, tab and pane a host was showing, so attaching it again lands
    /// on the same screen rather than on whatever Herdr happens to have focused.
    ///
    /// Ids, not positions: a Herdr id outlives the client, and if the *server*
    /// has restarted since then none of these are found and the selection falls
    /// back to the server's focus, which is the right answer for a session this
    /// client has never seen.
    struct Selection: Codable, Equatable {
        var workspaceId: String?
        var tabId: String?
        var paneId: String?
    }

    static func selection(for target: ConnectTarget) -> Selection? {
        decodeSelections()[storageKey(target)]
    }

    static func rememberSelection(_ selection: Selection, for target: ConnectTarget) {
        var selections = decodeSelections()
        selections[storageKey(target)] = selection
        saveSelections(selections)
    }

    /// The host the window was showing. Only one host renders at a time, so
    /// coming back to the right *screen* needs this as well as the per-host
    /// selection — otherwise a relaunch lands on whichever remembered host
    /// happens to be first.
    static func selectedHost() -> ConnectTarget? {
        guard let data = UserDefaults.standard.data(forKey: selectedHostKey) else { return nil }
        return try? JSONDecoder().decode(ConnectTarget.self, from: data)
    }

    static func rememberSelectedHost(_ target: ConnectTarget) {
        guard let data = try? JSONEncoder().encode(target) else { return }
        UserDefaults.standard.set(data, forKey: selectedHostKey)
    }

    /// A host as one dictionary key. `ConnectTarget` trims both halves and turns
    /// an empty session into nil, so the pair is already canonical; the separator
    /// only has to be something neither half can contain.
    private static func storageKey(_ target: ConnectTarget) -> String {
        "\(target.host)\u{0}\(target.session ?? "")"
    }

    private static func decodeSelections() -> [String: Selection] {
        guard let data = UserDefaults.standard.data(forKey: selectionKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Selection].self, from: data)) ?? [:]
    }

    private static func saveSelections(_ selections: [String: Selection]) {
        guard let data = try? JSONEncoder().encode(selections) else { return }
        UserDefaults.standard.set(data, forKey: selectionKey)
    }

    /// The list as written: the order hosts were added, which is what the cap in
    /// `remember` needs and what nothing else should read.
    private static func stored() -> [ConnectTarget] {
        decode(key)
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
