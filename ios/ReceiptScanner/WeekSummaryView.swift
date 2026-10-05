import SwiftUI

/// The web app's "Consumption" card (daily-rates) for the current week, same colors and layout.
struct WeekSummaryView: View {
    let summary: WeekSummary?
    let error: String?
    @State private var selected: Set<Int> = []

    private typealias C = WebStyle

    private func mono(_ size: CGFloat) -> Font { .system(size: size, weight: .light, design: .monospaced) }

    /// A single value line: never wraps mid-number, shrinks to fit the narrow cell instead.
    private func value(_ s: String, _ color: Color) -> some View {
        Text(s).font(mono(10)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.5)
            .contentTransition(.numericText())
    }

    /// fmt() in index.html: '€' + n.toFixed(2)
    private func fmt(_ n: Double) -> String { "€" + String(format: "%.2f", n) }
    private func signed(_ n: Double) -> String { (n >= 0 ? "+" : "") + fmt(n) }
    private func tone(_ n: Double) -> Color { n >= 0 ? C.green : C.red }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("CONSUMPTION").font(mono(10)).tracking(1).foregroundStyle(C.muted)
                Spacer()
                if let s = summary {
                    Text("W\(s.weekNumber) ").font(mono(10)).foregroundStyle(C.dim)
                        + Text(s.mondayLabel).font(mono(10)).foregroundStyle(C.muted)
                }
            }
            if let s = summary {
                grid(s)
                if !selected.isEmpty { chart(s.dailyBars(selected: selected)) }
            } else if let error {
                Text(error).font(mono(10)).foregroundStyle(C.red)
            } else {
                HStack { Spacer(); ProgressView().tint(C.dim); Spacer() }.frame(height: 120)
            }
        }
        .padding(14)
        .background(C.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(C.border))
        .environment(\.colorScheme, .dark)
    }

    private func grid(_ s: WeekSummary) -> some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            ForEach(Array(s.rows.enumerated()), id: \.offset) { _, row in
                GridRow(alignment: .top) {
                    ForEach(row.leading, id: \.combo) { item in
                        comboCell(item.combo, item.cell)
                            .gridCellColumns(row.leading.count == 1 ? 3 : 1)
                    }
                    item(row.cumulative.label) { values(row.cumulative) }
                    item("Saving") {
                        value(signed(row.saving.total), tone(row.saving.total))
                        (Text("+" + fmt(row.saving.dailyBudget)).foregroundColor(C.green)
                            + Text(" -" + fmt(row.saving.today)).foregroundColor(C.red)
                            + Text(" = ").foregroundColor(C.daily)
                            + Text(signed(row.saving.dailyNet)).foregroundColor(tone(row.saving.dailyNet)))
                            .font(mono(8))
                            .contentTransition(.numericText())
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    item("Forecast") {
                        value(signed(row.forecast.max), tone(row.forecast.max))
                        value(signed(row.forecast.projected), tone(row.forecast.projected))
                        value(signed(row.forecast.monthly) + "/mo", tone(row.forecast.monthly))
                    }
                }
            }
        }
    }

    private func values(_ c: WeekSummary.Cell) -> some View {
        Group {
            value(fmt(c.total), C.total)
            value(fmt(c.daily), C.daily)
        }
    }

    /// Selectable combo cell (.rate-item): tap to show the daily bar chart.
    private func comboCell(_ index: Int, _ c: WeekSummary.Cell) -> some View {
        let isSelected = selected.contains(index)
        return cellBody(c.label, filled: true) { values(c) }
            .background(isSelected ? Color(red: 196 / 255, green: 245 / 255, blue: 74 / 255).opacity(0.05) : .clear)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(isSelected ? C.accentDim : .clear))
            .contentShape(Rectangle())
            .onTapGesture {
                if isSelected { selected.remove(index) } else { selected.insert(index) }
            }
    }

    /// Non-selectable cell (.rate-item.cum / .saving): transparent with a border.
    private func item<V: View>(_ label: String, @ViewBuilder _ content: () -> V) -> some View {
        cellBody(label, filled: false, content)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(C.border))
    }

    private func cellBody<V: View>(_ label: String, filled: Bool, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased()).font(mono(8)).tracking(0.5).foregroundStyle(C.muted).lineLimit(1)
            VStack(alignment: .trailing, spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 5).padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(filled ? C.surface2 : .clear, in: RoundedRectangle(cornerRadius: 5))
    }

    private func chart(_ bars: [(label: String, total: Double)]) -> some View {
        let maxBar = max(bars.map(\.total).max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, b in
                VStack(spacing: 2) {
                    GeometryReader { geo in
                        VStack {
                            Spacer(minLength: 0)
                            UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3)
                                .fill(C.bar)
                                .frame(width: geo.size.width * 0.7, height: geo.size.height * b.total / maxBar)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    Text(b.total > 0 ? fmt(b.total) : " ").font(mono(8)).foregroundStyle(C.dim).lineLimit(1).minimumScaleFactor(0.6)
                    Text(b.label).font(mono(9)).foregroundStyle(C.muted)
                }
            }
        }
        .frame(height: 120)
        .padding(.top, 2)
        .animation(.default, value: bars.map(\.total))
    }
}

