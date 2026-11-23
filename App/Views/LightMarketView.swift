import SwiftUI

/// A minimal, light trading terminal shell around the existing TqSdk feed.
/// The chart, rather than decorative cards or account widgets, remains the focus.
enum MarketPalette {
    static let background = Color(red: 0.985, green: 0.989, blue: 0.994)
    static let surface = Color.white
    static let ink = Color(red: 0.13, green: 0.17, blue: 0.22)
    static let muted = Color(red: 0.48, green: 0.52, blue: 0.58)
    static let divider = Color(red: 0.91, green: 0.93, blue: 0.95)
    static let accent = Color(red: 0.17, green: 0.42, blue: 0.72)
    // Domestic futures convention: red = rising, green = falling.
    static let up = Color(red: 0.83, green: 0.23, blue: 0.29)
    static let down = Color(red: 0.06, green: 0.57, blue: 0.40)

    static func movement(_ change: Double?) -> Color {
        guard let change else { return muted }
        if change > 0 { return up }
        if change < 0 { return down }
        return muted
    }
}

struct LightMarketView: View {
    private enum Scope: String, CaseIterable {
        case favorites = "自选"
        case catalog = "全部品种"
    }

    @Environment(\.mainContracts) private var contracts
    @EnvironmentObject private var favorites: Favorites
    @State private var scope: Scope = .favorites
    @State private var search = ""
    @State private var editing = false

    private var instruments: [FuturesInstrument] {
        let keyword = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyword.isEmpty {
            return FuturesInstrument.catalog.filter { item in
                item.name.localizedCaseInsensitiveContains(keyword)
                    || item.id.localizedCaseInsensitiveContains(keyword)
                    || item.exchange.localizedCaseInsensitiveContains(keyword)
                    || (contracts[item.id]?.month.contains(keyword) ?? false)
                    || (contracts[item.id]?.code.localizedCaseInsensitiveContains(keyword) ?? false)
            }
        }
        if scope == .catalog { return FuturesInstrument.catalog }
        return favorites.ids.compactMap { id in
            FuturesInstrument.catalog.first(where: { $0.id == id })
        }
    }

    private var connectedCount: Int {
        FuturesInstrument.catalog.filter { contracts[$0.id]?.last != nil }.count
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                searchField
                scopeSelector
                columnHeadings

                List {
                    ForEach(instruments) { item in
                        marketRow(item)
                            .listRowBackground(MarketPalette.surface)
                            .listRowSeparatorTint(MarketPalette.divider)
                            .listRowInsets(EdgeInsets(top: 0, leading: 18, bottom: 0, trailing: 18))
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if favorites.ids.contains(item.id) {
                                    Button("移出自选", role: .destructive) { favorites.toggle(item.id) }
                                } else {
                                    Button("加入自选") { favorites.toggle(item.id) }
                                        .tint(MarketPalette.accent)
                                }
                            }
                    }
                    .onMove(perform: move)
                    if instruments.isEmpty {
                        Text(search.isEmpty ? "还没有自选品种，可在全部品种中添加。" : "没有找到匹配的品种")
                            .foregroundStyle(MarketPalette.muted)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 50)
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.editMode, .constant(editing ? .active : .inactive))
            }
            .background(MarketPalette.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.light)
        .tint(MarketPalette.accent)
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("行情")
                    .font(.system(size: 29, weight: .bold, design: .rounded))
                    .foregroundStyle(MarketPalette.ink)
                Text("国内期货")
                    .font(.system(size: 12))
                    .foregroundStyle(MarketPalette.muted)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(connectedCount > 0 ? MarketPalette.down : MarketPalette.muted)
                    .frame(width: 6, height: 6)
                Text(connectedCount > 0 ? "天勤行情" : "等待行情")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MarketPalette.muted)
            }
            .padding(.bottom, 4)
        }
        .padding(.horizontal, 19)
        .padding(.top, 14)
        .padding(.bottom, 17)
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(MarketPalette.muted)
            TextField("搜索品种、代码", text: $search)
                .font(.system(size: 15))
                .foregroundStyle(MarketPalette.ink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("搜索期货品种")
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(MarketPalette.muted)
                }
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 43)
        .background(MarketPalette.surface, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(MarketPalette.divider, lineWidth: 1))
        .padding(.horizontal, 18)
    }

    private var scopeSelector: some View {
        HStack(spacing: 24) {
            ForEach(Scope.allCases, id: \.self) { option in
                Button {
                    scope = option
                    editing = false
                } label: {
                    VStack(spacing: 9) {
                        Text(option.rawValue)
                            .font(.system(size: 15, weight: scope == option ? .semibold : .regular))
                            .foregroundStyle(scope == option ? MarketPalette.ink : MarketPalette.muted)
                        Rectangle()
                            .fill(scope == option ? MarketPalette.accent : .clear)
                            .frame(height: 2)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if scope == .favorites && search.isEmpty && !favorites.ids.isEmpty {
                Button(editing ? "完成" : "排序") { editing.toggle() }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MarketPalette.accent)
                    .padding(.bottom, 7)
            }
        }
        .padding(.horizontal, 19)
        .padding(.top, 19)
    }

    private var columnHeadings: some View {
        HStack {
            Text("品种")
            Spacer()
            Text("最新价")
                .frame(width: 90, alignment: .trailing)
            Text("涨跌幅")
                .frame(width: 82, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(MarketPalette.muted)
        .padding(.horizontal, 19)
        .frame(height: 39)
        .background(MarketPalette.background)
        .overlay(alignment: .bottom) {
            Rectangle().fill(MarketPalette.divider).frame(height: 1)
        }
    }

    private func marketRow(_ item: FuturesInstrument) -> some View {
        let quote = contracts[item.id]
        let isFavorite = favorites.ids.contains(item.id)
        return HStack(spacing: 8) {
            NavigationLink {
                InstrumentDetailView(instrument: item)
            } label: {
                HStack(spacing: 9) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.name + (quote?.month ?? ""))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(MarketPalette.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Text(quote?.code ?? item.id)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(MarketPalette.muted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text(quote?.last?.formatted() ?? "--")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(MarketPalette.movement(quote?.change))
                        .monospacedDigit()
                        .frame(width: 88, alignment: .trailing)
                    Text(quote?.changePercent ?? "--")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(MarketPalette.movement(quote?.change))
                        .monospacedDigit()
                        .frame(width: 75, alignment: .trailing)
                }
                .frame(height: 67)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                favorites.toggle(item.id)
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.system(size: 14))
                    .foregroundStyle(isFavorite ? MarketPalette.accent : MarketPalette.muted)
                    .frame(width: 25, height: 43)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isFavorite ? "移出自选" : "加入自选")
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        guard scope == .favorites, search.isEmpty,
              let from = source.first, instruments.indices.contains(from) else { return }
        let id = instruments[from].id
        let target = destination > from ? destination - 1 : destination
        favorites.move(id, to: min(max(0, target), favorites.ids.count - 1))
    }
}
