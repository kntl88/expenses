import AppIntents
import UIKit

/// Shortcuts action for Back Tap: "Take Screenshot" → "Import Wallet Screenshot". Opens the app,
/// which reads the payments in the screenshot of Wallet's transaction list.
struct ImportWalletScreenshotIntent: AppIntent {
    static var title: LocalizedStringResource = "Import Wallet Screenshot"
    static var description = IntentDescription("Adds the card payments in a screenshot of Wallet's transaction list to Receipts.")
    static var openAppWhenRun = true

    @Parameter(title: "Screenshot", supportedTypeIdentifiers: ["public.image"])
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
    var category: ReceiptCategory
    var status: String      // completed, pending, declined, refund
    /// A transaction already in expenses with the same amount nearby.
    var existing: Transaction?
    var include = true
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
                        "status": ["type": "string", "enum": ["completed", "pending", "declined", "refund"]],
                        "category": ["type": "string", "enum": ReceiptCategory.allCases.map(\.rawValue)],
                    ],
                    "required": ["merchant", "amount", "date", "status", "category"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["payments"],
        "additionalProperties": false,
    ]

    /// Reads the rows of a screenshot of Apple Wallet's card transaction list.
    func readWallet(_ image: UIImage, now: Date = Date()) async throws -> [WalletPayment] {
        guard let jpeg = ImageUtil.jpegForClaude(image) else { throw ClaudeError(message: "Couldn't encode the image.") }
        let today = Format.day.string(from: now)
        let weekday = now.formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "en_US")))
        let time = now.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute())
        let text = """
        This is a screenshot of Apple Wallet's transaction list for a payment card, from a personal expense tracker in Finland. List every transaction row shown.

        Now is \(weekday) \(today) \(time). Wallet shows recent dates relatively ("2 hours ago", "Yesterday", "Tuesday") — convert each to an absolute date YYYY-MM-DD; a weekday name means the most recent past such day.

        For each row: merchant as shown, amount in euros as a positive number, date, status (declined if the row says declined, pending if it says pending, refund if it's money back / a credit, otherwise completed) and the most likely spending category:
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

        Ignore anything that isn't a transaction row (card image, balance, headers). If there are no transaction rows, return an empty list.
        """
        let content: [[String: Any]] = [
            ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]],
            ["type": "text", "text": text],
        ]
        let result = try await send(content: content, schema: Self.walletSchema, maxTokens: 8000, effort: "low")
        return (result["payments"] as? [[String: Any]] ?? []).compactMap { p in
            guard let amount = (p["amount"] as? NSNumber)?.doubleValue, amount != 0,
                  let date = p["date"] as? String, Format.day.date(from: date) != nil else { return nil }
            return WalletPayment(merchant: (p["merchant"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                                 amount: Format.round2(abs(amount)), date: date,
                                 category: (p["category"] as? String).flatMap(ReceiptCategory.init(rawValue:)) ?? .misc,
                                 status: p["status"] as? String ?? "completed")
        }
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
