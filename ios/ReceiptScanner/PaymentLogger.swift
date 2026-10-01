import Foundation

/// Logs a card payment (from the Shortcuts "Transaction" automation) straight into expenses.json.
enum PaymentLogger {
    struct LogError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// `date`: when the card was tapped (defaults to now).
    static func log(amountText: String, merchant rawMerchant: String, date day: Date = Date()) async throws -> String {
        guard let amount = parseAmount(amountText), amount > 0 else {
            throw LogError(message: "Couldn't read the amount \"\(amountText)\". In the automation, tap the Amount field's token and choose Amount (it's passing the whole transaction or the card name).")
        }
        let merchant = rawMerchant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let store = Credentials.store else {
            throw LogError(message: "Receipts isn't connected. Open the app and unlock the vault.")
        }

        // 1. Your own history for this merchant  2. Claude  3. misc
        var history: [JSONValue] = []
        do { history = try await store.load().expenses } catch {}
        var source = "history"
        var guess = MerchantCategorizer.fromHistory(merchant, items: history)
        if guess == nil, let claude = Credentials.claude {
            if let (c, name) = try? await claude.classifyMerchant(merchant, amount: amount) {
                guess = .init(category: c, name: name)
                source = "Claude"
            }
        }
        var category = guess?.category ?? .misc
        if guess == nil { source = "uncategorized" }
        // Same rule as the receipt prompt: eating out under 5 € counts as basic.
        if category == .eo && amount < 5 { category = .basic }
        let name = guess?.name ?? (merchant.isEmpty ? "Card payment" : merchant)

        let date = Format.day.string(from: day)
        // Pending until a receipt is scanned for it or it's allocated in the app.
        let entry = ExpenseEntry.make(amount: amount, date: date, description: name,
                                      category: category, account: Credentials.defaultAccount, pending: true)
        var offline = false
        do {
            try await store.commit(newEntries: [entry], message: "Card payment \(name) \(date) (iOS)")
            if !history.isEmpty { // a failed history load would leave the widgets with one row
                WidgetData.save(expenses: [entry] + history, accounts: try? await store.loadAccounts())
            }
        } catch {
            Outbox.add(entry)
            offline = true
        }
        let msg = "\(Format.euro(amount)) · \(name) → \(category.label)"
        return offline ? msg + " (saved offline, will sync)" : msg + (source == "Claude" ? " ✦" : "")
    }

    /// Accepts "12.40", "12,40 €", "€12.40", "1 234,50", "-3,20".
    static func parseAmount(_ s: String) -> Double? {
        var t = s.filter { "0123456789.,".contains($0) }
        guard !t.isEmpty else { return nil }
        if let lastSep = t.lastIndex(where: { $0 == "," || $0 == "." }) {
            let decimals = t.distance(from: lastSep, to: t.endIndex) - 1
            if decimals <= 2 {
                let intPart = t[..<lastSep].filter(\.isNumber)
                t = intPart + "." + t[t.index(after: lastSep)...]
            } else {
                t = t.filter(\.isNumber) // "1,234" style thousands separator
            }
        }
        return Double(t).map(Format.round2)
    }
}

/// Picks a category from how you've categorized the same merchant before.
enum MerchantCategorizer {
    struct Guess { let category: ReceiptCategory; let name: String }

    /// "K-MARKET HERTTONIE" → "kmarket"; "Lidl Suomi KY" → "lidl".
    static func key(_ s: String) -> String? {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fi_FI"))
        let cleaned = String(String.UnicodeScalarView(folded.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == " "
        }))
        return cleaned.split(separator: " ").map(String.init).first { $0.count >= 3 && Int($0) == nil }
    }

    /// Reverse of ReceiptCategory.stored.
    static func token(category: String, subCategory: String?) -> ReceiptCategory? {
        switch (category, subCategory) {
        case ("unnecessary", "eating_out"): return .eo
        case ("unnecessary", _): return .un
        case ("budgeted", "purchases"): return .pu
        case ("budgeted", "health"): return .he
        case ("budgeted", "medical"): return .med
        case ("budgeted", "taloustarvikkeet"): return .ta
        case ("basic", _): return .basic
        case ("fun", _): return .fun
        case ("gas", _): return .gas
        case ("misc", _): return .misc
        default: return nil
        }
    }

    static func fromHistory(_ merchant: String, items: [JSONValue]) -> Guess? {
        guard let k = key(merchant) else { return nil }
        // Weight by euros so a receipt split into "groceries 40 €" + "candy 2 €" still reads as basic.
        var weight: [ReceiptCategory: Double] = [:]
        var name: String?
        for item in items.prefix(2000) {
            guard let amt = item["amount"]?.doubleValue, amt < 0,
                  let desc = item["description"]?.stringValue,
                  let cat = item["category"]?.stringValue,
                  let t = token(category: cat, subCategory: item["subCategory"]?.stringValue) else { continue }
            let base = desc.components(separatedBy: " · ").first ?? desc
            guard let dk = key(base),
                  dk == k || (k.count >= 5 && dk.hasPrefix(k)) || (dk.count >= 5 && k.hasPrefix(dk)) else { continue }
            weight[t, default: 0] += -amt
            if name == nil { name = base } // list is newest-first: reuse your latest naming
        }
        let total = weight.values.reduce(0, +)
        guard let top = weight.max(by: { $0.value < $1.value }), total > 0, top.value / total >= 0.5 else { return nil }
        return Guess(category: top.key, name: name ?? merchant)
    }
}

