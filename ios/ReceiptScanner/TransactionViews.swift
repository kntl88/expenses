import SwiftUI

struct TransactionRow: View {
    let tx: Transaction

    private var icon: (name: String, color: Color) {
        if tx.pending { return ("hourglass", .orange) }
        if tx.isItemized { return ("list.bullet.rectangle", .secondary) }
        return ("creditcard", .secondary)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon.name)
                .foregroundStyle(icon.color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(tx.title).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(Format.euro(tx.total)).monospacedDigit()
        }
    }

    private var subtitle: String {
        var parts = [tx.date, tx.pending ? "\(tx.categorySummary)?" : tx.categorySummary]
        if tx.isItemized { parts.append("\(tx.itemCount) item\(tx.itemCount == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

/// A transaction with its receipt lines grouped by category, plus actions: scan a receipt to
/// itemize it, allocate/re-split it by hand, and (for pending card payments) confirm or delete.
struct TransactionDetailView: View {
    @Environment(AppState.self) private var app
    let tx: Transaction
    var onScan: () -> Void
    var onAllocate: () -> Void
    var onDone: () -> Void

    @State private var busy = false
    @State private var error: String?
    @State private var confirmDelete = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tx.title).font(.title3.weight(.semibold))
                    Text([tx.date, tx.account.flatMap(Account.init(rawValue:))?.label].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                    Text(Format.euro(tx.total)).font(.title2.monospacedDigit())
                    if tx.pending {
                        Label("Waiting for receipt or allocation", systemImage: "hourglass")
                            .font(.subheadline).foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 4)
            }

            ForEach(tx.rows, id: \.id) { row in
                Section {
                    if row.items.isEmpty {
                        Text(tx.pending ? "Guessed from the merchant" : "No receipt lines")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(row.items.enumerated()), id: \.offset) { _, item in
                        HStack {
                            Text(item.name)
                            Spacer()
                            Text(Format.euro(item.amount)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    HStack {
                        if let t = row.token { Label(row.label, systemImage: t.symbol) } else { Text(row.label) }
                        Spacer()
                        Text(Format.euro(row.amount)).monospacedDigit()
                    }
                }
            }

            Section {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button { onScan() } label: {
                        Label(tx.isItemized ? "Rescan receipt" : "Scan receipt", systemImage: "camera")
                    }
                }
                Button { onAllocate() } label: {
                    Label(tx.pending ? "Allocate without receipt" : "Edit split", systemImage: "square.split.2x1")
                }
                if tx.pending {
                    Button { run { try await app.confirm(tx) } } label: {
                        Label("Confirm as \(tx.categorySummary)", systemImage: "checkmark")
                    }
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Delete payment", systemImage: "trash")
                    }
                }
            } footer: {
                if let error { Text(error).foregroundStyle(.red) }
            }
            .disabled(busy)
        }
        .navigationTitle(tx.pending ? "Pending" : "Transaction")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete this payment?", isPresented: $confirmDelete) {
            Button("Delete \(tx.title) · \(Format.euro(tx.total))", role: .destructive) {
                run { try await app.delete(tx) }
            }
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        Task {
            busy = true
            error = nil
            do {
                try await action()
                onDone()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
