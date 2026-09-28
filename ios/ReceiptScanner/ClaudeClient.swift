import Foundation
import UIKit

/// Calls the Claude Messages API with the receipt image(s), using the same prompt and
/// JSON schema as the web app's scanReceipt (index.html receiptPrompt / RECEIPT_SCHEMA).
struct ClaudeClient {
    let apiKey: String
    static let model = "claude-opus-5"

    struct ClaudeError: LocalizedError {
        let message: String
        var isAuth = false
        var errorDescription: String? { message }
    }

    static func prompt(pageCount: Int) -> String {
        var s = """
        Categorize this Finnish store receipt for a personal expense tracker. Read the line items and split the total into spending categories.

        Categories:
        - basic: everyday groceries and food items (incl. fresh fruit), household essentials, milk/juice/water; also any restaurant/cafe purchase under 5 EUR
        - fun: alcohol (beer, wine, cider, spirits), tobacco, entertainment, games; also pub/bar purchases
        - eo: prepared restaurant/cafe/takeaway food of 5 EUR or more (only when the receipt is from a restaurant, cafe or takeaway)
        - gas: vehicle fuel
        - pu: durable goods and household purchases (electronics, tools, clothes, home items)
        - he: frozen berries and frozen fruits, health foods and supplements
        - med: pharmacy items and medicine
        - ta: household cleaning supplies and consumables (detergents, sprays, cleaning tools, paper towels)
        - misc: parking, anything that fits nothing else
        - un: soft drinks (Coca-Cola etc.), energy drinks, candy and sweets, clearly unnecessary impulse purchases that are not alcohol

        Rules:
        - Merge items into as few parts as possible: at most one part per category.
        - Amounts are positive euros and must sum exactly to the receipt total. Fold discounts and bottle deposits (pantti) into the related category.
        - If everything is one category, return a single part.
        - label: 1-3 words describing the part (e.g. "groceries", "beer", "fuel").
        """
        if pageCount > 1 {
            s += "\n- The \(pageCount) images are consecutive sections of the same receipt, top to bottom."
        }
        return s
    }

    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "merchant": ["anyOf": [["type": "string"], ["type": "null"]]],
            "date": ["anyOf": [["type": "string"], ["type": "null"]],
                     "description": "Purchase date printed on the receipt as YYYY-MM-DD, or null"],
            "total": ["type": "number"],
            "parts": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "category": ["type": "string", "enum": ReceiptCategory.allCases.map(\.rawValue)],
                        "amount": ["type": "number"],
                        "label": ["type": "string"],
                    ],
                    "required": ["category", "amount", "label"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["merchant", "date", "total", "parts"],
        "additionalProperties": false,
    ]

    func scan(images: [UIImage]) async throws -> ReceiptScan {
        var content: [[String: Any]] = images.compactMap { img in
            guard let jpeg = ImageUtil.jpegForClaude(img) else { return nil }
            return ["type": "image",
                    "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]]
        }
        guard !content.isEmpty else { throw ClaudeError(message: "Couldn't encode the image.") }
        content.append(["type": "text", "text": Self.prompt(pageCount: content.count)])

        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 16000,
            "output_config": ["format": ["type": "json_schema", "schema": Self.schema]],
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

        let parts: [ReceiptPart] = (result["parts"] as? [[String: Any]] ?? []).compactMap { p in
            guard let c = (p["category"] as? String).flatMap(ReceiptCategory.init(rawValue:)),
                  let a = (p["amount"] as? NSNumber)?.doubleValue, a > 0 else { return nil }
            return ReceiptPart(category: c, amount: Format.round2(a), label: p["label"] as? String ?? "")
        }
        guard !parts.isEmpty else { throw ClaudeError(message: "No items found on the receipt.") }
        let date = (result["date"] as? String).flatMap { Format.day.date(from: $0) != nil ? $0 : nil }
        return ReceiptScan(merchant: result["merchant"] as? String, date: date,
                           total: Format.round2((result["total"] as? NSNumber)?.doubleValue ?? parts.reduce(0) { $0 + $1.amount }),
                           parts: parts)
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
