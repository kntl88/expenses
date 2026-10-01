import SwiftUI
import WidgetKit

/// Lock screen widget-row button that opens the camera. Lock screen widgets can't run intents,
/// so it opens the app with receipts://scan instead (handled in ReceiptScannerApp).
struct ScanWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.kntl88.ReceiptScanner.scanWidget", provider: ScanProvider()) { _ in
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "doc.text.viewfinder").font(.system(size: 22, weight: .medium))
            }
            .widgetURL(ScanRequest.url)
            .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Scan Receipt")
        .description("Opens the camera to scan a receipt.")
        .supportedFamilies([.accessoryCircular])
    }
}

private struct ScanProvider: TimelineProvider {
    struct Entry: TimelineEntry { let date = Date() }
    func placeholder(in context: Context) -> Entry { Entry() }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(Entry()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry()], policy: .never))
    }
}
