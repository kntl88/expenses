import Foundation
import UIKit

/// Calls the Claude Messages API with the receipt image(s). Categories follow the web app's
/// receipt prompt, but items come back one per line so they can be re-assigned and learned.
struct ClaudeClient {
    let apiKey: String
    static let model = "claude-opus-5"

    struct ClaudeError: LocalizedError {
        let message: String
        var isAuth = false
        var errorDescription: String? { message }
    }

    static func prompt(pageCount: Int, learned: [(name: String, category: ReceiptCategory)]) -> String {
        var s = """
        Read the Finnish store receipt(s) in this photo for a personal expense tracker. List every purchased line item and assign each one a spending category.

        The photo may show more than one receipt. Return each separate receipt (its own store header, total and payment) as its own entry in `receipts`, in order from top to bottom / left to right. Never merge different receipts into one.

        Categories:
        - basic (the default): everyday groceries and food items (incl. fresh fruit), household essentials, milk/juice/water; also any restaurant/cafe purchase under 5 EUR
        - fun: alcohol (beer, wine, cider, spirits), tobacco, entertainment, games; also pub/bar purchases
        - eo: prepared restaurant/cafe/takeaway food when the receipt is from a restaurant, cafe or takeaway and totals 5 EUR or more
        - gas: vehicle fuel
        - pu: durable goods and household purchases (electronics, tools, clothes, home items)
        - he: frozen berries and frozen fruits, health foods and supplements
        - med: pharmacy items and medicine
        - ta: household cleaning supplies and consumables (detergents, sprays, cleaning tools, paper towels)
        - misc: parking, anything that fits nothing else
        - un: soft drinks (Coca-Cola etc.), energy drinks, candy and sweets, clearly unnecessary impulse purchases that are not alcohol

        Rules:
        - One entry per purchased line, in receipt order, with the item name as printed.
        - amount: the final euros paid for that line (quantity x unit price). Apply line discounts to the item they belong to and add bottle deposits (pantti) to the drink they belong to, so discounts and deposits are not separate entries.
        - Each receipt's item amounts must sum exactly to that receipt's total. Subtract a receipt-level discount from the largest item.
        - When unsure, use basic.
        """
        if !learned.isEmpty {
            s += "\n\nThe user has previously put these items in these categories; follow the same choices for the same or clearly similar items:\n"
            s += learned.map { "- \($0.name) → \($0.category.rawValue)" }.joined(separator: "\n")
        }
        if pageCount > 1 {
            s += "\n\nThe \(pageCount) images are consecutive photos, top to bottom."
        }
        return s
    }

    private static let receiptSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "merchant": ["anyOf": [["type": "string"], ["type": "null"]]],
            "date": ["anyOf": [["type": "string"], ["type": "null"]],
                     "description": "Purchase date printed on the receipt as YYYY-MM-DD, or null"],
            "time": ["anyOf": [["type": "string"], ["type": "null"]],
                     "description": "Purchase time printed on the receipt as HH:MM (24h), or null"],
            "total": ["type": "number"],
            "items": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                        "amount": ["type": "number"],
                        "category": ["type": "string", "enum": ReceiptCategory.allCases.map(\.rawValue)],
                    ],
                    "required": ["name", "amount", "category"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["merchant", "date", "time", "total", "items"],
        "additionalProperties": false,
    ]

    static let schema: [String: Any] = [
        "type": "object",
        "properties": ["receipts": ["type": "array", "items": receiptSchema]],
        "required": ["receipts"],
        "additionalProperties": false,
    ]

    /// One entry per separate receipt found in the photo(s).
    func scan(images: [UIImage]) async throws -> [ReceiptScan] {
        var content: [[String: Any]] = images.compactMap { img in
            guard let jpeg = ImageUtil.jpegForClaude(img) else { return nil }
            return ["type": "image",
                    "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]]
        }
        guard !content.isEmpty else { throw ClaudeError(message: "Couldn't encode the image.") }
        content.append(["type": "text", "text": Self.prompt(pageCount: content.count, learned: ItemRules.promptHints())])

        let result = try await send(content: content, schema: Self.schema)
        let receipts: [ReceiptScan] = (result["receipts"] as? [[String: Any]] ?? []).compactMap { r in
            let items: [ReceiptItem] = (r["items"] as? [[String: Any]] ?? []).compactMap { p in
                guard let a = (p["amount"] as? NSNumber)?.doubleValue, a != 0 else { return nil }
                let c = (p["category"] as? String).flatMap(ReceiptCategory.init(rawValue:)) ?? .basic
                return ReceiptItem(name: p["name"] as? String ?? "", amount: Format.round2(a), category: c)
            }
            guard !items.isEmpty else { return nil }
            let date = (r["date"] as? String).flatMap { Format.day.date(from: $0) != nil ? $0 : nil }
            let time = (r["time"] as? String).flatMap { Format.minutes($0) != nil ? $0 : nil }
            return ReceiptScan(merchant: r["merchant"] as? String, date: date, time: time,
                               total: Format.round2((r["total"] as? NSNumber)?.doubleValue ?? items.reduce(0) { $0 + $1.amount }),
                               items: ItemRules.apply(to: items))
        }
        guard !receipts.isEmpty else { throw ClaudeError(message: "No items found on the receipt.") }
        return receipts
    }

    func send(content: [[String: Any]], schema: [String: Any],
                      maxTokens: Int = 16000, effort: String? = nil) async throws -> [String: Any] {
        var outputConfig: [String: Any] = ["format": ["type": "json_schema", "schema": schema]]
        if let effort { outputConfig["effort"] = effort }
        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": maxTokens,
            "output_config": outputConfig,
            // If the primary model declines, let the API retry on its default fallback model.
            "fallbacks": "default",
            "messages": [["role": "user", "content": content]],
        ]

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard code == 200, let json else {
            let msg = ((json?["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(code)"
            throw ClaudeError(message: "Claude API error: \(msg)", isAuth: code == 401)
        }
        if json["stop_reason"] as? String == "refusal" {
            throw ClaudeError(message: "Claude declined to read this receipt.")
        }
        if json["stop_reason"] as? String == "max_tokens" {
            throw ClaudeError(message: "Claude's response was cut off. Try again.")
        }
        guard let blocks = json["content"] as? [[String: Any]],
              let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let result = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { throw ClaudeError(message: "Couldn't parse Claude's response.") }
        return result
    }
}

enum ImageUtil {
    /// Longest side ≤ 1568 px, JPEG quality 0.85 — same as the web app.
    static func jpegForClaude(_ image: UIImage, maxSide: CGFloat = 1568) -> Data? {
        let w = image.size.width * image.scale, h = image.size.height * image.scale
        let scale = min(1, maxSide / max(w, h))
        let target = CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.85)
    }
}
