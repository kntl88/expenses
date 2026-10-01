import AppIntents

/// Run from a Shortcuts "Transaction" automation: pass the Wallet transaction's Amount and Merchant.
struct LogCardPaymentIntent: AppIntent {
    static var title: LocalizedStringResource = "Log Card Payment"
    static var description = IntentDescription("Adds a card payment to Expenses, categorized from the merchant name.")
    static var openAppWhenRun = false

    @Parameter(title: "Amount", description: "e.g. 12,40 € — the Transaction's Amount")
    var amount: String

    @Parameter(title: "Merchant", description: "The Transaction's Merchant")
    var merchant: String

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$amount) at \(\.$merchant)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let message: String
        // Wallet sometimes fires the trigger with no amount (a pass tap, or a card whose bank
        // doesn't share transaction details). Nothing to log then; the bank statement import covers it.
        if amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message = "Skipped: Wallet gave no amount" + (merchant.isEmpty ? "" : " for \(merchant)")
            AutomationLog.add(amount: amount, merchant: merchant, result: message)
            return .result(value: message, dialog: "\(message)")
        }
        do {
            message = try await PaymentLogger.log(amountText: amount, merchant: merchant)
        } catch {
            AutomationLog.add(amount: amount, merchant: merchant, result: "Error: \(error.localizedDescription)")
            throw error
        }
        AutomationLog.add(amount: amount, merchant: merchant, result: message)
        return .result(value: message, dialog: "\(message)")
    }
}

struct ReceiptShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: LogCardPaymentIntent(),
                    phrases: ["Log card payment in \(.applicationName)"],
                    shortTitle: "Log Card Payment",
                    systemImageName: "creditcard")
    }
}
