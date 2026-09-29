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

/// Colors from index.html's :root and .rate-* styles.
enum WebStyle {
    static let surface = Color(hex: 0x141416)
    static let surface2 = Color(hex: 0x1C1C20)
    static let border = Color(hex: 0x2A2A30)
    static let muted = Color(hex: 0x5A5850)
    static let dim = Color(hex: 0x8A8880)
    static let accent = Color(hex: 0xC4F54A)
    static let total = Color(hex: 0xE8A050)
    static let daily = Color(hex: 0xC08040)
    static let green = Color(hex: 0x6CC070)
    static let red = Color(hex: 0xF05454)
    static let accentDim = Color(hex: 0x8AAC34)
    static let bar = Color(hex: 0xE8C840)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
