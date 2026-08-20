import Foundation
import HerdrClient

enum RecentsStore {
    private static let key = "herdr-term.recents"

    static func load() -> [ConnectTarget] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([ConnectTarget].self, from: data)) ?? []
    }

    static func remember(_ target: ConnectTarget) {
        var items = load().filter { $0 != target }
        items.insert(target, at: 0)
        if items.count > 12 { items = Array(items.prefix(12)) }
        save(items)
    }

    /// Forgetting a host is what removes its sidebar folder for good; without
    /// this the next launch would seed it straight back in.
    static func forget(_ target: ConnectTarget) {
        save(load().filter { $0 != target })
    }

    private static func save(_ items: [ConnectTarget]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
