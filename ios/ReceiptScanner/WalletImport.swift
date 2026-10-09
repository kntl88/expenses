import AppIntents
import UniformTypeIdentifiers
import UIKit

/// Shortcuts action for Back Tap: "Take Screenshot" → "Import Wallet Screenshot". Opens the app,
/// which reads the payments in the screenshot of Wallet's transaction list.
struct ImportWalletScreenshotIntent: AppIntent {
    static var title: LocalizedStringResource = "Import Wallet Screenshot"
    static var description = IntentDescription("Adds the card payments in a screenshot of a transaction list (Wallet or a bank app) to Receipts.")
    static var openAppWhenRun = true

    @Parameter(title: "Screenshot", supportedContentTypes: [.image], inputConnectionBehavior: .connectToPreviousIntentResult)
    var screenshot: IntentFile

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let image = UIImage(data: screenshot.data) else {
            throw WalletImport.ImportError(message: "That isn't an image. Pass the Screenshot from Take Screenshot.")
        }
        WalletImport.request(image)
        return .result()
    }
}

/// Hand-off from the intent to HomeView (which may not exist yet on a cold launch).
@MainActor
enum WalletImport {
    struct ImportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let notification = Notification.Name("WalletImportRequested")
    private static var pending: UIImage?

    static func request(_ image: UIImage) {
        pending = image
        NotificationCenter.default.post(name: notification, object: nil)
    }

    static func take() -> UIImage? {
        defer { pending = nil }
        return pending
    }
}

/// A payment read from the Wallet screenshot.
struct WalletPayment: Identifiable {
    let id = UUID()
    var merchant: String
    var amount: Double      // positive euros
    var date: String        // YYYY-MM-DD
    var time: String?       // HH:MM when Wallet shows one (or a matched card tap does)
    var category: ReceiptCategory
    var status: String      // completed, pending, declined, refund
    /// A transaction already in expenses with the same amount nearby.
    var existing: Transaction?
    /// The waiting card tap this payment fills in.
    var tap: CardTaps.Tap?
    var include = true
}

/// What a transaction list screenshot showed.
struct WalletRead {
    enum Source: String { case wallet, norwegian, bank, other }
    var source: Source
    /// The card/account balance on screen (negative = owed), when a bank app shows one.
    var balance: Double?
    /// The month's totals from a month section header (Bank Norwegian: "Lokakuu · Käytetty 546,40 •
    /// Maksettu 0,00"), when shown.
    var month: MonthTotals?
    var payments: [WalletPayment]

    struct MonthTotals {
        /// YYYY-MM
        var month: String
        /// Card purchases in the month (positive), including reservations.
        var spent: Double
        /// Payments to the card in the month (positive).
        var paid: Double
    }

    /// Bank Norwegian rows are booked card purchases: added as accepted, not pending.
    var addsAccepted: Bool { source == .norwegian }

    /// The account this screenshot is from, when the source tells.
    var account: Account? {
        switch source {
        case .norwegian: .norwegian
        case .bank: .bank
        case .wallet, .other: nil
        }
    }
}

