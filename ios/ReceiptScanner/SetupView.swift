import SwiftUI

/// First-run setup: unlock the web app's vault with the PIN (gives the GitHub token + data repo),
/// and enter the Anthropic API key. Also reused from Settings.
struct SetupView: View {
    @Environment(AppState.self) private var app
    /// true when pushed from Settings (already inside a NavigationStack).
    var pushed = false

    @State private var pin = ""
    @State private var anthropicKey = ""
    @State private var manualToken = ""
    @State private var manualRepo = ""
    @State private var showManual = false
    @State private var busy = false
    @State private var error: String?
    @State private var needsRepo = false

    var body: some View {
        if pushed {
            form
        } else {
            NavigationStack { form }
        }
    }

    private var form: some View {
            Form {
                Section {
                    if app.store != nil {
                        Label("Connected to \(Vault.owner)/\(app.repo ?? "")", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    SecureField("Vault PIN", text: $pin)
                        .keyboardType(.numbersAndPunctuation)
                        .textContentType(.password)
                    if needsRepo {
                        TextField("Data repo name", text: $manualRepo)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Button {
                        Task { await unlock() }
                    } label: {
                        HStack {
                            Text(app.store == nil ? "Unlock vault" : "Re-unlock vault")
                            if busy { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(pin.isEmpty || busy)
                } header: {
                    Text("Expenses data")
                } footer: {
                    Text("Same PIN as the Expenses web app. The GitHub token is decrypted on the phone and kept in the Keychain.")
                }

                Section {
                    DisclosureGroup("Enter token manually", isExpanded: $showManual) {
                        SecureField("GitHub token", text: $manualToken)
                        TextField("Data repo name", text: $manualRepo)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Save") {
                            app.saveGitHub(token: manualToken.trimmingCharacters(in: .whitespaces),
                                           repo: manualRepo.trimmingCharacters(in: .whitespaces))
                        }
                        .disabled(manualToken.isEmpty || manualRepo.isEmpty)
                    }
                }

                Section {
                    SecureField(app.anthropicKey?.isEmpty == false ? "•••• saved (enter to replace)" : "sk-ant-…", text: $anthropicKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save API key") {
                        app.saveAnthropicKey(anthropicKey)
                        anthropicKey = ""
                    }
                    .disabled(anthropicKey.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("Anthropic API key")
                } footer: {
                    Text("Used to read and categorize receipts with Claude.")
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle(pushed ? "Connection" : "Set up")
    }

    private func unlock() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            let creds = try await Vault.unlock(pin: pin)
            let repo = creds.repo ?? (manualRepo.isEmpty ? nil : manualRepo)
            guard let repo else {
                needsRepo = true
                error = "This vault doesn't include the repo name — enter it above and unlock again."
                return
            }
            app.saveGitHub(token: creds.token, repo: repo)
            pin = ""
        } catch {
            self.error = error.localizedDescription
        }
    }
}
