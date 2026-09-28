import SwiftUI

/// Sends the receipt to Claude, lets the user adjust the split, then writes the expense rows —
/// the same flow as applyReceiptSplit in index.html.
struct ReviewView: View {
    @Environment(AppState.self) private var app
    let job: ScanJob
    var onDone: () -> Void

    enum Phase { case scanning, review, saving, saved }
    @State private var phase: Phase = .scanning
    @State private var error: String?

    @State private var scan: ReceiptScan?
    @State private var parts: [ReceiptPart] = []
    @State private var description = ""
    @State private var date = Date()
    @State private var account: Account = .norwegian

    @State private var existing: [ExistingExpense] = []
    @State private var existingLoadError: String?
    @State private var replacing: ExistingExpense?
    @State private var showImage = false

    private var sum: Double { Format.round2(parts.reduce(0) { $0 + $1.amount }) }
    private var dateString: String { Format.day.string(from: date) }

    /// Expenses that could be this same purchase (e.g. already imported from the card statement):
    /// same amount, within ±10 days. Norwegian booking dates can lag the purchase, so match by amount.
    private var candidates: [ExistingExpense] {
        guard !parts.isEmpty else { return [] }
        let targets = [sum, scan?.total ?? sum]
        return existing
            .filter { e in
                e.amount < 0 && targets.contains { abs(abs(e.amount) - $0) < 0.011 }
                    && Self.dayDistance(e.date, dateString) <= 10
            }
            .sorted { Self.dayDistance($0.date, dateString) < Self.dayDistance($1.date, dateString) }
    }

    private var replaceMismatch: Bool {
        guard let r = replacing else { return false }
        return abs(abs(r.amount) - sum) > 0.01
    }

    private var canSave: Bool {
        phase == .review && !parts.isEmpty && parts.allSatisfy { $0.amount > 0 } && !replaceMismatch
    }

    var body: some View {
        Group {
            switch phase {
            case .scanning: scanningView
            case .review, .saving: reviewForm
            case .saved: savedView
            }
        }
        .navigationTitle("Receipt")
        .navigationBarTitleDisplayMode(.inline)
        .task { await runScan() }
        .sheet(isPresented: $showImage) { imageSheet }
    }

    // MARK: Phases