extension ClaudeClient {
    private static let walletSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "payments": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "merchant": ["type": "string"],
                        "amount": ["type": "number", "description": "Euros, positive"],
                        "date": ["type": "string", "description": "YYYY-MM-DD"],
                        "time": ["anyOf": [["type": "string"], ["type": "null"]],
                                 "description": "HH:MM (24h) when the row shows a clock time or an hours/minutes-ago time, else null"],
                        "status": ["type": "string", "enum": ["completed", "pending", "declined", "refund", "other"]],
                        "category": ["type": "string", "enum": ReceiptCategory.allCases.map(\.rawValue)],
                    ],
                    "required": ["merchant", "amount", "date", "time", "status", "category"],
                    "additionalProperties": false,
                ],
            ],
            "source": ["type": "string", "enum": ["apple_wallet", "bank_norwegian", "other_bank", "other"],
                       "description": "Which app the screenshot is from"],
            "balance": ["anyOf": [["type": "number"], ["type": "null"]],
                        "description": "The card's or account's current balance shown on screen, in euros; negative when it's money owed on a credit card; null if none is shown"],
            "month": ["anyOf": [
                ["type": "object",
                 "properties": [
                     "month": ["type": "string", "description": "YYYY-MM"],
                     "spent": ["type": "number", "description": "Euros used/spent in the month, positive"],
                     "paid": ["type": "number", "description": "Euros paid to the card in the month, positive"],
                 ],
                 "required": ["month", "spent", "paid"],
                 "additionalProperties": false],
                ["type": "null"],
            ], "description": "The newest month section header's spent/paid totals; null if none is shown"],
        ],
        "required": ["source", "balance", "month", "payments"],
        "additionalProperties": false,
    ]

    /// Reads the rows of a screenshot of Apple Wallet's card transaction list.
    func readWallet(_ image: UIImage, now: Date = Date()) async throws -> WalletRead {
        guard let jpeg = ImageUtil.jpegForClaude(image) else { throw ClaudeError(message: "Couldn't encode the image.") }
        let today = Format.day.string(from: now)
        let weekday = now.formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "en_US")))
        let time = now.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute())
        let text = """
        This is a screenshot of a payment card's transaction list — Apple Wallet or a bank app such as Bank Norwegian (the app may be in Finnish, Swedish, Norwegian or English) — from a personal expense tracker in Finland. List every transaction row shown.

        Now is \(weekday) \(today) \(time). Convert every date to an absolute YYYY-MM-DD: relative ones ("2 hours ago", "Yesterday", "Tänään", "Eilen", a weekday name = the most recent past such day), day-month ones without a year ("1.10.", "1. okt.", "1 Oct" = this year unless that is in the future), and dates from a section header the row sits under. Give a time HH:MM only when the row shows a clock time or "N minutes/hours ago".

        For each row: merchant as shown, amount in euros as a positive number, date, status and the most likely spending category.
        Status: declined if the row says declined/hylätty; pending if it's reserved, pending or authorized but not booked (varaus, katevaraus, reservert, reserverad); refund if it's money back to the card from a merchant; other for anything that isn't a purchase — payments to the card / invoice payments (maksu, innbetaling, inbetalning), interest (korko, rente), transfers, cash withdrawals; otherwise completed.
        Categories:
        - basic: grocery stores and supermarkets, everyday essentials; also any restaurant/cafe purchase under 5 EUR
        - fun: pubs, bars, alcohol shops (Alko), entertainment, games, cinema
        - eo: restaurants, cafes, takeaway and food delivery of 5 EUR or more
        - gas: fuel stations
        - pu: durable goods: electronics, hardware, clothes, home goods stores
        - he: health food stores, supplements
        - med: pharmacies (apteekki), doctors
        - ta: stores mainly selling cleaning and household consumables
        - misc: parking, public transport, services, anything unclear
        - un: kiosks and candy/soft-drink impulse purchases

        Ignore anything that isn't a transaction row (card image, balance, credit limit, headers, buttons). Skip a row cut off at the top or bottom edge of the screen or hidden behind a button or tab bar, so its merchant, date or amount isn't fully visible — it's read from the next screenshot. If there are no transaction rows, return an empty list.

        Also give the source app (apple_wallet, bank_norwegian for the Bank Norwegian app, other_bank for any other bank's app, other) and the balance. Balance: the current balance (saldo) of the card or account as shown — for a credit card, the amount used/owed as a negative number (e.g. "Saldo 167,13" owed → -167.13). Never the available amount (disponibelt, käytettävissä), the credit limit or a minimum payment. null when no balance is shown.

        Month: when a month section header shows the month's totals — amount used/spent (Käytetty, Brukt, Använt, Spent) and paid (Maksettu, Betalt, Paid) — give the newest such month as YYYY-MM with both amounts as positive numbers (paid 0 when it says 0,00). null when no month totals are shown.
        """
        let content: [[String: Any]] = [
            ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]],
            ["type": "text", "text": text],
        ]
        let result = try await send(content: content, schema: Self.walletSchema, maxTokens: 8000, effort: "low")
        let payments: [WalletPayment] = (result["payments"] as? [[String: Any]] ?? []).compactMap { p in
            guard let amount = (p["amount"] as? NSNumber)?.doubleValue, amount != 0,
                  let date = p["date"] as? String, Format.day.date(from: date) != nil else { return nil }
            return WalletPayment(merchant: (p["merchant"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                                 amount: Format.round2(abs(amount)), date: date,
                                 time: (p["time"] as? String).flatMap { Format.minutes($0) != nil ? $0 : nil },
                                 category: (p["category"] as? String).flatMap(ReceiptCategory.init(rawValue:)) ?? .misc,
                                 status: p["status"] as? String ?? "completed")
        }
        let source: WalletRead.Source = switch result["source"] as? String {
        case "apple_wallet": .wallet
        case "bank_norwegian": .norwegian
        case "other_bank": .bank
        default: .other
        }
        let month = (result["month"] as? [String: Any]).flatMap { m -> WalletRead.MonthTotals? in
            guard let month = m["month"] as? String, month.count == 7, Format.day.date(from: month + "-01") != nil,
                  let spent = (m["spent"] as? NSNumber)?.doubleValue else { return nil }
            return .init(month: month, spent: Format.round2(abs(spent)),
                         paid: Format.round2(abs((m["paid"] as? NSNumber)?.doubleValue ?? 0)))
        }
        return WalletRead(source: source, balance: (result["balance"] as? NSNumber).map { Format.round2($0.doubleValue) },
                          month: month, payments: payments)
    }
}

/// Picks a category from how you've categorized the same merchant before.
enum MerchantHistory {
    /// "K-MARKET HERTTONIE" → "kmarket"; "Lidl Suomi KY" → "lidl".
    static func key(_ s: String) -> String? {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fi_FI"))
        let cleaned = String(String.UnicodeScalarView(folded.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == " "
        }))
        return cleaned.split(separator: " ").map(String.init).first { $0.count >= 3 && Int($0) == nil }
    }

    /// Your latest name and majority category (weighted by euros) for this merchant, from the
    /// transactions the app shows.
    static func guess(_ merchant: String, in transactions: [Transaction]) -> (category: ReceiptCategory, name: String)? {
        guard let k = key(merchant) else { return nil }
        var weight: [ReceiptCategory: Double] = [:]
        var name: String?
        for tx in transactions where !tx.pending {
            guard let tk = key(tx.title),
                  tk == k || (k.count >= 5 && tk.hasPrefix(k)) || (tk.count >= 5 && k.hasPrefix(tk)) else { continue }
            for row in tx.rows { if let t = row.token { weight[t, default: 0] += row.amount } }
            if name == nil { name = tx.title } // newest first: reuse your latest naming
        }
        let total = weight.values.reduce(0, +)
        guard let top = weight.max(by: { $0.value < $1.value }), total > 0, top.value / total >= 0.5 else { return nil }
        return (top.key, name ?? merchant)
    }
}
