import SwiftUI

@main
struct ReceiptScannerApp: App {
    @State private var app = AppState()

    var body: some Scene {
        WindowGroup {
            Group {
                if app.isConfigured {
                    HomeView()
                } else {
                    SetupView()
                }
            }
            .environment(app)
        }
    }
}
