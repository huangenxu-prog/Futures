import SwiftUI

private struct QuoteColumn {
    let title: String
    let width: CGFloat
}

struct MarketHomeView: View {
    @Environment(\.mainContracts) private var contracts
    @EnvironmentObject private var favorites: Favorites
    @State private var destination: FuturesInstrument?
    @State private var deleteID: String?
    @State private var dragOrigin: Int?
    @State private var dragging: String?
    private var instruments: [FuturesInstrument] {
        favorites.ids.compactMap { id in FuturesInstrument.catalog.first { $0.id == id } }
    }
    private let yellow = Color(red: 1, green: 0.82, blue: 0.02)
    private let pinnedWidth: CGFloat = 106
    private let rowHeight: CGFloat = 34
    private let headerHeight: CGFloat = 36
    private let columns: [QuoteColumn] = [
        .init(title: "最新", width: 82),
        .init(title: "涨幅%", width: 83),
        .init(title: "日增仓", width: 94),
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
                // One vertical scroller owns all rows. Only the right-hand block
                // scrolls horizontally, with its headings inside the same scroller.
                ScrollView(.vertical, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            pinnedHeader
                            ForEach(instruments) { item in
                                ZStack(alignment: .leading) {
                                    instrumentName(item)
                                        .opacity(dragging == item.id ? 0.65 : 1)
                                        .overlay {
                                            FavoriteNameTouch(open: {
                                                if deleteID != nil { deleteID = nil } else { destination = item }
                                            }, reveal: { deleteID = item.id }, drag: { dy, state in
                                                switch state {
                                                case .began:
                                                    deleteID = nil
                                                    dragging = item.id
                                                    dragOrigin = favorites.ids.firstIndex(of: item.id)
                                                case .changed:
                                                    if let origin = dragOrigin {
                                                        let target = origin + Int((dy / rowHeight).rounded())
                                                        favorites.move(item.id, to: min(max(0, target), favorites.ids.count - 1))
                                                    }
                                                default:
                                                    dragging = nil
                                                    dragOrigin = nil
                                                }
                                            })
                                        }
                                        .accessibilityAction { destination = item }
                                        .accessibilityAction(named: "删除自选") { favorites.toggle(item.id) }
                                    if deleteID == item.id {
                                        Button("删除自选", role: .destructive) {
                                            favorites.toggle(item.id)
                                            deleteID = nil
                                        }
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        .background(.black)
                                    }
                                }
                                .frame(height: rowHeight)
                                .overlay(alignment: .bottom) { rowDivider }
                            }
                        }
                        .frame(width: pinnedWidth)
                        .zIndex(1)

                        ScrollView(.horizontal, showsIndicators: false) {
                            VStack(spacing: 0) {
                                quoteHeader
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
                            .frame(width: quoteWidth, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
                }

            }
            .background(Color.black.ignoresSafeArea())
            .navigationDestination(item: $destination) { InstrumentDetailView(instrument: $0) }
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    private var pinnedHeader: some View {
        HStack(spacing: 7) {
            Text("名称")
            Spacer(minLength: 0)
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 13))
                .frame(width: 25)
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.leading, 0)
        .padding(.trailing, 4)
        .frame(width: pinnedWidth, height: headerHeight)
        .overlay(alignment: .bottom) { rowDivider }
    }

    private var quoteHeader: some View {
        HStack(spacing: 0) {
            ForEach(columns, id: \.title) { column in
                Text(column.title)
                    .frame(width: column.width - 8, alignment: .trailing)
                    .padding(.trailing, 8)
            }
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: quoteWidth, height: headerHeight, alignment: .leading)
        .overlay(alignment: .bottom) { rowDivider }
    }

    private func instrumentName(_ item: FuturesInstrument) -> some View {
        HStack(spacing: 5) {
            Text(item.name + (contracts[item.id]?.month ?? ""))
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
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
        guard let quote = contracts[item.id] else { return "--" }
        switch column {
        case "最新": return quote.last?.formatted() ?? "--"
        case "涨幅%": return quote.changePercent
        case "日增仓": return quote.interestChange?.formatted() ?? "--"
        case "涨跌额": return quote.change?.formatted() ?? "--"
        case "成交量": return quote.volume?.formatted() ?? "--"
        case "持仓量": return quote.interest?.formatted() ?? "--"
        default: return "--"
        }
    }

    private func quoteColor(_ item: FuturesInstrument, _ column: String) -> Color {
        if column == "最新" || column == "涨幅%" || column == "涨跌额" {
            let change = contracts[item.id]?.change ?? 0
            if change > 0 { return .red }
            if change < 0 { return .green }
            return .white
        }
        return .white.opacity(0.8)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.075))
            .frame(height: 0.5)
    }
}
