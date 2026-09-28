/// Sidebar sections by repo, shown only once sessions span more than one repo.
public enum Grouping {
    public struct Group<Item> {
        /// The section's key, like the repo's path. Nil for the unnamed section at the top.
        public let key: String?
        public let items: [Item]

        public init(key: String?, items: [Item]) {
            self.key = key
            self.items = items
        }
    }

    /// Items without a key come first, in one unnamed group. The others follow, one group per key, in order of first appearance.
    /// With fewer than two keys everything stays in one unnamed group, in its original order.
    public static func group<Item>(_ items: [Item], by key: (Item) -> String?) -> [Group<Item>] {
        var keys: [String] = []
        var byKey: [String: [Item]] = [:]
        var loose: [Item] = []
        for item in items {
            guard let k = key(item) else {
                loose.append(item)
                continue
            }
            if byKey[k] == nil { keys.append(k) }
            byKey[k, default: []].append(item)
        }
        guard keys.count > 1 else { return [Group(key: nil, items: items)] }
        let named = keys.map { Group(key: $0, items: byKey[$0]!) }
        return loose.isEmpty ? named : [Group(key: nil, items: loose)] + named
    }
}
