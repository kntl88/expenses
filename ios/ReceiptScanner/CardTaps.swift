import AppIntents
import Foundation

/// Run from a Shortcuts "Transaction" automation. Wallet usually doesn't have the amount yet at the
/// tap (it arrives 30–60 min later), so this only records that a payment happened; the Wallet
/// screenshot import later fills in the details and clears it.
struct RegisterCardTapIntent: AppIntent {
    static var title: LocalizedStringResource = "Register Card Tap"
    static var description = IntentDescription("Notes a card payment in Receipts as waiting for details from Wallet.")
    static var openAppWhenRun = false

    @Parameter(title: "Merchant", description: "The Transaction's Merchant, if Wallet has it")
    var merchant: String?

    @Parameter(title: "Amount", description: "The Transaction's Amount, if Wallet has it")
    var amount: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Register card tap at \(\.$merchant) for \(\.$amount)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let m = (merchant ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let a = CardTaps.parseAmount(amount ?? "")
        CardTaps.add(merchant: m, amount: a)
        var msg = "Card payment noted"
        if !m.isEmpty { msg += " at \(m)" }
        if let a { msg += " · \(Format.euro(a))" }
        return .result(dialog: "\(msg). Import it from Wallet when the details arrive.")
    }
}

/// Card taps waiting for their Wallet details; listed on Home under "Waiting for details".
enum CardTaps {
    struct Tap: Codable, Identifiable, Hashable {
        var id = UUID()
        var date: Date
        var merchant: String
        var amount: Double?

        var day: String { Format.day.string(from: date) }
    }

    private static let key = "cardTaps"

    static func load() -> [Tap] {
        guard let d = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Tap].self, from: d)) ?? []
    }

    static func add(merchant: String, amount: Double?) {
        save([Tap(date: Date(), merchant: merchant, amount: amount)] + load())
    }

    static func remove(_ ids: Set<UUID>) {
        save(load().filter { !ids.contains($0.id) })
    }

    private static func save(_ list: [Tap]) {
        // Older ones are covered by the statement import.
        let recent = list.filter { $0.date > Date().addingTimeInterval(-14 * 86400) }
        if let d = try? JSONEncoder().encode(Array(recent.prefix(50))) { UserDefaults.standard.set(d, forKey: key) }
    }

    /// Accepts "12.40", "12,40 €", "€12.40", "1 234,50"; nil for "" or anything without a positive number.
    static func parseAmount(_ s: String) -> Double? {
        var t = s.filter { "0123456789.,".contains($0) }
        guard !t.isEmpty else { return nil }
        if let lastSep = t.lastIndex(where: { $0 == "," || $0 == "." }) {
            let decimals = t.distance(from: lastSep, to: t.endIndex) - 1
            if decimals <= 2 {
                t = t[..<lastSep].filter(\.isNumber) + "." + t[t.index(after: lastSep)...]
            } else {
                t = t.filter(\.isNumber) // "1,234" style thousands separator
            }
        }
        guard let v = Double(t), v > 0 else { return nil }
        return Format.round2(v)
    }

    /// Pairs Wallet payments with waiting taps: same day (±1), the same amount when the tap has one,
    /// and the same merchant when both are known. Returns tap id per payment id.
    static func match(_ payments: [WalletPayment], taps: [Tap]) -> [UUID: Tap] {
        var result: [UUID: Tap] = [:]
        var free = taps.sorted { $0.date < $1.date }
        for p in payments where p.status != "declined" && p.status != "refund" {
            guard let pd = Format.day.date(from: p.date) else { continue }
            let i = free.firstIndex { t in
                let days = abs(Calendar(identifier: .gregorian).dateComponents([.day], from: Calendar.current.startOfDay(for: t.date), to: pd).day ?? 99)
                guard days <= 1 else { return false }
                if let a = t.amount, abs(a - p.amount) > 0.011 { return false }
                if !t.merchant.isEmpty, let tk = MerchantHistory.key(t.merchant), let pk = MerchantHistory.key(p.merchant),
                   !(tk == pk || tk.hasPrefix(pk) || pk.hasPrefix(tk)) { return false }
                return true
            }
            if let i { result[p.id] = free.remove(at: i) }
        }
        return result
    }
}
