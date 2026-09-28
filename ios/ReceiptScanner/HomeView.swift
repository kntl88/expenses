import PhotosUI
import SwiftUI
import VisionKit

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
    @State private var photoItem: PhotosPickerItem?
    @State private var loadError: String?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    VStack(spacing: 12) {
                        Button {
                            showScanner = true
                        } label: {
                            Label("Scan receipt", systemImage: "doc.viewfinder")
                                .font(.title3.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 56)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!VNDocumentCameraViewController.isSupported)

                        PhotosPicker(selection: $photoItem, matching: .images) {
                            Label("Choose from Photos", systemImage: "photo.on.rectangle")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                    }
                    .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
                    .listRowBackground(Color.clear)
                }

                if let loadError {
                    Section { Text(loadError).foregroundStyle(.red) }
                }

                Section("Recently added") {
                    if app.recent.isEmpty {
                        Text("Nothing yet. Scanned receipts show up here after saving.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(app.recent) { r in
                        HStack {
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
                DocumentScanner { images in
                    showScanner = false
                    if !images.isEmpty { path.append(ScanJob(images: images)) }
                } onCancel: {
                    showScanner = false
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                photoItem = nil
                Task {
                    loadError = nil
                    if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                        path.append(ScanJob(images: [img]))
                    } else {
                        loadError = "Couldn't load that photo."
                    }
                }
            }
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
