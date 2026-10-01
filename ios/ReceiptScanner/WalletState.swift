import AppIntents
import Foundation

/// Whether Wallet is in front, kept by two Shortcuts app automations (Wallet opened / closed), so
/// the Back Tap shortcut can do nothing outside Wallet — Back Tap itself works everywhere.
enum WalletState {
    private static let key = "walletOpenedAt"
    /// A missed "closed" automation shouldn't leave Back Tap armed for long.
    private static let maxOpen: TimeInterval = 15 * 60

    static func set(open: Bool) {
        if open { UserDefaults.standard.set(Date(), forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
    }

    static var isOpen: Bool {
        guard let d = UserDefaults.standard.object(forKey: key) as? Date else { return false }
        return Date().timeIntervalSince(d) < maxOpen
    }
}

struct WalletOpenedIntent: AppIntent {
    static var title: LocalizedStringResource = "Wallet Opened"
    static var description = IntentDescription("Run from an app automation when Wallet is opened.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        WalletState.set(open: true)
        return .result()
    }
}

struct WalletClosedIntent: AppIntent {
    static var title: LocalizedStringResource = "Wallet Closed"
    static var description = IntentDescription("Run from an app automation when Wallet is closed.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        WalletState.set(open: false)
        return .result()
    }
}

struct IsWalletOpenIntent: AppIntent {
    static var title: LocalizedStringResource = "Is Wallet Open"
    static var description = IntentDescription("True while Wallet is in front (per the Wallet Opened / Closed automations).")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        .result(value: WalletState.isOpen)
    }
}
