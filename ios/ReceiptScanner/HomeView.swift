import SwiftUI

final class ScanJob: Identifiable, Hashable {
    let id = UUID()
    let images: [UIImage]
    init(images: [UIImage]) { self.images = images }
    static func == (a: ScanJob, b: ScanJob) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct HomeView: View {
    @Environment(AppState.self) private var app
    @State private var path: [ScanJob] = []
    @State private var showScanner = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    WeekSummaryView(summary: app.week, error: app.weekError)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 0, trailing: 16))
                        .listRowBackground(Color.clear)
                }

                Section {
                    VStack(spacing: 12) {
                        Button {
                            showScanner = true
                        } label: {
                            Label("Scan receipt", systemImage: "camera")
                                .font(.title3.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 56)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                }

                if app.outboxCount > 0 {
                    Section {
                        Label("\(app.outboxCount) card payment\(app.outboxCount == 1 ? "" : "s") waiting to sync",
                              systemImage: "icloud.slash")
                            .foregroundStyle(.orange)
                    }
                }

                Section("Recently added") {
                    if app.recent.isEmpty {
                        Text("Nothing yet. Scanned receipts show up here after saving.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(app.recent) { r in
                        HStack {
                            Image(systemName: r.viaCard == true ? "creditcard" : "doc.text.viewfinder")
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.description).lineLimit(1)
                                Text("\(r.date) · \(r.categories.joined(separator: ", "))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(Format.euro(r.total)).monospacedDigit()
                        }
                    }
                }
            }
            .navigationTitle("Receipts")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .navigationDestination(for: ScanJob.self) { job in
                ReviewView(job: job) { path.removeAll() }
            }
            .fullScreenCover(isPresented: $showScanner) {
                CameraPicker { image in
                    showScanner = false
                    path.append(ScanJob(images: [image]))
                } onCancel: {
                    showScanner = false
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .refreshable { await app.loadWeek() }
            .task { await app.loadWeek() }
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
