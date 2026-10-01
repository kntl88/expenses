import AppIntents
import Foundation

/// Opens the app straight into the camera. Used by the lock-screen / Control Center control
/// (ReceiptControls) and available as a Shortcuts action. Compiled into both targets so the
/// system runs it in the app.
struct ScanReceiptIntent: AppIntent {
    static var title: LocalizedStringResource = "Scan Receipt"
    static var description = IntentDescription("Opens Receipts with the camera ready to scan a receipt.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        ScanRequest.request()
        return .result()
    }
}

/// Hand-off from the intent to HomeView, which may not exist yet on a cold launch.
@MainActor
enum ScanRequest {
    static let notification = Notification.Name("ScanReceiptRequested")
    private(set) static var pending = false

    static func request() {
        pending = true
        NotificationCenter.default.post(name: notification, object: nil)
    }

    /// True once per request.
    static func take() -> Bool {
        defer { pending = false }
        return pending
    }
}
