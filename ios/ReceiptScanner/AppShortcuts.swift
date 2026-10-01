import AppIntents

struct ReceiptShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ScanReceiptIntent(),
                    phrases: ["Scan receipt in \(.applicationName)"],
                    shortTitle: "Scan Receipt",
                    systemImageName: "doc.text.viewfinder")
    }
}
