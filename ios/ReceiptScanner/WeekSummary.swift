import Foundation

/// Port of the web app's "Consumption" grid (renderDailyRates in index.html) for the current week,
/// including getBudgetBreakdown, loan / temp-recurring deductions and spread income, so the numbers
/// match the web app exactly.
struct WeekSummary {
    struct Expense {
        let date: String
        let amount: Double
        let category: String
        let subCategory: String?
        let spreadDays: Int
        let oneTime: Bool
        let refund: Bool
        let proposed: Bool
        let dismissed: Bool
        let adjustment: Bool
        let recurringId: String?

        init?(_ v: JSONValue) {
            guard let date = v["date"]?.stringValue, let amount = WeekSummary.number(v["amount"]) else { return nil }
            self.date = date
            self.amount = amount
            category = v["category"]?.stringValue ?? ""
            subCategory = v["subCategory"]?.stringValue
            spreadDays = Int(WeekSummary.number(v["spreadDays"]) ?? 1)
            oneTime = WeekSummary.truthy(v["oneTime"])
            refund = WeekSummary.truthy(v["refund"])
            proposed = WeekSummary.truthy(v["proposed"])
            dismissed = WeekSummary.truthy(v["dismissed"])
            adjustment = WeekSummary.truthy(v["adjustment"])
            recurringId = v["recurringId"]?.stringValue
        }
    }

    struct Combo {
        let label: String
        var cats: [String]? = nil
        var subCat: String? = nil
        var allCats = false
        var excludeSubCat: String? = nil
    }

    /// DAILY_COMBOS
    static let combos: [Combo] = [
        Combo(label: "Basic", cats: ["basic"]),
        Combo(label: "Fun", cats: ["fun"]),
        Combo(label: "Unnec", cats: ["unnecessary"]),
        Combo(label: "Total", cats: ["basic", "fun", "unnecessary"]),
        Combo(label: "Purchases", cats: ["purchase"], subCat: "purchases"),
        Combo(label: "Gas", cats: ["gas"]),
        Combo(label: "Everything", allCats: true),
        Combo(label: "All-Purch", allCats: true, excludeSubCat: "purchases"),
    ]

    struct Cell { let label: String; let total: Double; let daily: Double }
    struct Saving { let total: Double; let dailyBudget: Double; let today: Double; let dailyNet: Double }
    struct Forecast { let max: Double; let projected: Double; let monthly: Double }
    struct Row {
        let leading: [(combo: Int, cell: Cell)]   // row 1: Basic/Fun/Unnec; rows 2–3: one cell spanning 3
        let cumulative: Cell
        let saving: Saving
        let forecast: Forecast
    }

    let weekNumber: Int
    let mondayLabel: String
    let rows: [Row]
    /// For the per-day bar chart (web shows it when combo cells are selected).
    let periodItems: [Expense]
    let periodStart: String
    let periodEnd: String

    // MARK: Compute

