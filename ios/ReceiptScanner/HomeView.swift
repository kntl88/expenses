import SwiftUI

final class ScanJob: Identifiable, Hashable {
    let id = UUID()
    let images: [UIImage]
    init(images: [UIImage]) { self.images = images }
    static func == (a: ScanJob, b: ScanJob) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

enum Route: Hashable {
    case review(ScanJob?, Transaction?)
    case walletImport(ScanJob)
}

struct HomeView: View {
    @Environment(AppState.self) private var app
    @State private var path: [Route] = []
    @State private var showScanner = false
    @State private var scanTarget: Transaction?
    @State private var showSettings = false
    @State private var confirmDelete: Transaction?
    @State private var actionError: String?
    @State private var expanded: Set<String> = []
    enum Page { case home, score }
    @State private var page: Page = .home
    @State private var editingBalance: AppState.Balance?
    @State private var balanceText = ""

    var body: some View {
        // Read here so List rows redraw when it changes (rows don't track it on their own).
        let vanishing = app.vanishing
        return NavigationStack(path: $path) {
            List {
                Section {
                    HStack(spacing: 6) {
                        NavButton(title: "Home", systemImage: "house", selected: page == .home) { page = .home }
                        NavButton(title: "Score", systemImage: "gauge.with.needle", selected: page == .score) { page = .score }
                        Spacer(minLength: 0)
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 6, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                if page == .score {
                    Section {
                        ScoreView(summary: app.week)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 6, trailing: 0))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                } else {
                Section {
                    if !app.balances.isEmpty {
                        BalancesView(balances: app.balances) { b in
                            balanceText = String(format: "%.2f", b.value)
                            editingBalance = b
                        }
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 6, trailing: 0))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }

                    WeekSummaryView(summary: app.week, error: app.weekError)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 6, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)

                    CardButton(title: "Scan receipt", systemImage: "camera") { scan(for: nil) }
                        .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 6, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)

                    // The bank app shows card payments immediately (Wallet lags 30–60 min); triple-tap there to import.
                    CardButton(title: "Open Bank Norwegian", systemImage: "building.columns", tint: WebStyle.dim) {
                        openBank()
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 6, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                    CardButton(title: "Settings", systemImage: "gearshape", tint: WebStyle.dim) { showSettings = true }
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                if let actionError {
                    Section { Text(actionError).foregroundStyle(.red) }
                }

                if !app.cardTaps.isEmpty {
                    Section {
                        ForEach(app.cardTaps) { tap in
                            Button { openBank() } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "clock.badge.questionmark")
                                        .foregroundStyle(.orange)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(tap.merchant.isEmpty ? "Card payment" : tap.merchant).lineLimit(1)
                                        Text(tap.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(tap.amount.map(Format.euro) ?? "—").monospacedDigit()
                                        .foregroundStyle(tap.amount == nil ? .secondary : .primary)
                                }
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { app.clearTaps([tap.id]) } label: {
                                    Label("Dismiss", systemImage: "xmark")
                                }
                            }
                        }
                    } header: {
                        Text("Waiting for details · \(app.cardTaps.count)")
                    } footer: {
                        Text("Card taps from the automation. Tap to open Bank Norwegian, then triple-tap to import. Swipe to dismiss.")
                    }
                }

                if !app.pending.isEmpty {
                    Section {
                        ForEach(app.pending) { tx in
                            expandable(tx, vanish: vanishing[tx.id])
                                .swipeActions(edge: .leading) {
                                    Button { run { try await app.confirm(tx) } } label: {
                                        Label("Confirm", systemImage: "checkmark")
                                    }
                                    .tint(.green)
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) { confirmDelete = tx } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    Button { scan(for: tx) } label: {
                                        Label("Receipt", systemImage: "camera")
                                    }
                                    .tint(.blue)
                                }
                        }
                    } header: {
                        Text("Pending · \(app.pending.count)")
                    } footer: {
                        Text("Card payments waiting for a receipt or allocation. Tap to see details, swipe right to confirm the category, left to scan the receipt.")
                    }
                }

