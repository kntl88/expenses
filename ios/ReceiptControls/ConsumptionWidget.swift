import AppIntents
import SwiftUI
import WidgetKit

struct ConsumptionEntry: TimelineEntry {
    let date: Date
    let week: WeekSummary?
    let pending: Int
    let updated: Date?
}

struct ConsumptionProvider: TimelineProvider {
    func placeholder(in context: Context) -> ConsumptionEntry {
        ConsumptionEntry(date: Date(), week: nil, pending: 0, updated: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (ConsumptionEntry) -> Void) {
        completion(entries(from: Date(), count: 1).first ?? placeholder(in: context))
    }

    /// Now, then each of the next two midnights (Saving and Forecast depend on the day).
    func getTimeline(in context: Context, completion: @escaping (Timeline<ConsumptionEntry>) -> Void) {
        completion(Timeline(entries: entries(from: Date(), count: 3), policy: .atEnd))
    }

    private func entries(from now: Date, count: Int) -> [ConsumptionEntry] {
        let data = WidgetData.load()
        let cal = Calendar(identifier: .gregorian)
        let start = cal.startOfDay(for: now)
        return (0..<count).map { i in
            let date = i == 0 ? now : cal.date(byAdding: .day, value: i, to: start)!
            guard let data else { return ConsumptionEntry(date: date, week: nil, pending: 0, updated: nil) }
            return ConsumptionEntry(date: date,
                                    week: WeekSummary.compute(expenses: data.expenses, accounts: data.accounts, now: date),
                                    pending: pendingCount(data.expenses),
                                    updated: data.updated)
        }
    }

    /// Pending card payments (one per transaction), as listed in the app.
    private func pendingCount(_ expenses: [JSONValue]) -> Int {
        Set(expenses.compactMap { v -> String? in
            guard WeekSummary.truthy(v["pending"]), let date = v["date"]?.stringValue,
                  date >= "2026-09-28" /* Transaction.displayCutoff */ else { return nil }
            return v["txId"]?.stringValue ?? v["id"]?.stringValue
        }).count
    }
}

/// This week's Saving / Forecast (Basic+Fun+Unnec row) on the home and lock screens.
struct ConsumptionWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.kntl88.ReceiptScanner.consumption", provider: ConsumptionProvider()) { entry in
            ConsumptionWidgetView(entry: entry)
                .containerBackground(for: .widget) { WebStyle.surface }
        }
        .configurationDisplayName("Consumption")
        .description("This week's saving and forecast.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline, .accessoryCircular])
    }
}

struct ConsumptionWidgetView: View {
    let entry: ConsumptionEntry
    @Environment(\.widgetFamily) private var family

    private typealias C = WebStyle
    private func mono(_ size: CGFloat, _ weight: Font.Weight = .light) -> Font { .system(size: size, weight: weight, design: .monospaced) }
    private func fmt(_ n: Double) -> String { "€" + String(format: "%.2f", n) }
    private func signed(_ n: Double) -> String { (n >= 0 ? "+" : "") + fmt(n) }
    private func whole(_ n: Double) -> String { (n >= 0 ? "+" : "−") + String(format: "%.0f", abs(n)) }
    private func tone(_ n: Double) -> Color { n >= 0 ? C.green : C.red }

    var body: some View {
        if let week = entry.week, let row = week.rows.first {
            switch family {
            case .accessoryInline:
                Text("Saving \(signed(row.saving.total))")
            case .accessoryCircular:
                VStack(spacing: 0) {
                    Text("SAVE").font(.system(size: 9, weight: .semibold))
                    Text(whole(row.saving.total)).font(.system(size: 16, weight: .semibold)).minimumScaleFactor(0.5)
                }
                .widgetAccentable()
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 1) {
                    Text("W\(week.weekNumber) Consumption").font(.caption2.weight(.semibold)).widgetAccentable()
                    Text("Saving \(signed(row.saving.total))").font(.caption)
                    Text("Forecast \(signed(row.forecast.projected))").font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case .systemMedium:
                HStack(alignment: .top, spacing: 12) {
                    summary(week, row)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(row.leading, id: \.combo) { item in
                            HStack {
                                Text(item.cell.label.uppercased()).font(mono(9)).foregroundStyle(C.muted)
                                Spacer()
                                Text(fmt(item.cell.total)).font(mono(11)).foregroundStyle(C.total)
                            }
                        }
                        HStack {
                            Text("TOTAL").font(mono(9)).foregroundStyle(C.muted)
                            Spacer()
                            Text(fmt(row.cumulative.total)).font(mono(11)).foregroundStyle(C.total)
                        }
                        Spacer(minLength: 0)
                        Button(intent: ScanReceiptIntent()) {
                            Label("Scan", systemImage: "camera").font(.caption.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .tint(C.accent)
                    }
                }
            default:
                summary(week, row)
            }
        } else {
            VStack(spacing: 4) {
                Image(systemName: "chart.bar")
                Text("Open Receipts to load").font(.caption)
            }
            .foregroundStyle(.secondary)
        }
    }

    private func summary(_ week: WeekSummary, _ row: WeekSummary.Row) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("W\(week.weekNumber)").font(mono(10)).foregroundStyle(C.dim)
                Spacer()
                if entry.pending > 0 {
                    Label("\(entry.pending)", systemImage: "hourglass").font(mono(10, .regular)).foregroundStyle(.orange)
                }
            }
            Text("SAVING").font(mono(9)).tracking(1).foregroundStyle(C.muted).padding(.top, 2)
            Text(signed(row.saving.total)).font(mono(20, .regular)).foregroundStyle(tone(row.saving.total))
                .lineLimit(1).minimumScaleFactor(0.5)
            Text("today \(signed(row.saving.dailyNet))").font(mono(9)).foregroundStyle(tone(row.saving.dailyNet))
            Spacer(minLength: 0)
            Text("FORECAST").font(mono(9)).tracking(1).foregroundStyle(C.muted)
            Text(signed(row.forecast.projected)).font(mono(12)).foregroundStyle(tone(row.forecast.projected))
                .lineLimit(1).minimumScaleFactor(0.5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