    static func compute(expenses raw: [JSONValue], accounts: JSONValue, now: Date = Date()) -> WeekSummary {
        let all = raw.compactMap(Expense.init)
        let todayStr = Day.str(now)
        let weekday = Calendar(identifier: .gregorian).component(.weekday, from: now) // 1 = Sunday
        let diff = (weekday - 1 + 6) % 7
        let monday = Day.add(todayStr, -diff)
        let sunday = Day.add(monday, 6)

        let allExpenses = all.filter { !$0.proposed && !$0.dismissed && ($0.amount < 0 || $0.refund) && !$0.adjustment }
        let periodStart = monday
        let periodEnd = sunday <= todayStr ? sunday : todayStr
        let periodItems = allExpenses.filter { overlaps($0, periodStart, periodEnd) }
        let periodDays = Day.between(periodStart, periodEnd) + 1

        let comboTotals = combos.map { comboSpread($0, periodItems, periodStart, periodEnd) }
        func cell(_ i: Int) -> Cell {
            Cell(label: combos[i].label, total: comboTotals[i], daily: periodDays > 0 ? comboTotals[i] / Double(periodDays) : 0)
        }
        func cum(_ label: String, _ total: Double) -> Cell {
            Cell(label: label, total: total, daily: periodDays > 0 ? total / Double(periodDays) : 0)
        }

        let weeklyBudget = budgetBreakdown(all, accounts: accounts)
        let baseDailyRate = weeklyBudget / 7
        let periodLoans: Double = loanDeduction(accounts, periodStart, periodEnd)
        let periodTR: Double = tempRecurringDeduction(accounts, periodStart, periodEnd)
        let periodSI: Double = spreadIncome(accounts, periodStart, periodEnd)
        let periodBudgetPool: Double = Double(periodDays) * baseDailyRate - periodLoans - periodTR + periodSI

        let weekItems = allExpenses.filter { overlaps($0, monday, sunday) && $0.category != "budgeted" && $0.category != "misc" }
        let weekCombo = combos.map { comboSpread($0, weekItems, monday, todayStr) }
        let weekComboOneTime = combos.map { comboSpread($0, weekItems.filter(\.oneTime), monday, todayStr) }
        let todayCombo = combos.map { comboSpread($0, weekItems, todayStr, todayStr) }
        let daysElapsed = diff + 1

        let weekLoans: Double = loanDeduction(accounts, monday, sunday)
        let weekTR: Double = tempRecurringDeduction(accounts, monday, sunday)
        let weekSI: Double = spreadIncome(accounts, monday, sunday)
        let weekBudgetPool: Double = weeklyBudget - weekLoans - weekTR + weekSI
        let periodDailyBudget = periodDays > 0 ? periodBudgetPool / Double(periodDays) : baseDailyRate
        func saving(_ periodSpent: Double, _ todaySpent: Double) -> Saving {
            Saving(total: periodBudgetPool - periodSpent, dailyBudget: periodDailyBudget,
                   today: todaySpent, dailyNet: periodDailyBudget - todaySpent)
        }
        let daysRemaining = 7 - daysElapsed
        let weekDailyBudget = weekBudgetPool / 7
        func forecast(_ weekSpent: Double, _ weekOneTime: Double) -> Forecast {
            let max = Double(daysRemaining) * weekDailyBudget
            let regular = weekSpent - weekOneTime
            let proj = daysElapsed > 0 ? weekBudgetPool - (regular / Double(daysElapsed)) * 7 - weekOneTime : weekBudgetPool - weekOneTime
            return Forecast(max: max, projected: proj, monthly: proj * 4.35)
        }

        let cum1 = comboTotals[3], wk1 = weekCombo[3], td1 = todayCombo[3], ot1 = weekComboOneTime[3]
        let cum2 = cum1 + comboTotals[5], wk2 = wk1 + weekCombo[5], td2 = td1 + todayCombo[5], ot2 = ot1 + weekComboOneTime[5]
        let cum3 = cum2 + comboTotals[4], wk3 = wk2 + weekCombo[4], td3 = td2 + todayCombo[4], ot3 = ot2 + weekComboOneTime[4]
        let rows = [
            Row(leading: [0, 1, 2].map { ($0, cell($0)) }, cumulative: cum("Total", cum1),
                saving: saving(cum1, td1), forecast: forecast(wk1, ot1)),
            Row(leading: [(5, cell(5))], cumulative: cum("+Gas", cum2),
                saving: saving(cum2, td2), forecast: forecast(wk2, ot2)),
            Row(leading: [(4, cell(4))], cumulative: cum("+Purch", cum3),
                saving: saving(cum3, td3), forecast: forecast(wk3, ot3)),
        ]

        let mondayDate = Format.day.date(from: monday) ?? now
        let comps = Calendar(identifier: .gregorian).dateComponents([.day, .month], from: mondayDate)
        return WeekSummary(weekNumber: Calendar(identifier: .iso8601).component(.weekOfYear, from: mondayDate),
                           mondayLabel: "\(comps.day ?? 0)/\(comps.month ?? 0)",
                           rows: rows, periodItems: periodItems, periodStart: periodStart, periodEnd: periodEnd)
    }

