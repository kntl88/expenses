import SwiftUI

@main
struct ReceiptScannerApp: App {
    @State private var app = AppState()
    @Environment(\.scenePhase) private var scenePhase

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
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await app.refresh() } }
            }
        }
    }
}
