import Foundation

/// Sample data for `-demo` launches (DEBUG builds only), used to check layout without credentials.
enum DemoData {
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
