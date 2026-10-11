import SwiftUI

/// Reads a Wallet or bank app screenshot, then goes through its payments one by one in the review
/// (`ReviewView`) to accept: new ones are added as transactions, ones already in Receipts show their
/// previous itemization. A balance on screen, or the current month's spent/paid totals, is checked
/// against the app's.
struct WalletImportView: View {
    @Environment(AppState.self) private var app
    let job: ScanJob
    var onDone: () -> Void

    /// `confirm` first, so an accidental Back Tap screenshot is never sent to Claude.
    enum Phase { case confirm, reading, review, done }
    @State private var phase: Phase = .confirm
    @State private var started = false
    @State private var error: String?
    @State private var payments: [WalletPayment] = []
    @State private var read: WalletRead?
    /// The balance the screenshot shows, or the one its month totals imply.
    @State private var reported: Double?
    /// The account's balance in Receipts when the screenshot was read.
    @State private var balanceBefore: Double?
    /// The payments to review, in screenshot order.
    @State private var queue: [WalletPayment] = []
    @State private var accepted = 0
    /// Spending added to `account` by the accepted payments.
    @State private var added = 0.0

    private var account: Account { read?.account ?? app.defaultAccount }

    var body: some View {
        if phase == .review {
            ReviewView(job: job, imported: queue, importAccount: account, onDone: finishReview) { acc, amount in
                accepted += 1
                if acc == account { added = Format.round2(added + amount) }
            }
        } else {
            Group {
                switch phase {
                case .confirm: confirmView
                case .reading, .review: readingView
                case .done: doneList
                }
            }
            .navigationTitle("Import payments")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(phase == .confirm || phase == .done)
            .toolbar {
                if phase == .confirm {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onDone)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Import") { Task { await start() } }.fontWeight(.semibold)
                    }
                }
                if phase == .done {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onDone).fontWeight(.semibold)
                    }
                }
            }
        }
    }

    private var confirmView: some View {
        VStack(spacing: 12) {
            if let first = job.images.first {
                Image(uiImage: first).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
            }
            Text("Read the card payments in this screenshot?")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                ProgressView("Reading payments…")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// After the review: what was accepted, the balance check, and the rows that weren't purchases.
    private var doneList: some View {
        List {
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
            Section {
                if queue.isEmpty {
                    Text(payments.isEmpty ? "No transactions found in the screenshot." : "No payments to import.")
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent("Accepted", value: "\(accepted) of \(queue.count)")
                }
            }
            if let reported, let before = balanceBefore, let b = app.balances.first(where: { $0.key == account.rawValue }) {
                let after = Format.round2(before - added)
                let off = abs(reported - after) >= 0.005
                Section {
                    if read?.balance == nil, let m = read?.month {
                        let bank = Format.round2(m.spent - m.paid)
                        let here = Format.round2(app.monthNet(account.rawValue, month: m.month) + added)
                        LabeledContent("\(m.month) spent − paid, bank", value: Format.euro(bank))
                        LabeledContent("\(m.month) in Receipts", value: Format.euro(here))
                            .foregroundStyle(abs(bank - here) >= 0.005 ? .red : .primary)
                        if bank - here >= 0.005 {
                            Text("\(Format.euro(bank - here)) of this month's payments are missing from Receipts.")
                                .font(.footnote).foregroundStyle(.red)
                        } else if here - bank >= 0.005 {
                            Text("Receipts has \(Format.euro(here - bank)) more this month than the bank.")
                                .font(.footnote).foregroundStyle(.red)
                        }
                    }
                    LabeledContent("\(b.label) \(read?.balance == nil ? "by the screenshot" : "in screenshot")", value: Format.euro(reported))
                    LabeledContent("In Receipts now", value: Format.euro(after))
                        .foregroundStyle(off ? .red : .primary)
                } footer: {
                    Text((read?.balance == nil ? "From the month's totals, taking the app's balance at the end of last month as right. " : "")
                         + (off ? "Doesn't match: \(Format.euro(abs(reported - after))) \(reported > after ? "more" : "less") in the bank. The \(b.label) balance is highlighted on Home until it matches."
                             : "Matches."))
                }
            }
            let ignored = payments.filter { !$0.include && $0.existing == nil }
            if !ignored.isEmpty {
                Section {
                    ForEach(ignored) { PaymentRow(payment: $0) }
                } header: {
                    Text("Not imported")
                } footer: {
                    Text("Declined payments, refunds and non-purchases.")
                }
            }
        }
    }

    // MARK: Actions

    private func start() async {
        guard !started else { return }
        started = true
        phase = .reading
        if app.transactions.isEmpty { await app.loadData() }
        await read()
    }

    private func read() async {
        guard let image = job.images.first, let claude = app.claude else { return }
        error = nil
        do {
            let result = try await claude.readWallet(image)
            if let account = result.account {
                reported = result.balance ?? result.month.flatMap {
                    app.balanceFromMonth(account.rawValue, month: $0.month, spent: $0.spent, paid: $0.paid)
                }
                if let reported { app.recordBalanceCheck(account.rawValue, reported: reported) }
            }
            var found = result.payments
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
            let taps = CardTaps.match(found, taps: app.cardTaps)
            for i in found.indices {
                found[i].tap = taps[found[i].id]
                if let tap = found[i].tap { found[i].time = Format.hhmm(tap.date) } // exact, from the tap
            }
            payments = found
            read = result
            balanceBefore = app.balances.first { $0.key == (result.account ?? app.defaultAccount).rawValue }?.value
            queue = found.filter { $0.include || $0.existing != nil }
            phase = queue.isEmpty ? .done : .review
        } catch let e as ClaudeClient.ClaudeError where e.isAuth {
            app.saveAnthropicKey(nil)
            error = "Anthropic API key was rejected. Enter a new one in Settings."
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The review went through the queue (accepted or skipped each). A tap whose payment was already
    /// in Receipts is done either way; with a balance to check, the summary shows it.
    private func finishReview() {
        app.clearTaps(Set(payments.compactMap { $0.existing != nil ? $0.tap?.id : nil }))
        if reported == nil { onDone() } else { phase = .done }
    }

    private static func dayDistance(_ a: String, _ b: String) -> Int {
        guard let da = Format.day.date(from: a), let db = Format.day.date(from: b) else { return .max }
        return abs(Calendar(identifier: .gregorian).dateComponents([.day], from: da, to: db).day ?? .max)
    }
}

private struct PaymentRow: View {
    let payment: WalletPayment

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: payment.category.symbol)
                .frame(width: 32, height: 28)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text(payment.merchant).font(.subheadline)
                Text([payment.date, payment.note].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(Format.euro(payment.amount)).monospacedDigit()
        }
        .foregroundStyle(.secondary)
    }
}
