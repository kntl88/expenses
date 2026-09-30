import Foundation

/// Sample data for `-demo` launches (DEBUG builds only), used to check layout without credentials.
enum DemoData {
    static func expenses() -> [JSONValue] {
        let today = Day.str(Date())
        return [
            ExpenseEntry.make(amount: 12.40, date: today, description: "K-Market Herttoniemi", category: .basic,
                              account: .norwegian, pending: true),
            ExpenseEntry.make(amount: 48.90, date: Day.add(today, -1), description: "Neste Itäkeskus", category: .gas,
                              account: .norwegian, pending: true),
            ExpenseEntry.make(amount: 31.25, date: Day.add(today, -1), description: "Prisma · basic", category: .basic,
                              account: .norwegian, created: "2026-09-29T10:00:00.000Z", txId: "tx1",
                              items: [ReceiptItem(name: "Ruisleipä", amount: 2.49, category: .basic),
                                      ReceiptItem(name: "Maito 1L", amount: 1.29, category: .basic),
                                      ReceiptItem(name: "Kanafile 400g", amount: 27.47, category: .basic)]),
            ExpenseEntry.make(amount: 8.76, date: Day.add(today, -1), description: "Prisma · fun", category: .fun,
                              account: .norwegian, created: "2026-09-29T10:00:00.000Z", txId: "tx1",
                              items: [ReceiptItem(name: "KOFF III 0,33L x4", amount: 8.76, category: .fun)]),
        ]
    }

    static func week() -> WeekSummary {
        let today = Day.str(Date())
        func e(_ amount: Double, _ cat: String, _ days: Int = 0, sub: String? = nil) -> JSONValue {
            var f: [(String, JSONValue)] = [("amount", .num(amount)), ("date", .string(Day.add(today, -days))), ("category", .string(cat))]
            if let sub { f.append(("subCategory", .string(sub))) }
            return .object(f)
        }
        let expenses = [e(-23.4, "basic"), e(-12.1, "fun", 1), e(-14.5, "unnecessary", 1, sub: "eating_out"),
                        e(-55, "gas", 1), e(-89.9, "budgeted", sub: "purchases"),
                        e(3200, "income", 40), e(3300, "income", 70)]
        let accounts: JSONValue = .object([("budgeted", .array([.object([("monthlyAlloc", .num(300))])]))])
        return WeekSummary.compute(expenses: expenses, accounts: accounts)
    }
}
