import Foundation
import Observation
import SwiftUI

@Observable
final class AppState {
    var githubToken: String? = Keychain.get("githubToken")
    var repo: String? = UserDefaults.standard.string(forKey: "repo")
    var anthropicKey: String? = Keychain.get("anthropicKey")
    var defaultAccount: Account = Account(rawValue: UserDefaults.standard.string(forKey: "defaultAccount") ?? "") ?? .norwegian {
        didSet { UserDefaults.standard.set(defaultAccount.rawValue, forKey: "defaultAccount") }
    }

    var isConfigured: Bool { AppState.demo || (store != nil && !(anthropicKey ?? "").isEmpty) }

    /// Debug-only: launch with `-demo` to show sample data without credentials (for layout checks).
    #if DEBUG
    static let demo = ProcessInfo.processInfo.arguments.contains("-demo")
    #else
    static let demo = false
    #endif

    var store: GitHubStore? {
        guard let t = githubToken, !t.isEmpty, let r = repo, !r.isEmpty else { return nil }
        return GitHubStore(owner: Vault.owner, repo: r, token: t)
    }

    var claude: ClaudeClient? {
        guard let k = anthropicKey, !k.isEmpty else { return nil }
        return ClaudeClient(apiKey: k)
    }

    func saveGitHub(token: String, repo: String) {
        githubToken = token
        self.repo = repo
        Keychain.set("githubToken", token)
        UserDefaults.standard.set(repo, forKey: "repo")
    }

    func saveAnthropicKey(_ key: String?) {
        let k = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        anthropicKey = k
        Keychain.set("anthropicKey", k)
    }

    func signOut() {
        saveGitHub(token: "", repo: "")
        githubToken = nil
        repo = nil
    }

    /// Card taps from the Transaction automation, waiting for their Wallet details.
    var cardTaps = CardTaps.load()

    func clearTaps(_ ids: Set<UUID>) {
        CardTaps.remove(ids)
        cardTaps = CardTaps.load()
    }

    /// Called when the app becomes active (picks up edits made in the web app and new card taps).
    func refresh() async {
        cardTaps = CardTaps.load()
        await loadData()
    }

    // MARK: Data (week summary + transactions)

    var week: WeekSummary?
    /// Bank and card balances. Detached from the web app: each account has its own phone-only offset
    /// (`AppBalances`), so changing an offset in the web app doesn't move them; the rows still do.
    var balances: [Balance] = []
    /// The rows of the last load, for balance checks.
    private var expenses: [JSONValue] = []

    struct Balance: Identifiable {
        let key: String
        let label: String
        /// Every confirmed row on the account up to today.
        let rowSum: Double
        let webOffset: Double
        let appOffset: Double
        /// The latest balance read from a bank app screenshot, and the rows up to that day.
        let check: AppBalances.Check?
        let rowSumAtCheck: Double?
        var id: String { key }
        var value: Double { appOffset + rowSum }
        /// What the web app's Accounts card shows.
        var webValue: Double { webOffset + rowSum }
        var differsFromWeb: Bool { abs(appOffset - webOffset) >= 0.005 }
        /// Screenshot balance minus the app's balance on that day, when they don't match.
        var discrepancy: Double? {
            guard let check, let rowSumAtCheck else { return nil }
            let d = Format.round2(check.reported - (appOffset + rowSumAtCheck))
            return abs(d) >= 0.005 ? d : nil
        }
    }

    private static let balanceAccounts = [("bank", "Bank"), ("norwegian", "Norwegian"), ("work", "Work")]

    private static func balances(expenses: [JSONValue], accounts: JSONValue) -> [Balance] {
        balanceAccounts.map { key, label in
            let web = WeekSummary.webOffset(key, accounts: accounts)
            let check = AppBalances.check(key)
            return Balance(key: key, label: label, rowSum: WeekSummary.rowSum(key, expenses: expenses), webOffset: web,
                           appOffset: AppBalances.offset(key, webOffset: web), check: check,
                           rowSumAtCheck: check.map { WeekSummary.rowSum(key, expenses: expenses, through: $0.day) })
        }
    }

    private func updateBalance(_ key: String) {
        balances = balances.map { b in
            b.key != key ? b : Balance(key: key, label: b.label, rowSum: b.rowSum, webOffset: b.webOffset,
                                       appOffset: AppBalances.offset(key, webOffset: b.webOffset),
                                       check: b.check, rowSumAtCheck: b.rowSumAtCheck)
        }
    }

    /// Phone-only: makes `key` show `actual` now (later payments still move it). nil goes back to the
    /// web app's offset.
    func setBalance(_ key: String, actual: Double?) {
        guard let b = balances.first(where: { $0.key == key }) else { return }
        AppBalances.setOffset(key, actual.map { Format.round2($0 - b.rowSum) } ?? b.webOffset)
        updateBalance(key)
    }