/// Bank, Norwegian and Work balances with the app's own offsets: accent when positive, red when
/// negative. Ones that differ from the web app show the difference; a balance that didn't match the
/// last bank app screenshot is outlined in red. Tap one to set it by hand.
struct BalancesView: View {
    let balances: [AppState.Balance]
    var onTap: (AppState.Balance) -> Void
    private typealias C = WebStyle

    var body: some View {
        HStack(spacing: 6) {
            ForEach(balances) { b in
                Button { onTap(b) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(b.label.uppercased())
                            .font(.system(size: 9, weight: .light, design: .monospaced)).tracking(1)
                            .foregroundStyle(C.muted)
                        Text("€" + String(format: "%.2f", b.value)) // fmt() in index.html
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundStyle(b.value >= 0 ? C.accent : C.red)
                            .contentTransition(.numericText())
                            .lineLimit(1).minimumScaleFactor(0.6)
                        Text(caption(b))
                            .font(.system(size: 7, weight: .light, design: .monospaced)).tracking(0.5)
                            .foregroundStyle(b.discrepancy != nil ? C.red : C.dim)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(C.surface, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).fill(C.red.opacity(b.discrepancy != nil ? 0.12 : 0)).allowsHitTesting(false))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(b.discrepancy != nil ? C.red : C.border, lineWidth: b.discrepancy != nil ? 1.5 : 1))
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private func caption(_ b: AppState.Balance) -> String {
        if let d = b.discrepancy { return "BANK " + (d > 0 ? "+" : "−") + String(format: "%.2f", abs(d)) }
        if b.differsFromWeb { return "WEB " + String(format: "%.2f", b.webValue) }
        return " "
    }
}

/// The day's score: this week's saving if every day were like today, next to the week's pace so far,
/// for each level of the Consumption card (Total, +Gas, +Purch).
struct ScoreView: View {
    let summary: WeekSummary?
    @State private var level = 0
    private typealias C = WebStyle

    private func mono(_ size: CGFloat, _ weight: Font.Weight = .light) -> Font { .system(size: size, weight: weight, design: .monospaced) }
    private func fmt(_ n: Double) -> String { "€" + String(format: "%.2f", n) }
    private func signed(_ n: Double) -> String { (n >= 0 ? "+" : "") + fmt(n) }
    private func tone(_ n: Double) -> Color { n >= 0 ? C.green : C.red }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("DAY'S SCORE").font(mono(10)).tracking(1).foregroundStyle(C.muted)
                Spacer()
                Text(Date().formatted(.dateTime.weekday(.wide).day().month(.abbreviated)).uppercased())
                    .font(mono(10)).foregroundStyle(C.dim)
            }
            if let s = summary {
                levelPicker(s)
                let score = s.rows[level].score
                tile("TODAY × 7", value: score.dayProjected,
                     note: "If every day this week went like today.",
                     detail: "spent \(fmt(score.today)) today · budget \(fmt(score.weekBudget / 7))/day")
                tile("THIS WEEK", value: score.weekProjected,
                     note: "At this week's pace so far, to Sunday.",
                     detail: "spent \(fmt(score.week)) in \(score.daysElapsed) day\(score.daysElapsed == 1 ? "" : "s") · budget \(fmt(score.weekBudget))/week")
                difference(score)
            } else {
                HStack { Spacer(); ProgressView().tint(C.dim); Spacer() }.frame(height: 160)
            }
        }
        .padding(14)
        .background(C.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(C.border))
        .environment(\.colorScheme, .dark)
    }

    private func levelPicker(_ s: WeekSummary) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(s.rows.enumerated()), id: \.offset) { i, row in
                Button { withAnimation(.snappy) { level = i } } label: {
                    Text(row.cumulative.label.uppercased())
                        .font(mono(9, i == level ? .regular : .light)).tracking(0.5)
                        .foregroundStyle(i == level ? C.accent : C.muted)
                        .frame(maxWidth: .infinity, minHeight: 26)
                        .background(i == level ? C.surface2 : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(i == level ? C.accentDim : C.border))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func tile(_ label: String, value: Double, note: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(mono(9)).tracking(1).foregroundStyle(C.muted)
            Text(signed(value))
                .font(mono(34, .regular)).foregroundStyle(tone(value))
                .lineLimit(1).minimumScaleFactor(0.5)
                .contentTransition(.numericText())
            Text(note).font(mono(9)).foregroundStyle(C.dim)
            Text(detail).font(mono(9)).foregroundStyle(C.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(C.surface2, in: RoundedRectangle(cornerRadius: 8))
    }

    /// How today moves the week: better or worse than the pace so far.
    private func difference(_ score: WeekSummary.Score) -> some View {
        let d = score.dayProjected - score.weekProjected
        return HStack(spacing: 6) {
            Image(systemName: d >= 0 ? "arrow.up.right" : "arrow.down.right")
            Text(d >= 0 ? "Today beats the week's pace by \(fmt(d))/week"
                        : "Today is \(fmt(-d))/week behind the week's pace")
        }
        .font(mono(10))
        .foregroundStyle(tone(d))
    }
}
