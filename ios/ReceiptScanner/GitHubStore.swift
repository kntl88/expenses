import Foundation

/// Reads/writes data/expenses.json in the private data repo via the GitHub Contents API,
/// the same way index.html does (loadData / saveData / mergeRemote).
struct GitHubStore {
    let owner: String
    let repo: String
    let token: String

    static let dataPath = "data/expenses.json"

    struct StoreError: LocalizedError {
        let message: String
        var notFound = false
        var errorDescription: String? { message }
    }

    struct Snapshot {
        var expenses: [JSONValue]
        var sha: String
    }

    static let accountsPath = "data/accounts.json"

    private var fileURL: URL { url(Self.dataPath) }

    private func url(_ path: String) -> URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(repo)/contents/\(path)")!
    }

    private func request(_ url: URL, accept: String = "application/vnd.github.v3+json") -> URLRequest {
        var r = URLRequest(url: url)
        r.cachePolicy = .reloadIgnoringLocalCacheData
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue(accept, forHTTPHeaderField: "Accept")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return r
    }

    func load() async throws -> Snapshot {
        let (value, sha) = try await loadFile(Self.dataPath)
        guard case let .array(items) = value else { throw StoreError(message: "expenses.json is not an array.") }
        return Snapshot(expenses: items, sha: sha)
    }

    /// data/accounts.json (recurring templates, envelopes, loans, …); empty object if missing.
    func loadAccounts() async throws -> JSONValue {
        do { return try await loadFile(Self.accountsPath).value } catch let e as StoreError where e.notFound { return .object([]) }
    }

    private func loadFile(_ path: String) async throws -> (value: JSONValue, sha: String) {
        let (data, resp) = try await URLSession.shared.data(for: request(url(path)))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            if code == 401 { throw StoreError(message: "GitHub token rejected (401). Re-unlock in Settings.") }
            throw StoreError(message: "Loading \(path) failed: HTTP \(code)", notFound: code == 404)
        }
        guard let meta = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sha = meta["sha"] as? String
        else { throw StoreError(message: "Unexpected GitHub response.") }

        var fileBytes: Data
        if let b64 = meta["content"] as? String, !b64.isEmpty,
           let d = Data(base64Encoded: b64.replacingOccurrences(of: "\n", with: "")) {
            fileBytes = d
        } else {
            // Files over 1 MB come back without inline content; fetch raw.
            let (raw, rresp) = try await URLSession.shared.data(for: request(url(path), accept: "application/vnd.github.raw+json"))
            guard (rresp as? HTTPURLResponse)?.statusCode == 200 else { throw StoreError(message: "Loading raw \(path) failed.") }
            fileBytes = raw
        }
        return (try JSONValue.parse(fileBytes), sha)
    }

    /// PUTs the whole array. Returns false on a sha conflict (409/422) so the caller can re-fetch and retry.
    private func put(_ expenses: [JSONValue], sha: String, message: String) async throws -> Bool {
        let text = JSONValue.array(expenses).pretty()
        let body: [String: Any] = ["message": message, "content": Data(text.utf8).base64EncodedString(), "sha": sha]
        var r = request(fileURL)
        r.httpMethod = "PUT"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 200 || code == 201 { return true }
        if code == 409 || code == 422 { return false }
        let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
        throw StoreError(message: "Saving failed: \(msg ?? "HTTP \(code)")")
    }

    /// Applies `change` to the latest expense list and saves it. On a sha conflict it re-fetches and
    /// re-applies, so concurrent web edits aren't lost.
    func mutate(message: String, _ change: ([JSONValue]) -> [JSONValue]) async throws {
        for _ in 0..<3 {
            let snap = try await load()
            var list = change(snap.expenses)
            // Stable sort by date descending, same as the web app.
            list = list.enumerated().sorted { a, b in
                let da = a.element["date"]?.stringValue ?? "", db = b.element["date"]?.stringValue ?? ""
                return da != db ? da > db : a.offset < b.offset
            }.map(\.element)
            if try await put(list, sha: snap.sha, message: message) { return }
        }
        throw StoreError(message: "Saving failed: the file kept changing on GitHub. Try again.")
    }

    /// Appends `newEntries`, removing the rows in `replacingIds` (e.g. the pending card payment a receipt replaces).
    func commit(newEntries: [JSONValue], replacingIds: Set<String> = [], message: String) async throws {
        let newIds = Set(newEntries.compactMap { $0["id"]?.stringValue })
        try await mutate(message: message) { list in
            list.filter { item in
                guard let id = item["id"]?.stringValue else { return true }
                return !replacingIds.contains(id) && !newIds.contains(id)
            } + newEntries
        }
    }
}
