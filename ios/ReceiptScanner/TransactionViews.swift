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

/// A transaction row that expands in place (tap) to show its receipt lines grouped by category,
/// with actions to scan a receipt, re-split it, or confirm a pending payment.
struct ExpandableTransaction: View {
    let tx: Transaction
    let expanded: Bool
    var onToggle: () -> Void
    var onScan: () -> Void
    var onAllocate: () -> Void
    var onConfirm: () -> Void
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TransactionRow(tx: tx)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(tx.rows, id: \.id) { row in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                if let t = row.token {
                                    Label(row.label, systemImage: t.symbol)
                                } else {
                                    Text(row.label)
                                }
                                Spacer()
                                Text(Format.euro(row.amount)).monospacedDigit()
                            }
                            .font(.subheadline.weight(.medium))
                            if row.items.isEmpty {
                                Text(tx.pending ? "Guessed from the merchant" : "No receipt lines")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .padding(.leading, 28)
                            }
                            ForEach(Array(row.items.enumerated()), id: \.offset) { _, item in
                                HStack {
                                    Text(item.name).lineLimit(1)
                                    Spacer()
                                    Text(Format.euro(item.amount)).monospacedDigit()
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 28)
                            }
                        }
                    }

                    HStack(spacing: 6) {
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            actionButton(tx.isItemized ? "Rescan" : "Receipt", "camera", action: onScan)
                        }
                        actionButton(tx.pending ? "Allocate" : "Edit split", "square.split.2x1", action: onAllocate)
                        if tx.pending {
                            actionButton("Confirm", "checkmark", action: onConfirm)
                        } else {
                            // Pending rows delete by swiping; their three buttons leave no room here.
                            Button(role: .destructive, action: onDelete) {
                                Label("Delete", systemImage: "trash")
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(.top, 2)
                }
                .padding(.leading, 36)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func actionButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .fixedSize()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
