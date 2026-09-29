import Foundation

/// Learned receipt-item → category choices. Only non-basic choices are stored (basic is the default);
/// saving an item as basic forgets any rule for it.
enum ItemRules {
    struct Rule: Codable {
        var name: String      // as last printed on a receipt, for display and prompt hints
        var category: String
        var updated: Date
    }

    private static let storeKey = "itemRules"

    /// "KOFF III 0,33L" → "koff iii"; "Pepsi Max 1,5l" → "pepsi max". Size/price tokens are dropped so
    /// different pack sizes share a rule.
    static func key(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fi_FI"))
        let spaced = String(String.UnicodeScalarView(folded.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? $0 : " "
        }))
        return spaced.split(separator: " ")
            .filter { !$0.contains(where: \.isNumber) }
            .joined(separator: " ")
    }

    static func all() -> [String: Rule] {
        guard let d = UserDefaults.standard.data(forKey: storeKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Rule].self, from: d)) ?? [:]
    }

    private static func save(_ rules: [String: Rule]) {
        if let d = try? JSONEncoder().encode(rules) { UserDefaults.standard.set(d, forKey: storeKey) }
    }

    /// Overrides Claude's category with the learned one for exactly-matching items.
    static func apply(to items: [ReceiptItem]) -> [ReceiptItem] {
        let rules = all()
        guard !rules.isEmpty else { return items }
        return items.map { item in
            var item = item
            let k = key(item.name)
            if !k.isEmpty, let r = rules[k], let c = ReceiptCategory(rawValue: r.category) {
                item.category = c
                item.learned = true
            }
            return item
        }
    }

    /// Most recent rules, passed to Claude so similar (not just identical) items follow them.
    static func promptHints(limit: Int = 150) -> [(name: String, category: ReceiptCategory)] {
        all().values
            .sorted { $0.updated > $1.updated }
            .prefix(limit)
            .compactMap { r in ReceiptCategory(rawValue: r.category).map { (r.name, $0) } }
    }

    /// Called after a receipt is saved.
    static func learn(from items: [ReceiptItem]) {
        var rules = all()
        for item in items {
            let k = key(item.name)
            guard !k.isEmpty else { continue }
            if item.category == .basic {
                rules[k] = nil
            } else {
                rules[k] = Rule(name: item.name, category: item.category.rawValue, updated: Date())
            }
        }
        save(rules)
    }

    static func remove(_ key: String) {
        var rules = all()
        rules[key] = nil
        save(rules)
    }
}