    private var scanningView: some View {
        VStack(spacing: 20) {
            if let first = job.images.first {
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

    private var savedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(.green)
            Text("Added to expenses").font(.title2.weight(.semibold))
            Text("\(parts.count) \(parts.count == 1 ? "entry" : "entries") · \(Format.euro(sum))")
                .foregroundStyle(.secondary)
            Button("Done", action: onDone).buttonStyle(.borderedProminent).padding(.top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var reviewForm: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    if let first = job.images.first {
                        Button { showImage = true } label: {
                            Image(uiImage: first).resizable().scaledToFill()
                                .frame(width: 56, height: 72).clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                    VStack(alignment: .leading) {
                        Text(scan?.merchant ?? "Unknown merchant").font(.headline)
                        if let total = scan?.total {
                            Text("Receipt total \(Format.euro(total))").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Details") {
                TextField("Description", text: $description)
                DatePicker("Date", selection: $date, displayedComponents: .date)
                Picker("Account", selection: $account) {
                    ForEach(Account.allCases.filter { $0 != .work }) { Text($0.label).tag($0) }
                }
            }

            Section {
                ForEach($parts) { $part in
                    PartRow(part: $part)
                }
                .onDelete { parts.remove(atOffsets: $0) }
                Button {
                    let remaining = Format.round2((replacing.map { abs($0.amount) } ?? scan?.total ?? 0) - sum)
                    parts.append(ReceiptPart(category: .basic, amount: max(remaining, 0), label: ""))
                } label: {
                    Label("Add part", systemImage: "plus.circle")
                }
            } header: {
                Text("Split")
            } footer: {
                totalsFooter
            }

            replaceSection

            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    HStack {
                        Spacer()
                        if phase == .saving { ProgressView() } else {
                            Text(replacing == nil ? "Add \(parts.count) \(parts.count == 1 ? "expense" : "expenses")" : "Replace with split")
                                .fontWeight(.semibold)
                        }
                        Spacer()
                    }
                }
                .disabled(!canSave)
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var totalsFooter: some View {
        let total = replacing.map { abs($0.amount) } ?? scan?.total
        return HStack {
            Text("Sum \(Format.euro(sum))")
            if let total, abs(total - sum) > 0.01 {
                Text("≠ \(Format.euro(total))").foregroundStyle(.orange)
            }
        }
        .monospacedDigit()
    }

    @ViewBuilder private var replaceSection: some View {
        Section {
            if let existingLoadError {
                Text(existingLoadError).foregroundStyle(.secondary)
            } else if candidates.isEmpty && replacing == nil {
                Text("No existing expense with this amount nearby — will add as new.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Existing expense", selection: $replacing) {
                    Text("None (add as new)").tag(ExistingExpense?.none)
                    ForEach(candidates) { e in
                        Text("\(e.date) · \(e.description) · \(Format.euro(abs(e.amount)))").tag(Optional(e))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                if replaceMismatch {
                    Text("Parts must sum to \(Format.euro(abs(replacing!.amount))).").foregroundStyle(.red)
                }
            }
        } header: {
            Text("Replace existing")
        } footer: {
            Text("Pick a matching expense (e.g. from the card statement) to split it by this receipt instead of adding a duplicate.")
        }
        .onChange(of: replacing) { _, r in
            guard let r else { return }
            if let d = Format.day.date(from: r.date) { date = d }
            if !r.description.isEmpty { description = r.description }
            if let a = r.account.flatMap(Account.init(rawValue:)) { account = a }
        }
    }

    private var imageSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array(job.images.enumerated()), id: \.offset) { _, img in
                        Image(uiImage: img).resizable().scaledToFit()
                    }
                }
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showImage = false } } }
        }
    }

    // MARK: Actions

    private func runScan() async {
        guard scan == nil, let claude = app.claude else { return }
        error = nil
        account = app.defaultAccount
        async let existingTask: Void = loadExisting()
        do {
            let result = try await claude.scan(images: job.images)
            scan = result
            parts = result.parts
            description = result.merchant ?? "Receipt"
            if let d = result.date.flatMap({ Format.day.date(from: $0) }) { date = d }
            phase = .review
        } catch let e as ClaudeClient.ClaudeError where e.isAuth {
            app.saveAnthropicKey(nil)
            error = "Anthropic API key was rejected. Enter a new one in Settings."
        } catch {
            self.error = error.localizedDescription
        }
        await existingTask
    }

    private func loadExisting() async {
        guard let store = app.store else { return }
        do {
            existing = GitHubStore.existing(from: try await store.load().expenses)
        } catch {
            existingLoadError = "Couldn't check existing expenses: \(error.localizedDescription)"
        }
    }

    private func save() async {
        guard canSave, let store = app.store else { return }
        phase = .saving
        error = nil
        let desc = description.trimmingCharacters(in: .whitespaces).isEmpty ? "Receipt" : description.trimmingCharacters(in: .whitespaces)
        let created = Format.isoMillis.string(from: Date())
        let entries: [JSONValue] = parts.map { p in
            let m = p.category.stored
            let label = p.label.trimmingCharacters(in: .whitespaces)
            var fields: [(String, JSONValue)] = [
                ("id", .string(Format.newExpenseId())),
                ("amount", .num(-abs(Format.round2(p.amount)))),
                ("date", .string(dateString)),
                ("description", .string(desc + (!label.isEmpty && parts.count > 1 ? " · " + label : ""))),
                ("category", .string(m.category)),
                ("type", .string("expense")),
            ]
            if let sub = m.subCategory { fields.append(("subCategory", .string(sub))) }
            fields.append(("account", .string(account.rawValue)))
            fields.append(("created", .string(created)))
            return .object(fields)
        }
        do {
            try await store.commit(newEntries: entries, replacingId: replacing?.id,
                                   message: "Add receipt \(desc) \(dateString) (iOS)")
            app.addRecent(.init(date: dateString, description: desc, total: sum,
                                categories: parts.map(\.category.label), savedAt: Date()))
            phase = .saved
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

private struct PartRow: View {
    @Binding var part: ReceiptPart

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("Category", selection: $part.category) {
                    ForEach(ReceiptCategory.allCases) { c in
                        Label(c.label, systemImage: c.symbol).tag(c)
                    }
                }
            } label: {
                Label(part.category.label, systemImage: part.category.symbol)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.tint.opacity(0.12), in: Capsule())
            }
            TextField("label", text: $part.label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("0.00", value: $part.amount, format: .number.precision(.fractionLength(2)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 80)
            Text("€").foregroundStyle(.secondary)
        }
    }
}
