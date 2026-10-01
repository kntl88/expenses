import AppIntents
import SwiftUI
import WidgetKit

@main
struct ReceiptControlsBundle: WidgetBundle {
    var body: some Widget {
        ScanReceiptControl()
        ConsumptionWidget()
    }
}

/// Lock screen / Control Center button that opens the camera in Receipts.
struct ScanReceiptControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.kntl88.ReceiptScanner.scan") {
            ControlWidgetButton(action: ScanReceiptIntent()) {
                Label("Scan Receipt", systemImage: "doc.text.viewfinder")
            }
        }
        .displayName("Scan Receipt")
        .description("Opens the camera to scan a receipt.")
    }
}
