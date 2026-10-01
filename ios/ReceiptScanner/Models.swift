import Foundation

/// Receipt category tokens, same set as RECEIPT_CATS / mapCat in index.html.
enum ReceiptCategory: String, CaseIterable, Identifiable, Codable {
    case basic, eo, fun, gas, pu, he, med, ta, misc, un

    var id: String { rawValue }

    var label: String {
        switch self {
        case .basic: return "Basic"
        case .eo: return "Eating out"
        case .fun: return "Fun"
        case .gas: return "Gas"
        case .pu: return "Purchases"
        case .he: return "Health"
        case .med: return "Medical"
        case .ta: return "Taloustarv."
        case .misc: return "Misc"
        case .un: return "Unnecessary"
        }
    }

    var symbol: String {
        switch self {
        case .basic: return "cart"
        case .eo: return "fork.knife"
        case .fun: return "wineglass"
        case .gas: return "fuelpump"
        case .pu: return "bag"
        case .he: return "leaf"
        case .med: return "cross.case"
        case .ta: return "bubbles.and.sparkles"
        case .misc: return "square.grid.2x2"
        case .un: return "birthday.cake"
        }
    }

    /// Stored (category, subCategory) — mirrors mapCat in index.html.
    var stored: (category: String, subCategory: String?) {
        switch self {
        case .eo: return ("unnecessary", "eating_out")
        case .pu: return ("budgeted", "purchases")
        case .he: return ("budgeted", "health")
        case .med: return ("budgeted", "medical")
        case .ta: return ("budgeted", "taloustarvikkeet")
        case .un: return ("unnecessary", nil)
        case .basic, .fun, .gas, .misc: return (rawValue, nil)
        }
    }
}

enum Account: String, CaseIterable, Identifiable {
    case bank, work, gold, norwegian, nordnet
    var id: String { rawValue }
    var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

struct ReceiptItem: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var amount: Double
    var category: ReceiptCategory
    /// Category came from a learned rule rather than Claude.
    var learned = false
}

struct ReceiptScan {
    var merchant: String?
    var date: String?
    /// Purchase time printed on the receipt, HH:MM.
    var time: String? = nil
    var total: Double
    var items: [ReceiptItem]
}

/// Builds an expense row in the same key order/shape as saveExpense / applyReceiptSplit in index.html.
enum ExpenseEntry {
    /// Extra fields (ignored by the web app's calculations, preserved by its edits):
    /// `txId` groups the rows of one receipt, `items` holds that row's receipt lines,
    /// `pending` marks a card payment still waiting for a receipt or allocation,
    /// `time` (HH:MM) is when it was paid, used to pair receipts with card payments.
    static func make(amount: Double, date: String, description: String, category: ReceiptCategory,
                     account: Account, created: String = Format.isoMillis.string(from: Date()),
                     time: String? = nil, txId: String? = nil, items: [ReceiptItem] = [], pending: Bool = false) -> JSONValue {
        let m = category.stored
        var fields: [(String, JSONValue)] = [
            ("id", .string(Format.newExpenseId())),
            ("amount", .num(-abs(Format.round2(amount)))),
            ("date", .string(date)),
            ("description", .string(description)),
            ("category", .string(m.category)),
            ("type", .string("expense")),
        ]
        if let sub = m.subCategory { fields.append(("subCategory", .string(sub))) }
        fields.append(("account", .string(account.rawValue)))
        fields.append(("created", .string(created)))
        if let time { fields.append(("time", .string(time))) }
        if let txId { fields.append(("txId", .string(txId))) }
        if !items.isEmpty {
            fields.append(("items", .array(items.map { .object([("name", .string($0.name)), ("amount", .num(Format.round2($0.amount)))]) })))
        }
        if pending { fields.append(("pending", .bool(true))) }
        return .object(fields)
    }
}

enum Format {
    static let day: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let isoMillis: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// "21:56" → minutes since midnight.
    static func minutes(_ hhmm: String?) -> Int? {
        guard let parts = hhmm?.split(separator: ":"), parts.count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]), (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }

    static func hhmm(_ d: Date) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    static func euro(_ v: Double) -> String { String(format: "%.2f €", v) }

    static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }

    /// Same shape as the web app: Date.now().toString(36) + 4 random base36 chars.
    static func newExpenseId() -> String {
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        let chars = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        let rand = String((0..<4).map { _ in chars.randomElement()! })
        return String(ms, radix: 36) + rand
    }
}