                Section("Transactions") {
                    if app.recent.isEmpty {
                        Text("No transactions yet.").foregroundStyle(.secondary)
                    }
                    ForEach(app.recent) { tx in
                        expandable(tx, vanish: vanishing[tx.id])
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { confirmDelete = tx } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
                }
            }
            .contentMargins(.horizontal, 0, for: .scrollContent)
            .navigationTitle("")
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case let .review(job, target):
                    ReviewView(job: job, target: target) { path.removeAll() }
                case let .walletImport(job):
                    WalletImportView(job: job) { path.removeAll() }
                }
            }
            .fullScreenCover(isPresented: $showScanner) {
                CameraPicker { image in
                    showScanner = false
                    path.append(.review(ScanJob(images: [image]), scanTarget))
                } onCancel: {
                    showScanner = false
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .alert(editingBalance.map { "\($0.label) balance" } ?? "", isPresented: Binding(
                get: { editingBalance != nil }, set: { if !$0 { editingBalance = nil } }
            ), presenting: editingBalance) { b in
                TextField("Actual balance", text: $balanceText)
                    .keyboardType(.numbersAndPunctuation)
                Button("Set") {
                    let v = Double(balanceText.replacingOccurrences(of: ",", with: ".").filter { "-0123456789.".contains($0) })
                    if let v { app.setBalance(b.key, actual: v) }
                }
                if b.manualOffset != nil {
                    Button("Use calculated (\(String(format: "€%.2f", b.computed)))", role: .destructive) {
                        app.setBalance(b.key, actual: nil)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Temporary, on this phone only, until the missing expenses are added. Later payments still move it.")
            }
            .confirmationDialog("Delete this transaction?", isPresented: Binding(
                get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }
            ), presenting: confirmDelete) { tx in
                Button("Delete \(tx.title) · \(Format.euro(tx.total))", role: .destructive) {
                    run { try await app.delete(tx) }
                }
            } message: { tx in
                Text(tx.rows.count > 1 ? "Removes all \(tx.rows.count) category rows of this receipt from expenses."
                                       : "Removes it from expenses.")
            }
            .refreshable { await app.loadData() }
            .onReceive(NotificationCenter.default.publisher(for: ScanRequest.notification)) { _ in
                handleScanRequest()
            }
            .onReceive(NotificationCenter.default.publisher(for: WalletImport.notification)) { _ in
                handleWalletImport()
            }
            .task {
                handleScanRequest()
                handleWalletImport()
                await app.loadData()
                // Debug layout check: `-demo -expand` opens every row.
                if AppState.demo, ProcessInfo.processInfo.arguments.contains("-expand") {
                    expanded = Set(app.transactions.map(\.id))
                }
                #if DEBUG
                if AppState.demo, ProcessInfo.processInfo.arguments.contains("-score") { page = .score }
                if AppState.demo, ProcessInfo.processInfo.arguments.contains("-settle") { await app.demoSettle() }
                if AppState.demo, ProcessInfo.processInfo.arguments.contains("-review") {
                    path = [.review(ScanJob(images: [UIImage(systemName: "doc.text")!]), nil)]
                }
                #endif
            }
        }
    }

    private func expandable(_ tx: Transaction, vanish: AppState.Vanish?) -> some View {
        ExpandableTransaction(
            tx: tx,
            expanded: expanded.contains(tx.id),
            onToggle: {
                withAnimation(.snappy) {
                    if expanded.contains(tx.id) { expanded.remove(tx.id) } else { expanded.insert(tx.id) }
                }
            },
            onScan: { scan(for: tx) },
            onAllocate: { path.append(.review(nil, tx)) },
            onConfirm: { run { try await app.confirm(tx) } },
            onDelete: { confirmDelete = tx })
            .modifier(VanishEffect(phase: vanish))
            .listRowBackground(vanish == nil ? nil : Color.green.opacity(0.18))
    }

    /// Runs the user's "Open Norwegian" shortcut (Open App → Bank Norwegian); apps can't open
    /// another app without a link it supports.
    private func openBank() {
        UIApplication.shared.open(URL(string: "shortcuts://run-shortcut?name=Open%20Norwegian")!)
    }

    /// From the lock-screen control / Scan Receipt intent.
    private func handleScanRequest() {
        guard ScanRequest.take(), UIImagePickerController.isSourceTypeAvailable(.camera) else { return }
        showSettings = false
        scan(for: nil)
    }

    /// From the Import Wallet Screenshot intent (Back Tap shortcut).
    private func handleWalletImport() {
        guard let image = WalletImport.take() else { return }
        showSettings = false
        showScanner = false
        path = [.walletImport(ScanJob(images: [image]))]
    }

    /// Opens the camera; the photo goes to review, replacing `target` if given.
    private func scan(for target: Transaction?) {
        scanTarget = target
        showScanner = true
    }

    private func run(_ action: @escaping () async throws -> Void) {
        Task {
            actionError = nil
            do { try await action() } catch { actionError = error.localizedDescription }
        }
    }
}

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            Form {
                Section("Defaults") {
                    Picker("Account", selection: $app.defaultAccount) {
                        ForEach(Account.allCases) { Text($0.label).tag($0) }
                    }
                }
                Section("Connection") {
                    LabeledContent("Data repo", value: "\(Vault.owner)/\(app.repo ?? "—")")
                    LabeledContent("Model", value: ClaudeClient.model)
                    NavigationLink("Change PIN unlock / API key") { SetupView(pushed: true) }
                }
                Section {
                    NavigationLink("Learned items") { LearnedItemsView() }
                } footer: {
                    Text("Items you've put in a category other than Basic on past receipts.")
                }
                Section {
                    Button("Sign out", role: .destructive) {
                        app.signOut()
                        dismiss()
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

struct LearnedItemsView: View {
    @State private var rules: [(key: String, rule: ItemRules.Rule)] = []

    var body: some View {
        List {
            if rules.isEmpty {
                Text("Nothing learned yet. Move an item out of Basic on a receipt and save it.")
                    .foregroundStyle(.secondary)
            }
            ForEach(rules, id: \.key) { entry in
                HStack {
                    Text(entry.rule.name)
                    Spacer()
                    Text(ReceiptCategory(rawValue: entry.rule.category)?.label ?? entry.rule.category)
                        .foregroundStyle(.secondary)
                }
            }
            .onDelete { offsets in
                offsets.map { rules[$0].key }.forEach(ItemRules.remove)
                reload()
            }
        }
        .navigationTitle("Learned items")
        .onAppear(perform: reload)
    }

    private func reload() {
        rules = ItemRules.all().map { ($0.key, $0.value) }.sorted { $0.rule.name.localizedCaseInsensitiveCompare($1.rule.name) == .orderedAscending }
    }
}

/// Full-width button in the Consumption card's style (dark surface, border, monospaced caps).
struct CardButton: View {
    let title: String
    let systemImage: String
    var tint: Color = WebStyle.accent
    var action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage).font(.system(size: 13, weight: .light))
                Text(title.uppercased()).font(.system(size: 11, weight: .regular, design: .monospaced)).tracking(0.5)
            }
            .foregroundStyle(isEnabled ? tint : WebStyle.muted)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(WebStyle.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(WebStyle.border))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

/// Compact page switch at the top: same height and style as CardButton, sized to its title.
struct NavButton: View {
    let title: String
    let systemImage: String
    let selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 12, weight: .light))
                Text(title.uppercased()).font(.system(size: 11, weight: .regular, design: .monospaced)).tracking(0.5)
            }
            .foregroundStyle(selected ? WebStyle.accent : WebStyle.dim)
            .padding(.horizontal, 16)
            .frame(minHeight: 40)
            .background(selected ? WebStyle.surface2 : WebStyle.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? WebStyle.accentDim : WebStyle.border))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

/// A settled pending payment's exit: swells with a bouncing green checkmark, then flies off.
private struct VanishEffect: ViewModifier {
    let phase: AppState.Vanish?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .leading) {
                if phase != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white, .green)
                        .background(Circle().fill(Color(.systemBackground)).padding(2))
                        .offset(x: -3)
                        .transition(.scale(scale: 0.2).combined(with: .opacity))
                }
            }
            .scaleEffect(phase == .pop ? 1.08 : 1, anchor: .leading)
            .rotationEffect(.degrees(phase == .fly ? 6 : 0))
            .offset(x: phase == .fly ? 600 : 0)
            .opacity(phase == .fly ? 0 : 1)
    }
}
