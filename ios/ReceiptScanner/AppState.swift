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
    var recent: [RecentSave] = AppState.loadRecent()

    var isConfigured: Bool { store != nil && !(anthropicKey ?? "").isEmpty }

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

    // MARK: Recent saves (local log only)

    struct RecentSave: Codable, Identifiable {
        var id = UUID()
        var date: String
        var description: String
        var total: Double
        var categories: [String]
        var savedAt: Date
    }

    func addRecent(_ r: RecentSave) {
        recent.insert(r, at: 0)
        recent = Array(recent.prefix(30))
        if let d = try? JSONEncoder().encode(recent) { UserDefaults.standard.set(d, forKey: "recent") }
    }

    private static func loadRecent() -> [RecentSave] {
        guard let d = UserDefaults.standard.data(forKey: "recent") else { return [] }
        return (try? JSONDecoder().decode([RecentSave].self, from: d)) ?? []
    }
}
