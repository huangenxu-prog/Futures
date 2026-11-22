import SwiftUI

private struct QuoteColumn {
    let title: String
    let width: CGFloat
}

private struct QuoteScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct MarketHomeView: View {
    @State private var instruments = FuturesInstrument.samples
    @State private var quoteScrollOffset: CGFloat = 0

    private let yellow = Color(red: 1, green: 0.82, blue: 0.02)
    private let pinnedWidth: CGFloat = 132
    private let rowHeight: CGFloat = 49
    private let columns: [QuoteColumn] = [
        .init(title: "最新", width: 78),
        .init(title: "涨幅%", width: 78),
        .init(title: "日增仓", width: 78),
        .init(title: "涨跌额", width: 86),
        .init(title: "成交量", width: 92),
        .init(title: "持仓量", width: 92)
    ]

    private var quoteWidth: CGFloat {
        columns.reduce(CGFloat.zero) { $0 + $1.width }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerBar
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
                    .padding(.bottom, 5)

                // Only the quote values scroll sideways. All names stay pinned on the left.
                // A single quote ScrollView contains every row, so all columns move in sync.
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            ForEach(instruments) { item in
                                NavigationLink {
                                    InstrumentDetailView(instrument: item)
                                } label: {
                                    instrumentName(item)
                                }
                                .buttonStyle(.plain)
                                .frame(height: rowHeight)
                                .overlay(alignment: .bottom) { rowDivider }
                            }
                        }
                        .frame(width: pinnedWidth)

                        ScrollView(.horizontal, showsIndicators: false) {
                            VStack(spacing: 0) {
                                ForEach(instruments) { item in
                                    NavigationLink {
                                        InstrumentDetailView(instrument: item)
                                    } label: {
                                        quoteRow(item)
                                    }
                                    .buttonStyle(.plain)
                                    .frame(height: rowHeight)
                                    .overlay(alignment: .bottom) { rowDivider }
                                }
                            }
                            .frame(width: quoteWidth)
                            .background {
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: QuoteScrollOffsetKey.self,
                                        value: proxy.frame(in: .named("quoteHorizontalScroll")).minX
                                    )
                                }
                            }
                        }
                        .coordinateSpace(name: "quoteHorizontalScroll")
                        .onPreferenceChange(QuoteScrollOffsetKey.self) { quoteScrollOffset = $0 }
                    }
                    .padding(.horizontal, 12)
                }
                .scrollIndicators(.hidden)

                Spacer(minLength: 0)
                Text("演示行情 · 非实时数据")
                    .font(.caption2)
                    .foregroundStyle(.gray)
                    .padding(.bottom, 8)
            }
            .background(Color.black)
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    private var headerBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("名称")
                Spacer(minLength: 0)
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 13))
                    .frame(width: 25)
            }
            .frame(width: pinnedWidth)

            GeometryReader { _ in
                HStack(spacing: 0) {
                    ForEach(columns, id: \.title) { column in
                        Text(column.title)
                            .frame(width: column.width - 8, alignment: .trailing)
                            .padding(.trailing, 8)
                    }
                }
                .frame(width: quoteWidth, alignment: .leading)
                .offset(x: quoteScrollOffset)
            }
            .clipped()
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 50)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule().stroke(
                LinearGradient(
                    colors: [.white, .cyan.opacity(0.5), .white.opacity(0.25)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
        }
        .shadow(color: .cyan.opacity(0.2), radius: 8)
    }

    private func instrumentName(_ item: FuturesInstrument) -> some View {
        HStack(spacing: 5) {
            Text(item.name)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(yellow)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text("M")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.black)
                .padding(3)
                .background(.pink, in: RoundedRectangle(cornerRadius: 3))
            Spacer(minLength: 0)
        }
        .frame(width: pinnedWidth, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func quoteRow(_ item: FuturesInstrument) -> some View {
        HStack(spacing: 0) {
            ForEach(columns, id: \.title) { column in
                Text(quoteValue(item, column.title))
                    .foregroundStyle(quoteColor(item, column.title))
                    .frame(width: column.width - 8, alignment: .trailing)
                    .padding(.trailing, 8)
            }
        }
        .font(.system(size: 16, weight: .medium, design: .rounded))
        .monospacedDigit()
        .frame(width: quoteWidth, height: rowHeight, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func quoteValue(_ item: FuturesInstrument, _ column: String) -> String {
        switch column {
        case "最新": return item.lastPrice.formatted()
        case "涨幅%": return String(format: "%.2f%%", item.changePercent)
        case "日增仓": return String(Int(item.change * 37)) // Existing demo-only value.
        case "涨跌额": return item.change.formatted()
        // No corresponding fields exist in the current demo model. Never invent live figures.
        case "成交量", "持仓量": return "--"
        default: return "--"
        }
    }

    private func quoteColor(_ item: FuturesInstrument, _ column: String) -> Color {
        if column == "最新" || column == "涨幅%" || column == "涨跌额" {
            if item.change > 0 { return .red }
            if item.change < 0 { return .green }
            return .white
        }
        return .white.opacity(0.8)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.14))
            .frame(height: 0.5)
    }
}