/// Credentials read directly from Keychain/UserDefaults so intents work without the UI.
enum Credentials {
    static var store: GitHubStore? {
        guard let t = Keychain.get("githubToken"), !t.isEmpty,
              let r = UserDefaults.standard.string(forKey: "repo"), !r.isEmpty else { return nil }
        return GitHubStore(owner: Vault.owner, repo: r, token: t)
    }

    static var claude: ClaudeClient? {
        guard let k = Keychain.get("anthropicKey"), !k.isEmpty else { return nil }
        return ClaudeClient(apiKey: k)
    }

    static var defaultAccount: Account {
        Account(rawValue: UserDefaults.standard.string(forKey: "defaultAccount") ?? "") ?? .norwegian
    }
}

/// Entries that couldn't be saved (no network); retried when the app becomes active.
enum Outbox {
    private static let key = "outbox"

    static var count: Int { (UserDefaults.standard.stringArray(forKey: key) ?? []).count }

    static func add(_ entry: JSONValue) {
        var list = UserDefaults.standard.stringArray(forKey: key) ?? []
        list.append(entry.pretty())
        UserDefaults.standard.set(list, forKey: key)
    }

    static func flush() async {
        let list = UserDefaults.standard.stringArray(forKey: key) ?? []
        guard !list.isEmpty, let store = Credentials.store else { return }
        let entries = list.compactMap { try? JSONValue.parse(Data($0.utf8)) }
        do {
            // commit() de-duplicates by id, so a retry after a partial failure is safe.
            try await store.commit(newEntries: entries, message: "Sync \(entries.count) offline card payments (iOS)")
            let now = UserDefaults.standard.stringArray(forKey: key) ?? []
            UserDefaults.standard.set(Array(now.dropFirst(list.count)), forKey: key)
        } catch {}
    }
}

/// What the Shortcuts automation actually passed in, for troubleshooting (Settings → Automation log).
enum AutomationLog {
    struct Entry: Codable, Identifiable {
        var id = UUID()
        var date: Date
        var amount: String
        var merchant: String
        var result: String
    }

    private static let key = "automationLog"

    static func load() -> [Entry] {
        guard let d = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: d)) ?? []
    }

    static func add(amount: String, merchant: String, result: String) {
        let list = Array(([Entry(date: Date(), amount: amount, merchant: merchant, result: result)] + load()).prefix(20))
        if let d = try? JSONEncoder().encode(list) { UserDefaults.standard.set(d, forKey: key) }
    }
}

/// Card taps where Wallet didn't have the amount yet; listed on Home under "Needs amount".
enum MissedTaps {
    struct Tap: Codable, Identifiable, Hashable {
        var id = UUID()
        var date: Date
        var merchant: String
    }

    private static let key = "missedTaps"

    static func load() -> [Tap] {
        guard let d = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Tap].self, from: d)) ?? []
    }

    static func add(merchant: String) {
        save([Tap(date: Date(), merchant: merchant)] + load())
    }

    static func remove(_ id: UUID) {
        save(load().filter { $0.id != id })
    }

    private static func save(_ list: [Tap]) {
        // Old ones are covered by the statement import.
        let recent = list.filter { $0.date > Date().addingTimeInterval(-14 * 86400) }
        if let d = try? JSONEncoder().encode(Array(recent.prefix(50))) { UserDefaults.standard.set(d, forKey: key) }
    }
}
