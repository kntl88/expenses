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
            transactions = Transaction.group(DemoData.expenses()).filter { $0.date >= Transaction.displayCutoff }
            return
        }
        guard let store else { return }
        do {
            async let expenses = store.load().expenses
            async let accounts = store.loadAccounts()
            let (ex, ac) = try await (expenses, accounts)
            let newTransactions = Transaction.group(ex).filter { $0.date >= Transaction.displayCutoff }
            let newWeek = WeekSummary.compute(expenses: ex, accounts: ac)
            WidgetData.save(expenses: ex, accounts: ac)
            switch update {
            case .keep:
                transactions = newTransactions
                return
            case .now:
                transactions = newTransactions
                withAnimation(.easeInOut(duration: 0.6)) { week = newWeek }
            case let .after(delay):
                // Old list and numbers stay on screen; numbers change first, then any pending payment
                // that was just settled pops and flies off before the list updates.
                try? await Task.sleep(until: start + delay)
                withAnimation(.easeInOut(duration: 0.6)) { week = newWeek }
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
