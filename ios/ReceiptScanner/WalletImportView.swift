import SwiftUI

/// Reads a Wallet screenshot and adds the payments that aren't in expenses yet as pending card payments.
struct WalletImportView: View {
    @Environment(AppState.self) private var app
    let job: ScanJob
    var onDone: () -> Void

    enum Phase { case reading, review, saving }
    @State private var phase: Phase = .reading
    @State private var started = false
    @State private var error: String?
    @State private var payments: [WalletPayment] = []

    private var selected: [WalletPayment] { payments.filter(\.include) }

    var body: some View {
        Group {
            switch phase {
            case .reading: readingView
            case .review, .saving: reviewList
            }
        }
        .navigationTitle("Wallet import")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if phase != .reading {
                ToolbarItem(placement: .confirmationAction) {
                    if phase == .saving {
                        ProgressView()
                    } else {
                        Button(selected.isEmpty ? "Add" : "Add \(selected.count)") { Task { await save() } }
                            .fontWeight(.semibold)
                            .disabled(selected.isEmpty)
                    }
                }
            }
        }
        .task { await start() }
    }

    private var readingView: some View {
        VStack(spacing: 20) {
            if let first = job.images.first {
                Image(uiImage: first).resizable().scaledToFit()
                    .frame(maxHeight: 320).clipShape(RoundedRectangle(cornerRadius: 12))
                    .opacity(error == nil ? 0.6 : 1)
            }
            if let error {
                Text(error).foregroundStyle(.red).multilineTextAlignment(.center)
                Button("Try again") { Task { await read() } }.buttonStyle(.borderedProminent)
            } else {
                ProgressView("Reading Wallet…")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var reviewList: some View {
        List {
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
            Section {
                if payments.isEmpty {
                    Text("No transactions found in the screenshot.").foregroundStyle(.secondary)
                }
                ForEach($payments) { $p in
                    PaymentRow(payment: $p)
                }
            } footer: {
                Text("New payments are added as pending, to confirm or itemize later. Ones already in Receipts (same amount within 5 days), declined ones and refunds are unchecked.")
            }
        }
    }

    // MARK: Actions

    private func start() async {
        guard !started else { return }
        started = true
        if app.transactions.isEmpty { await app.loadData() }
        await read()
    }

    private func read() async {
        guard let image = job.images.first, let claude = app.claude else { return }
        error = nil
        do {
            var found = try await claude.readWallet(image)
            var used: Set<String> = []
            for i in found.indices {
                if let g = MerchantHistory.guess(found[i].merchant, in: app.transactions) {
                    found[i].category = g.category
                    found[i].merchant = g.name
                }
                // Same rule as the receipt prompt: eating out under 5 € counts as basic.
                if found[i].category == .eo && found[i].amount < 5 { found[i].category = .basic }
                let match = app.transactions.first { t in
                    !used.contains(t.id) && abs(t.total - found[i].amount) < 0.011 && Self.dayDistance(t.date, found[i].date) <= 5
                }
                if let match { used.insert(match.id) }
                found[i].existing = match
                found[i].include = match == nil && (found[i].status == "completed" || found[i].status == "pending")
            }
            payments = found
            phase = .review
        } catch let e as ClaudeClient.ClaudeError where e.isAuth {
            app.saveAnthropicKey(nil)
            error = "Anthropic API key was rejected. Enter a new one in Settings."
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() async {
        guard let store = app.store, !selected.isEmpty else { return }
        phase = .saving
        error = nil
        let entries = selected.map { p in
            ExpenseEntry.make(amount: p.amount, date: p.date,
                              description: p.merchant.isEmpty ? "Card payment" : p.merchant,
                              category: p.category, account: app.defaultAccount, pending: true)
        }
        do {
            try await store.commit(newEntries: entries,
                                   message: "Wallet import \(entries.count) payment\(entries.count == 1 ? "" : "s") (iOS)")
            onDone()
            Task { await app.loadData(week: .after(.seconds(2.4))) }
        } catch {
            self.error = error.localizedDescription
            phase = .review
        }
    }

    private static func dayDistance(_ a: String, _ b: String) -> Int {
        guard let da = Format.day.date(from: a), let db = Format.day.date(from: b) else { return .max }
        return abs(Calendar(identifier: .gregorian).dateComponents([.day], from: da, to: db).day ?? .max)
    }
}

private struct PaymentRow: View {
    @Binding var payment: WalletPayment

    private var subtitle: String {
        if let t = payment.existing { return "\(payment.date) · already added: \(t.title)" }
        switch payment.status {
        case "declined": return "\(payment.date) · declined"
        case "refund": return "\(payment.date) · refund"
        case "pending": return "\(payment.date) · pending in Wallet"
        default: return payment.date
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Button { payment.include.toggle() } label: {
                Image(systemName: payment.include ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(payment.include ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
            Menu {
                Picker("Category", selection: $payment.category) {
                    ForEach(ReceiptCategory.allCases) { c in
                        Label(c.label, systemImage: c.symbol).tag(c)
                    }
                }
            } label: {
                Image(systemName: payment.category.symbol)
                    .frame(width: 32, height: 28)
                    .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 1) {
                TextField("Merchant", text: $payment.merchant).font(.subheadline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(Format.euro(payment.amount)).monospacedDigit()
        }
        .opacity(payment.include ? 1 : 0.55)
    }
}
