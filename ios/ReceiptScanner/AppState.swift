import Foundation
import Observation

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

    var outboxCount = Outbox.count

    /// Called when the app becomes active: sync the offline queue and reload data
    /// (picks up card payments logged by the Shortcuts automation).
    func refresh() async {
        await Outbox.flush()
        outboxCount = Outbox.count
        await loadData()
    }

    // MARK: Data (week summary + transactions)

    var week: WeekSummary?
    var weekError: String?
    var transactions: [Transaction] = []

    /// Card payments waiting for a receipt or allocation.
    var pending: [Transaction] { transactions.filter(\.pending) }
    var recent: [Transaction] { Array(transactions.filter { !$0.pending }.prefix(30)) }

    func loadData() async {
        if AppState.demo {
            week = DemoData.week()
            transactions = Transaction.group(DemoData.expenses())
            return
        }
        guard let store else { return }
        do {
            async let expenses = store.load().expenses
            async let accounts = store.loadAccounts()
            let (ex, ac) = try await (expenses, accounts)
            week = WeekSummary.compute(expenses: ex, accounts: ac)
            transactions = Transaction.group(ex)
            weekError = nil
        } catch {
            if week == nil { weekError = error.localizedDescription }
        }
    }

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
