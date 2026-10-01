import Foundation
import WidgetKit

/// Latest expenses.json + accounts.json, cached by the app in the shared App Group container so the
/// widgets can compute this week's Consumption themselves (correct across midnight, no network).
enum WidgetData {
    static let group = "group.com.kntl88.ReceiptScanner"

    private static var dir: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }

    /// `accounts` nil keeps the previously cached accounts.
    static func save(expenses: [JSONValue], accounts: JSONValue?) {
        guard let dir else { return }
        try? Data(JSONValue.array(expenses).pretty().utf8).write(to: dir.appendingPathComponent("expenses.json"), options: .atomic)
        if let accounts {
            try? Data(accounts.pretty().utf8).write(to: dir.appendingPathComponent("accounts.json"), options: .atomic)
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func load() -> (expenses: [JSONValue], accounts: JSONValue, updated: Date)? {
        guard let dir else { return nil }
        let file = dir.appendingPathComponent("expenses.json")
        guard let data = try? Data(contentsOf: file),
              case let .array(expenses)? = try? JSONValue.parse(data) else { return nil }
        let accounts = (try? Data(contentsOf: dir.appendingPathComponent("accounts.json")))
            .flatMap { try? JSONValue.parse($0) } ?? .object([])
        let updated = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) ?? .distantPast
        return (expenses, accounts, updated)
    }
}
