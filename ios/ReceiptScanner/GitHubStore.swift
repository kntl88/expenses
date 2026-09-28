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
        var errorDescription: String? { message }
    }

    struct Snapshot {
        var expenses: [JSONValue]
        var sha: String
    }

    private var fileURL: URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(repo)/contents/\(Self.dataPath)")!
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
        let (data, resp) = try await URLSession.shared.data(for: request(fileURL))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            if code == 401 { throw StoreError(message: "GitHub token rejected (401). Re-unlock in Settings.") }
            throw StoreError(message: "Loading expenses failed: HTTP \(code)")
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
            let (raw, rresp) = try await URLSession.shared.data(for: request(fileURL, accept: "application/vnd.github.raw+json"))
            guard (rresp as? HTTPURLResponse)?.statusCode == 200 else { throw StoreError(message: "Loading raw expenses failed.") }
            fileBytes = raw
        }
        guard case let .array(items) = try JSONValue.parse(fileBytes) else {
            throw StoreError(message: "expenses.json is not an array.")
        }
        return Snapshot(expenses: items, sha: sha)
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

    /// Appends `newEntries`, optionally removing the expense with id `replacingId`, and saves.
    /// Re-fetches and re-applies on conflict, so concurrent web edits aren't lost.
    func commit(newEntries: [JSONValue], replacingId: String?, message: String) async throws {
        let newIds = Set(newEntries.compactMap { $0["id"]?.stringValue })
        for _ in 0..<3 {
            let snap = try await load()
            var list = snap.expenses.filter { item in
                guard let id = item["id"]?.stringValue else { return true }
                return id != replacingId && !newIds.contains(id)
            }
            list.append(contentsOf: newEntries)
            // Stable sort by date descending, same as the web app.
            list = list.enumerated().sorted { a, b in
                let da = a.element["date"]?.stringValue ?? "", db = b.element["date"]?.stringValue ?? ""
                return da != db ? da > db : a.offset < b.offset
            }.map(\.element)
            if try await put(list, sha: snap.sha, message: message) { return }
        }
        throw StoreError(message: "Saving failed: the file kept changing on GitHub. Try again.")
    }

    static func existing(from items: [JSONValue]) -> [ExistingExpense] {
        items.compactMap { v in
            guard let id = v["id"]?.stringValue, let amount = v["amount"]?.doubleValue,
                  let date = v["date"]?.stringValue else { return nil }
            return ExistingExpense(id: id, amount: amount, date: date,
                                   description: v["description"]?.stringValue ?? "",
                                   category: v["category"]?.stringValue ?? "",
                                   account: v["account"]?.stringValue)
        }
    }
}