    /// Daily totals Mon…today for the selected combo cells (the web app's rate-chart for one week).
    func dailyBars(selected: Set<Int>) -> [(label: String, total: Double)] {
        var cats = Set<String>(), subCats = Set<String>()
        for i in selected {
            Self.combos[i].cats?.forEach { cats.insert($0) }
            if let s = Self.combos[i].subCat { subCats.insert(s) }
        }
        let filtered = periodItems.filter { cats.contains($0.category) || ($0.subCategory.map(subCats.contains) ?? false) }
        let names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        var bars: [(String, Double)] = []
        for d in 0..<7 {
            let ds = Day.add(periodStart, d)
            if ds > periodEnd { break }
            bars.append((names[d], filtered.reduce(0) { $0 + Self.spreadAmount($1, ds, ds) }))
        }
        return bars
    }

    // MARK: Web helpers

    static func overlaps(_ e: Expense, _ rs: String, _ re: String) -> Bool {
        let sd = e.spreadDays > 1 ? e.spreadDays : 1
        let end = sd > 1 ? Day.add(e.date, sd - 1) : e.date
        return e.date <= re && end >= rs
    }

    static func spreadAmount(_ e: Expense, _ rs: String, _ re: String) -> Double {
        let sd = e.spreadDays > 1 ? e.spreadDays : 1
        let end = sd > 1 ? Day.add(e.date, sd - 1) : e.date
        let os = e.date > rs ? e.date : rs
        let oe = end < re ? end : re
        if os > oe { return 0 }
        return abs(e.amount) * Double(Day.between(os, oe) + 1) / Double(sd)
    }

    static func comboMatch(_ c: Combo, _ e: Expense) -> Bool {
        if e.subCategory == "eating_out", let cats = c.cats, cats.contains("basic") || cats.contains("unnecessary") { return true }
        let match = c.allCats || (c.cats?.contains(e.category) ?? false) || (c.subCat != nil && e.subCategory == c.subCat)
        return match && !(c.excludeSubCat != nil && e.subCategory == c.excludeSubCat)
    }

    /// Eating out: the first 5 € counts as basic, the rest as unnecessary.
    static func eatingOutRatio(_ c: Combo, _ e: Expense) -> Double {
        guard e.subCategory == "eating_out", let cats = c.cats else { return 1 }
        let total = abs(e.amount)
        if total == 0 { return 0 }
        if cats.contains("basic") && !cats.contains("unnecessary") { return min(5, total) / total }
        if cats.contains("unnecessary") && !cats.contains("basic") { return max(0, total - 5) / total }
        return 1
    }

    static func comboSpread(_ c: Combo, _ items: [Expense], _ rs: String, _ re: String) -> Double {
        items.filter { comboMatch(c, $0) }.reduce(0) { $0 + spreadAmount($1, rs, re) * eatingOutRatio(c, $1) }
    }

    /// getBudgetBreakdown().weekly
    static func budgetBreakdown(_ all: [Expense], accounts: JSONValue) -> Double {
        let confirmed = all.filter { !$0.proposed && !$0.dismissed && !$0.adjustment }
        let income = confirmed.filter { $0.amount > 0 && $0.category != "work" }
        let months = max(1, Set(income.map { String($0.date.prefix(7)) }).count)
        let incomeMo = income.reduce(0) { $0 + $1.amount } / Double(months)
        var recurringMo = 0.0
        for t in array(accounts["recurring"]) where t["type"]?.stringValue != "income" {
            let id = t["id"]?.stringValue
            let tAmount = number(t["amount"]) ?? 0
            let matches = all.filter { $0.recurringId != nil && $0.recurringId == id && !$0.proposed && !$0.dismissed }
            let avg = matches.isEmpty ? tAmount : matches.reduce(0) { $0 + abs($1.amount) } / Double(matches.count)
            let interval = number(t["intervalMonths"]).flatMap { $0 == 0 ? nil : $0 } ?? 1
            recurringMo += avg / interval
        }
        let budgetedMo = array(accounts["budgeted"]).reduce(0) { $0 + (number($1["monthlyAlloc"]) ?? 0) }
        return (incomeMo - recurringMo - budgetedMo) / 4.333
    }

