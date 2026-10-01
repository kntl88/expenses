import SwiftUI

/// Two modes:
/// - receipt (`job` set): sends the photo to Claude, shows its line items grouped by category
///   (tap an item's category to move it) and writes one row per category with its receipt lines;
/// - allocate (`job` nil): splits/categorizes an existing transaction (e.g. a pending card payment)
///   without a receipt.
/// Either way it can replace a transaction (`target`, or one picked from matching candidates).
struct ReviewView: View {
    @Environment(AppState.self) private var app
    let job: ScanJob?
    var target: Transaction? = nil
    var onDone: () -> Void

    enum Phase { case scanning, review, saving }
    @State private var phase: Phase = .scanning
    @State private var started = false
    @State private var error: String?

    @State private var scan: ReceiptScan?
    /// All receipts found in the photo; they're reviewed and saved one after another.
    @State private var queue: [ReceiptScan] = []
    @State private var position = 0
    /// Something from this photo was saved; Home reveals the updated Consumption on the way back.
    @State private var savedAny = false
    @State private var items: [ReceiptItem] = []
    @State private var description = ""
    @State private var date = Date()
    @State private var account: Account = .norwegian

    @State private var replacing: Transaction?
    /// A card tap still waiting for Wallet details that this receipt fills in (matched by time).
    @State private var matchedTap: CardTaps.Tap?
    @State private var showImage = false

    private var sum: Double { Format.round2(items.reduce(0) { $0 + $1.amount }) }
    private var dateString: String { Format.day.string(from: date) }

    /// Categories in use, in the standard order, with their totals.
    private var groups: [(category: ReceiptCategory, items: [ReceiptItem], total: Double)] {
        ReceiptCategory.allCases.compactMap { c in
            let list = items.filter { $0.category == c }
            return list.isEmpty ? nil : (c, list, Format.round2(list.reduce(0) { $0 + $1.amount }))
        }
    }

    /// Receipt lines are stored with the rows; manual allocation splits are not receipt lines.
    private var storesItems: Bool { job != nil || (target?.isItemized ?? false) }

    /// Transactions that could be this same purchase (a pending card payment, or one imported from the
    /// statement): same amount, within ±10 days — Norwegian booking dates lag, so match by amount.
    /// Pending payments first.
    private var candidates: [Transaction] {
        guard !items.isEmpty else { return [] }
        let targets = [sum, scan?.total ?? sum]
        return app.transactions
            .filter { t in
                targets.contains { abs(t.total - $0) < 0.011 } && Self.dayDistance(t.date, dateString) <= 10
            }
            .sorted { a, b in
                a.pending != b.pending ? a.pending : Self.dayDistance(a.date, dateString) < Self.dayDistance(b.date, dateString)
            }
    }

    private var replaceMismatch: Bool {
        guard let r = replacing else { return false }
        return abs(r.total - sum) > 0.01
    }

    private var canSave: Bool {
        phase == .review && !groups.isEmpty && groups.allSatisfy { $0.total > 0 } && !replaceMismatch
    }

