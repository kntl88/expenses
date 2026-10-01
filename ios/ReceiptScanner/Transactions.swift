import Foundation

/// A purchase as the phone shows it: one or more expense rows (one per category) that belong
/// together, optionally with the receipt's line items. Built from the flat rows in expenses.json.
struct Transaction: Identifiable, Hashable {
    struct Row: Hashable {
        let id: String
        let amount: Double          // positive euros
        let category: String
        let subCategory: String?
        let description: String
        let items: [Item]

        var token: ReceiptCategory? { Transaction.token(category: category, subCategory: subCategory) }
        var label: String { token?.label ?? Transaction.categoryLabel(category) }
    }

    struct Item: Hashable {
        let name: String
        let amount: Double
    }

    let id: String                  // txId, or the single row's id
    let date: String
    let created: String
    let account: String?
    /// When it was paid (HH:MM), if known.
    let time: String?
    let rows: [Row]
    let pending: Bool

    var total: Double { Format.round2(rows.reduce(0) { $0 + $1.amount }) }
    var rowIds: Set<String> { Set(rows.map(\.id)) }
    var isItemized: Bool { rows.contains { !$0.items.isEmpty } }
    var itemCount: Int { rows.reduce(0) { $0 + $1.items.count } }

    /// Shared description without the " · label" suffix of split rows.
    var title: String {
        let base = rows.first.map { $0.description.components(separatedBy: " · ").first ?? $0.description } ?? ""
        return base.isEmpty ? "Expense" : base
    }

    var categorySummary: String { rows.map(\.label).joined(separator: ", ") }

    /// Receipt lines with the category of the row they belong to (for re-editing).
    var receiptItems: [ReceiptItem] {
        rows.flatMap { row in
            row.items.map { ReceiptItem(name: $0.name, amount: $0.amount, category: row.token ?? .basic) }
        }
    }

    /// The app only shows transactions from this date on (the week summary still uses all data).
    static let displayCutoff = "2026-09-28"

    /// Reverse of ReceiptCategory.stored.
    static func token(category: String, subCategory: String?) -> ReceiptCategory? {
        switch (category, subCategory) {
        case ("unnecessary", "eating_out"): return .eo
        case ("unnecessary", _): return .un
        case ("budgeted", "purchases"): return .pu
        case ("budgeted", "health"): return .he
        case ("budgeted", "medical"): return .med
        case ("budgeted", "taloustarvikkeet"): return .ta
        case ("basic", _): return .basic
        case ("fun", _): return .fun
        case ("gas", _): return .gas
        case ("misc", _): return .misc
        default: return nil
        }
    }

    static func categoryLabel(_ key: String) -> String {
        let labels = ["basic": "Basic", "gas": "Gas", "fun": "Fun", "fixed": "Fixed", "unnecessary": "Unnecessary",
                      "budgeted": "Budgeted", "recurring": "Recurring", "work": "Work", "income": "Income", "misc": "Misc"]
        return labels[key] ?? key.capitalized
    }

    /// Groups expense rows into transactions, newest first.
    /// Rows sharing a `txId` form one transaction; older receipt splits without a txId are grouped
    /// when they share the same `created` timestamp, date and base description (how both apps write split rows).
    static func group(_ values: [JSONValue]) -> [Transaction] {
        var order: [String] = []
        var buckets: [String: [JSONValue]] = [:]
        for v in values {
            guard let id = v["id"]?.stringValue, let amount = WeekSummary.number(v["amount"]), amount < 0,
                  v["date"]?.stringValue != nil,
                  !WeekSummary.truthy(v["proposed"]), !WeekSummary.truthy(v["dismissed"]),
                  !WeekSummary.truthy(v["adjustment"]) else { continue }
            let key: String
            if let tx = v["txId"]?.stringValue {
                key = "tx:" + tx
            } else if let created = v["created"]?.stringValue, let date = v["date"]?.stringValue {
                // Bulk add stamps a whole batch in the same millisecond, so also require the same base description.
                let desc = v["description"]?.stringValue ?? ""
                key = "c:\(created)|\(date)|\(desc.components(separatedBy: " · ").first ?? desc)"
            } else {
                key = "id:" + id
            }
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(v)
        }
        let txs: [Transaction] = order.compactMap { key in
            guard let vs = buckets[key], let first = vs.first else { return nil }
            let rows = vs.map { v in
                Row(id: v["id"]?.stringValue ?? "",
                    amount: abs(WeekSummary.number(v["amount"]) ?? 0),
                    category: v["category"]?.stringValue ?? "",
                    subCategory: v["subCategory"]?.stringValue,
                    description: v["description"]?.stringValue ?? "",
                    items: WeekSummary.array(v["items"]).compactMap { i in
                        guard let a = WeekSummary.number(i["amount"]) else { return nil }
                        return Item(name: i["name"]?.stringValue ?? "", amount: a)
                    })
            }
            let id = first["txId"]?.stringValue ?? rows[0].id
            return Transaction(id: id, date: first["date"]?.stringValue ?? "",
                               created: first["created"]?.stringValue ?? "",
                               account: first["account"]?.stringValue,
                               time: first["time"]?.stringValue, rows: rows,
                               pending: vs.contains { WeekSummary.truthy($0["pending"]) })
        }
        return txs.sorted { $0.date != $1.date ? $0.date > $1.date : $0.created > $1.created }
    }
}