    /// Makes `key` match the balance last read from a screenshot.
    func acceptCheckedBalance(_ key: String) {
        guard let b = balances.first(where: { $0.key == key }), let c = b.check, let atCheck = b.rowSumAtCheck else { return }
        AppBalances.setOffset(key, Format.round2(c.reported - atCheck))
        updateBalance(key)
    }

    /// Records the balance a bank app screenshot showed today (compared on Home after the next load).
    func recordBalanceCheck(_ key: String, reported: Double) {
        let check = AppBalances.Check(reported: Format.round2(reported), day: Format.day.string(from: Date()))
        AppBalances.setCheck(key, check)
        // Checked today, so the rows up to that day are today's rows (the next load recomputes it).
        balances = balances.map { b in
            b.key != key ? b : Balance(key: key, label: b.label, rowSum: b.rowSum, webOffset: b.webOffset,
                                       appOffset: b.appOffset, check: check, rowSumAtCheck: b.rowSum)
        }
    }

    /// The balance a bank app's month totals imply for `key` today: the app's balance at the end of
    /// last month (assumed checked) plus the month's payments minus its purchases. nil unless `month`
    /// (YYYY-MM) is the current month.
    func balanceFromMonth(_ key: String, month: String, spent: Double, paid: Double) -> Double? {
        let today = Format.day.string(from: Date())
        guard today.hasPrefix(month + "-"), let b = balances.first(where: { $0.key == key }) else { return nil }
        // "YYYY-MM-00" sorts before the month's first day and after every day of the month before.
        let atMonthStart = WeekSummary.rowSum(key, expenses: expenses, through: month + "-00")
        return Format.round2(b.appOffset + atMonthStart + paid - spent)
    }

    var weekError: String?
    var transactions: [Transaction] = []

    /// Card payments waiting for a receipt or allocation.
    var pending: [Transaction] { transactions.filter(\.pending) }
    var recent: [Transaction] { Array(transactions.filter { !$0.pending }.prefix(30)) }

    /// Pending payments being animated away after a receipt or allocation settled them.
    enum Vanish { case pop, fly }
    var vanishing: [String: Vanish] = [:]

    /// How a reload treats the Consumption card.x<
    enum WeekUpdate {
        case now
        /// Keep the old numbers on screen at least this long (from the call), then animate to the new ones.
        case after(Duration)
        /// Leave it as is (e.g. between receipts of one photo; the last save reveals the change).
        case keep
    }

    func loadData(week update: WeekUpdate = .now) async {
        let start = ContinuousClock.now
        if AppState.demo {
            week = DemoData.week()
            balances = [Balance(key: "bank", label: "Bank", rowSum: 1843.27, webOffset: 0, appOffset: 0, check: nil, rowSumAtCheck: nil),
                        Balance(key: "norwegian", label: "Norwegian", rowSum: -412.60, webOffset: 0, appOffset: 0,
                                check: .init(reported: -398.10, day: Format.day.string(from: Date())), rowSumAtCheck: -412.60),
                        Balance(key: "work", label: "Work", rowSum: -86.20, webOffset: 0, appOffset: 0, check: nil, rowSumAtCheck: nil)]
            transactions = Transaction.group(DemoData.expenses()).filter { $0.date >= Transaction.displayCutoff }
            return
        }
        guard let store else { return }
        do {
            async let expenses = store.load().expenses
            async let accounts = store.loadAccounts()
            let (ex, ac) = try await (expenses, accounts)
            self.expenses = ex
            let newTransactions = Transaction.group(ex).filter { $0.date >= Transaction.displayCutoff }
            let newWeek = WeekSummary.compute(expenses: ex, accounts: ac)
            let newBalances = Self.balances(expenses: ex, accounts: ac)
            WidgetData.save(expenses: ex, accounts: ac)
            switch update {
            case .keep:
                transactions = newTransactions
                return
            case .now:
                transactions = newTransactions
                withAnimation(.easeInOut(duration: 0.6)) { week = newWeek; balances = newBalances }
            case let .after(delay):
                // Old list and numbers stay on screen; numbers change first, then any pending payment
                // that was just settled pops and flies off before the list updates.
                try? await Task.sleep(until: start + delay)
                withAnimation(.easeInOut(duration: 0.6)) { week = newWeek; balances = newBalances }
                await show(newTransactions, settlingAfter: .seconds(1.2))
            }
            weekError = nil
        } catch {
            if week == nil { weekError = error.localizedDescription }
        }
    }