    var body: some View {
        Group {
            switch phase {
            case .scanning: scanningView
            case .review, .saving: reviewForm
            }
        }
        .navigationTitle(job == nil ? "Allocate" : "Receipt")
        .toolbar {
            if queue.count > 1, phase == .review {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(position + 1 < queue.count ? "Skip" : "Skip & finish") { advance() }
                }
            }
            if phase != .scanning {
                ToolbarItem(placement: .confirmationAction) {
                    if phase == .saving {
                        ProgressView()
                    } else {
                        Button(replacing == nil ? "Save" : "Replace") { Task { await save() } }
                            .fontWeight(.semibold)
                            .disabled(!canSave)
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await start() }
        .sheet(isPresented: $showImage) { imageSheet }
    }

    // MARK: Phases

    private var scanningView: some View {
        VStack(spacing: 20) {
            if let first = job?.images.first {
                Image(uiImage: first).resizable().scaledToFit()
                    .frame(maxHeight: 320).clipShape(RoundedRectangle(cornerRadius: 12))
                    .opacity(error == nil ? 0.6 : 1)
            }
            if let error {
                Text(error).foregroundStyle(.red).multilineTextAlignment(.center)
                Button("Try again") { Task { await runScan() } }.buttonStyle(.borderedProminent)
            } else {
                ProgressView("Reading receipt…")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var reviewForm: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    if let first = job?.images.first {
                        Button { showImage = true } label: {
                            Image(uiImage: first).resizable().scaledToFill()
                                .frame(width: 56, height: 72).clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                    VStack(alignment: .leading) {
                        if job != nil {
                            if queue.count > 1 {
                                Text("Receipt \(position + 1) of \(queue.count)").font(.caption.weight(.semibold)).foregroundStyle(.tint)
                            }
                            Text(scan?.merchant ?? "Unknown merchant").font(.headline)
                            if let total = scan?.total {
                                Text("Receipt total \(Format.euro(total))").font(.subheadline).foregroundStyle(.secondary)
                            }
                        } else if let t = target {
                            Text(t.title).font(.headline)
                            Text("\(t.pending ? "Pending card payment" : "Transaction") · \(Format.euro(t.total))")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }

            Section("Details") {
                TextField("Description", text: $description)
                DatePicker("Date", selection: $date, displayedComponents: .date)
                Picker("Account", selection: $account) {
                    ForEach(Account.allCases.filter { $0 != .work }) { Text($0.label).tag($0) }
                }
            }

            ForEach(groups, id: \.category) { group in
                Section {
                    ForEach(group.items) { item in
                        ItemRow(item: binding(item.id))
                    }
                    .onDelete { offsets in
                        let ids = Set(offsets.map { group.items[$0].id })
                        items.removeAll { ids.contains($0.id) }
                    }
                } header: {
                    HStack {
                        Label(group.category.label, systemImage: group.category.symbol)
                        Spacer()
                        Text(Format.euro(group.total)).monospacedDigit()
                    }
                }
            }

            Section {
                Button {
                    let remaining = Format.round2((replacing?.total ?? scan?.total ?? 0) - sum)
                    items.append(ReceiptItem(name: "", amount: max(remaining, 0), category: .basic))
                } label: {
                    Label("Add item", systemImage: "plus.circle")
                }
            } footer: {
                totalsFooter
            }

            replaceSection
        }
        .scrollDismissesKeyboard(.interactively)
        .animation(.default, value: items.map(\.category))
    }

    private var totalsFooter: some View {
        let total = replacing?.total ?? scan?.total
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Sum \(Format.euro(sum))")
                if let total, abs(total - sum) > 0.01 {
                    Text("≠ \(Format.euro(total))").foregroundStyle(.orange)
                }
            }
            .monospacedDigit()
            Text(job != nil ? "Tap an item's category to move it. Non-Basic choices are remembered for next time."
                            : "Tap the category to change it; add items to split the amount.")
        }
    }

    @ViewBuilder private var replaceSection: some View {
        if let t = target {
            Section("Replaces") {
                TransactionRow(tx: t)
                if replaceMismatch {
                    Text("Items must sum to \(Format.euro(t.total)).").foregroundStyle(.red)
                }
            }
        } else {
            Section {
                if candidates.isEmpty && replacing == nil {
                    Text("No transaction with this amount nearby — will add as new.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Existing transaction", selection: $replacing) {
                        Text("None (add as new)").tag(Transaction?.none)
                        ForEach(candidates) { t in
                            Text("\(t.pending ? "⏳ " : "")\(t.date) · \(t.title) · \(Format.euro(t.total))").tag(Optional(t))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    if replaceMismatch, let r = replacing {
                        Text("Items must sum to \(Format.euro(r.total)).").foregroundStyle(.red)
                    }
                }
                if replacing == nil, let tap = matchedTap {
                    Label("Fills in the card tap at \(Format.hhmm(tap.date))\(tap.merchant.isEmpty ? "" : " · \(tap.merchant)")",
                          systemImage: "clock.badge.checkmark")
                        .foregroundStyle(.green)
                }
            } header: {
                Text("Replace existing")
            } footer: {
                Text("Pick the matching card payment or expense so this receipt itemizes it instead of adding a duplicate.")
            }
            .onChange(of: replacing) { _, r in
                if let r { adopt(r) }
            }
        }
    }

    private var imageSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array((job?.images ?? []).enumerated()), id: \.offset) { _, img in
                        Image(uiImage: img).resizable().scaledToFit()
                    }
                }
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showImage = false } } }
        }
    }

    private func binding(_ id: UUID) -> Binding<ReceiptItem> {
        Binding(
            get: { items.first { $0.id == id } ?? ReceiptItem(name: "", amount: 0, category: .basic) },
            set: { v in if let i = items.firstIndex(where: { $0.id == id }) { items[i] = v } }
        )
    }

    // MARK: Actions

    private func start() async {
        guard !started else { return }
        started = true
        account = app.defaultAccount
        if let t = target {
            replacing = t
            adopt(t)
        }
        if job == nil {
            // Allocate: start from the transaction's receipt lines, or one item per row.
            if let t = target {
                items = t.isItemized ? t.receiptItems
                    : t.rows.map { ReceiptItem(name: t.title, amount: $0.amount, category: $0.token ?? .basic) }
            }
            phase = .review
        } else {
            if app.transactions.isEmpty { await app.loadData() }
            await runScan()
        }
    }

    /// Takes date, description and account from the transaction being replaced.
    private func adopt(_ t: Transaction) {
        if let d = Format.day.date(from: t.date) { date = d }
        description = t.title
        if let a = t.account.flatMap(Account.init(rawValue:)) { account = a }
    }

    private func runScan() async {
        guard scan == nil, let job, let claude = app.claude else { return }
        error = nil
        do {
            var receipts = try await claude.scan(images: job.images)
            // When scanning for a specific transaction, review the receipt that matches it first.
            if let t = target, let i = receipts.firstIndex(where: { abs($0.total - t.total) < 0.011 }), i > 0 {
                receipts.insert(receipts.remove(at: i), at: 0)
            }
            queue = receipts
            show(0)
        } catch let e as ClaudeClient.ClaudeError where e.isAuth {
            app.saveAnthropicKey(nil)
            error = "Anthropic API key was rejected. Enter a new one in Settings."
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Loads receipt `i` of the queue into the form. Only the first one replaces `target`.
    private func show(_ i: Int) {
        position = i
        let r = queue[i]
        scan = r
        items = r.items
        error = nil
        if i == 0, let t = target {
            replacing = t
            adopt(t)
        } else {
            replacing = nil
            account = app.defaultAccount
            description = r.merchant ?? "Receipt"
            if let d = r.date.flatMap({ Format.day.date(from: $0) }) { date = d } else { date = Date() }
            autoMatch(r)
        }
        phase = .review
    }

    /// Assigns the receipt to the pending card payment it most likely is: same total, same day ±1,
    /// closest paid time when both times are known. Failing that, to a card tap still waiting for
    /// Wallet details from within 30 min of the receipt's time.
    private func autoMatch(_ r: ReceiptScan) {
        matchedTap = nil
        let day = r.date ?? Format.day.string(from: Date())
        let receiptMinutes = Format.minutes(r.time)
        func distance(_ t: Transaction) -> Int? {
            let days = Self.dayDistance(t.date, day)
            guard abs(t.total - r.total) < 0.011, days <= 1 else { return nil }
            if days == 0, let a = receiptMinutes, let b = Format.minutes(t.time) {
                return abs(a - b) <= 120 ? abs(a - b) : nil
            }
            return 200 + days * 1440 // no times to compare: after any time match, nearest day first
        }
        if let best = app.pending.compactMap({ t in distance(t).map { (t, $0) } }).min(by: { $0.1 < $1.1 })?.0 {
            replacing = best
            adopt(best)
            return
        }
        matchedTap = app.cardTaps
            .filter { tap in
                guard tap.day == day else { return false }
                if let a = tap.amount, abs(a - r.total) > 0.011 { return false }
                if let m = receiptMinutes { return abs(m - (Format.minutes(Format.hhmm(tap.date)) ?? -999)) <= 30 }
                return tap.amount != nil // no receipt time: only a tap that knows the amount
            }
            .min { a, b in
                let m = receiptMinutes ?? 0
                return abs(m - (Format.minutes(Format.hhmm(a.date)) ?? 0)) < abs(m - (Format.minutes(Format.hhmm(b.date)) ?? 0))
            }
    }

    /// Next receipt in the queue, or the done screen.
    private func advance() {
        if position + 1 < queue.count {
            show(position + 1)
        } else {
            finish()
        }
    }

    /// Back to Home; it shows the old Consumption briefly, then animates in what was just added.
    private func finish() {
        onDone()
        if savedAny {
            Task { await app.loadData(week: .after(.seconds(2.4))) }
        }
    }

    /// Row label for a category's expense: the item's name if it's alone, else the category.
    private func label(for items: [ReceiptItem], category: ReceiptCategory) -> String {
        if storesItems, items.count == 1, !items[0].name.trimmingCharacters(in: .whitespaces).isEmpty {
            return items[0].name.trimmingCharacters(in: .whitespaces).lowercased()
        }
        return category.label.lowercased()
    }

    private func save() async {
        guard canSave, let store = app.store else { return }
        phase = .saving
        error = nil
        let desc = description.trimmingCharacters(in: .whitespaces).isEmpty ? "Receipt" : description.trimmingCharacters(in: .whitespaces)
        let created = Format.isoMillis.string(from: Date())
        let groups = self.groups
        let txId = "tx" + Format.newExpenseId()
        let entries: [JSONValue] = groups.map { g in
            ExpenseEntry.make(amount: g.total, date: dateString,
                              description: desc + (groups.count > 1 ? " · " + label(for: g.items, category: g.category) : ""),
                              category: g.category, account: account, created: created,
                              time: scan?.time ?? replacing?.time, txId: txId, items: storesItems ? g.items : [])
        }
        do {
            try await store.commit(newEntries: entries, replacingIds: replacing?.rowIds ?? [],
                                   message: "\(job != nil ? "Receipt" : "Allocate") \(desc) \(dateString) (iOS)")
            if job != nil { ItemRules.learn(from: items) }
            if replacing == nil, let tap = matchedTap { app.clearTaps([tap.id]) }
            savedAny = true
            if job != nil && position + 1 < queue.count {
                await app.loadData(week: .keep) // refresh candidates for the next receipt
                advance()
            } else {
                finish()
            }
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

private struct ItemRow: View {
    @Binding var item: ReceiptItem

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("Category", selection: $item.category) {
                    ForEach(ReceiptCategory.allCases) { c in
                        Label(c.label, systemImage: c.symbol).tag(c)
                    }
                }
            } label: {
                Image(systemName: item.category.symbol)
                    .frame(width: 32, height: 28)
                    .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 1) {
                TextField("Item", text: $item.name)
                    .font(.subheadline)
                if item.learned {
                    Label("learned", systemImage: "sparkles")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            TextField("0.00", value: $item.amount, format: .number.precision(.fractionLength(2)))
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 72)
        }
    }
}
