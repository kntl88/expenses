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
    case detail(Transaction)
}

struct HomeView: View {
    @Environment(AppState.self) private var app
    @State private var path: [Route] = []
    @State private var showScanner = false
    @State private var scanTarget: Transaction?
    @State private var showSettings = false
    @State private var confirmDelete: Transaction?
    @State private var actionError: String?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    WeekSummaryView(summary: app.week, error: app.weekError)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 6, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)

                    CardButton(title: "Scan receipt", systemImage: "camera") { scan(for: nil) }
                        .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 6, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)

                    CardButton(title: "Settings", systemImage: "gearshape", tint: WebStyle.dim) { showSettings = true }
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                if app.outboxCount > 0 {
                    Section {
                        Label("\(app.outboxCount) card payment\(app.outboxCount == 1 ? "" : "s") waiting to sync",
                              systemImage: "icloud.slash")
                            .foregroundStyle(.orange)
                    }
                }

                if let actionError {
                    Section { Text(actionError).foregroundStyle(.red) }
                }

                if !app.pending.isEmpty {
                    Section {
                        ForEach(app.pending) { tx in
                            NavigationLink(value: Route.detail(tx)) { TransactionRow(tx: tx) }
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
                        Text("Card payments waiting for a receipt or allocation. Swipe right to confirm the category, left to scan the receipt.")
                    }
                }

                Section("Transactions") {
                    if app.recent.isEmpty {
                        Text("No transactions yet.").foregroundStyle(.secondary)
                    }
                    ForEach(app.recent) { tx in
                        NavigationLink(value: Route.detail(tx)) { TransactionRow(tx: tx) }
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
                case let .detail(tx):
                    TransactionDetailView(tx: tx,
                                          onScan: { scan(for: tx) },
                                          onAllocate: { path.append(.review(nil, tx)) },
                                          onDone: { path.removeAll() })
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
            .confirmationDialog("Delete this payment?", isPresented: Binding(
                get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }
            ), presenting: confirmDelete) { tx in
                Button("Delete \(tx.title) · \(Format.euro(tx.total))", role: .destructive) {
                    run { try await app.delete(tx) }
                }
            }
            .refreshable { await app.loadData() }
            .task { await app.loadData() }
        }
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