    /// Swaps in `new`; pending payments it no longer has first pop and fly off (after `pause`).
    private func show(_ new: [Transaction], settlingAfter pause: Duration) async {
        let stillPending = Set(new.filter(\.pending).map(\.id))
        let settled = pending.map(\.id).filter { !stillPending.contains($0) }
        if !settled.isEmpty {
            try? await Task.sleep(for: pause)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.4)) {
                for id in settled { vanishing[id] = .pop }
            }
            try? await Task.sleep(for: .seconds(0.7))
            withAnimation(.easeIn(duration: 0.35)) {
                for id in settled { vanishing[id] = .fly }
            }
            try? await Task.sleep(for: .seconds(0.35))
        }
        withAnimation(.snappy) { transactions = new }
        vanishing = [:]
    }

    #if DEBUG
    /// `-demo -settle`: plays the settle animation on the first pending payment (layout check).
    func demoSettle() async {
        guard let first = pending.first else { return }
        await show(transactions.filter { $0.id != first.id }, settlingAfter: .seconds(1.5))
    }
    #endif

    /// Accepts a pending payment's guessed category as final.
    func confirm(_ tx: Transaction) async throws {
        guard let store else { return }
        let ids = tx.rowIds
        try await store.mutate(message: "Confirm \(tx.title) \(tx.date) (iOS)") { list in
            list.map { v in ids.contains(v["id"]?.stringValue ?? "") ? v.removing("pending") : v }
        }
        await loadData()
    }

    func delete(_ tx: Transaction) async throws {
        guard let store else { return }
        let ids = tx.rowIds
        try await store.mutate(message: "Delete \(tx.title) \(tx.date) (iOS)") { list in
            list.filter { !ids.contains($0["id"]?.stringValue ?? "") }
        }
        await loadData()
    }
}

/// The app's own balance offsets and screenshot balance checks, kept on the phone only.
enum AppBalances {
    private static let offsetsKey = "appBalanceOffsets"
    private static let checksKey = "balanceChecks"

    struct Check: Codable {
        /// Balance the bank app showed (negative = owed).
        let reported: Double
        /// YYYY-MM-DD the screenshot was read.
        let day: String
    }

    private static var offsets: [String: Double] {
        (UserDefaults.standard.dictionary(forKey: offsetsKey) as? [String: Double]) ?? [:]
    }

    /// The account's offset. The first time, it's taken over from the web app's offset plus the old
    /// manual correction, so the balance shown stays the same.
    static func offset(_ account: String, webOffset: Double) -> Double {
        applyCorrections()
        if let o = offsets[account] { return o }
        let o = Format.round2(webOffset + (LegacyOverrides.offset(account) ?? 0))
        if !AppState.demo { setOffset(account, o) }
        return o
    }

    /// One-time shifts of the phone's offsets, each applied once.
    /// 2026-10-09: with all of October imported Norwegian showed -496.54; the bank says -603.89.
    private static let corrections: [(key: String, account: String, delta: Double)] = [
        ("balanceCorrection-2026-10-09-norwegian", "norwegian", -107.35),
    ]

    private static func applyCorrections() {
        guard !AppState.demo else { return }
        let d = UserDefaults.standard
        for c in corrections where !d.bool(forKey: c.key) {
            // Only shifts an offset the phone already has; a fresh install starts from the web app's.
            if let o = offsets[c.account] { setOffset(c.account, Format.round2(o + c.delta)) }
            d.set(true, forKey: c.key)
        }
    }

    static func setOffset(_ account: String, _ offset: Double) {
        var updated = offsets
        updated[account] = offset
        UserDefaults.standard.set(updated, forKey: offsetsKey)
    }

    static func check(_ account: String) -> Check? {
        guard let data = UserDefaults.standard.data(forKey: checksKey),
              let all = try? JSONDecoder().decode([String: Check].self, from: data) else { return nil }
        return all[account]
    }

    static func setCheck(_ account: String, _ check: Check) {
        var all = (UserDefaults.standard.data(forKey: checksKey))
            .flatMap { try? JSONDecoder().decode([String: Check].self, from: $0) } ?? [:]
        all[account] = check
        UserDefaults.standard.set(try? JSONEncoder().encode(all), forKey: checksKey)
    }
}

/// Before the balances were detached: manual corrections added to the web app's balance. Only read
/// once, to carry them over into `AppBalances`.
private enum LegacyOverrides {
    private static let key = "balanceOverrides"

    /// Corrections measured on 2026-10-03 against the data then (calculated → actual):
    /// Bank 6613.04 → 1120, Norwegian -2743.13 → -167.13, Work -2070.03 → 0.
    private static let seed: [String: Double] = ["bank": -5493.04, "norwegian": 2576.00, "work": 2070.03]
    private static let seededKey = "balanceOverridesSeeded-2026-10-03"

    static func offset(_ account: String) -> Double? {
        let d = UserDefaults.standard
        let all = d.bool(forKey: seededKey) ? (d.dictionary(forKey: key) as? [String: Double]) ?? [:] : seed
        return all[account]
    }
}
