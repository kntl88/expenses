import AppIntents

struct ReceiptShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ScanReceiptIntent(),
                    phrases: ["Scan receipt in \(.applicationName)"],
                    shortTitle: "Scan Receipt",
                    systemImageName: "doc.text.viewfinder")
        AppShortcut(intent: ImportWalletScreenshotIntent(),
                    phrases: ["Import Wallet screenshot in \(.applicationName)"],
                    shortTitle: "Import Wallet Screenshot",
                    systemImageName: "wallet.pass")
        AppShortcut(intent: RegisterCardTapIntent(),
                    phrases: ["Register card tap in \(.applicationName)"],
                    shortTitle: "Register Card Tap",
                    systemImageName: "creditcard")
    }
}