    static func loanDeduction(_ accounts: JSONValue, _ ps: String, _ pe: String) -> Double {
        array(accounts["loans"]).reduce(0) { total, l in
            guard let start = l["startDate"]?.stringValue, let days = number(l["days"]), days != 0,
                  let amount = number(l["amount"]) else { return total }
            let end = Day.add(start, Int(days))
            let os = start > ps ? start : ps, oe = end < pe ? end : pe
            guard os <= oe else { return total }
            return total + (amount / days) * Double(Day.between(os, oe) + 1)
        }
    }

    static func tempRecurringDeduction(_ accounts: JSONValue, _ rs: String, _ re: String) -> Double {
        array(accounts["tempRecurring"]).reduce(0) { total, t in
            guard let start = t["startDate"]?.stringValue, let months = number(t["months"]),
                  let amount = number(t["amount"]) else { return total }
            let end = Day.addMonths(start, Int(months))
            let os = start > rs ? start : rs, oe = end < re ? end : re
            guard os < oe else { return total }
            return total + (amount / 30.5) * Double(Day.between(os, oe))
        }
    }

    static func spreadIncome(_ accounts: JSONValue, _ ps: String, _ pe: String) -> Double {
        array(accounts["spreadIncome"]).reduce(0) { total, si in
            guard let start = si["startDate"]?.stringValue, let amount = number(si["amount"]) else { return total }
            let td = number(si["days"]).flatMap { $0 == 0 ? nil : $0 } ?? (number(si["months"]) ?? 0) * 30.5
            guard td != 0 else { return total }
            let end = Day.add(start, Int(td)) // JS setDate truncates fractional days
            let os = start > ps ? start : ps, oe = end < pe ? end : pe
            guard os <= oe else { return total }
            return total + (amount / td) * Double(Day.between(os, oe) + 1)
        }
    }

    // MARK: Value helpers

    static func number(_ v: JSONValue?) -> Double? {
        switch v {
        case let .number(d, _): return d
        case let .string(s): return Double(s)
        default: return nil
        }
    }

    static func truthy(_ v: JSONValue?) -> Bool {
        switch v {
        case let .bool(b): return b
        case let .number(d, _): return d != 0
        case let .string(s): return !s.isEmpty
        case .array, .object: return true
        default: return false
        }
    }

    static func array(_ v: JSONValue?) -> [JSONValue] {
        if case let .array(a) = v { return a }
        return []
    }
}

/// Local-date string math matching the web app's YYYY-MM-DD helpers.
enum Day {
    private static let cal = Calendar(identifier: .gregorian)

    static func str(_ d: Date) -> String { Format.day.string(from: d) }

    static func add(_ s: String, _ n: Int) -> String {
        guard let d = Format.day.date(from: s), let r = cal.date(byAdding: .day, value: n, to: d) else { return s }
        return str(r)
    }

    /// Like JS setMonth: day overflow rolls into the next month (Jan 31 + 1 → Mar 3).
    static func addMonths(_ s: String, _ n: Int) -> String {
        let p = s.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, let r = cal.date(from: DateComponents(year: p[0], month: p[1] + n, day: p[2])) else { return s }
        return str(r)
    }

    static func between(_ a: String, _ b: String) -> Int {
        guard let da = Format.day.date(from: a), let db = Format.day.date(from: b) else { return 0 }
        return Int((db.timeIntervalSince(da) / 86400).rounded())
    }
}
