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
        case rankings = "行情排行"
    }

    @Environment(\.mainContracts) private var contracts
    @Environment(\.futuresCatalog) private var catalog
    @EnvironmentObject private var favorites: Favorites
    @State private var scope: Scope = .favorites
    @State private var search = ""
    @State private var editing = false
    @State private var selectedCategory = "全部"
    @State private var sortBy = "默认"
    @State private var onDemandQuotes: [String: MarketDataService.MainContract] = [:]
    private let categories = ["全部", "上期所", "大商所", "郑商所", "广期所", "能源中心", "中金所"]

    private func exchangeCode(for category: String) -> String? {
        switch category {
        case "上期所": return "SHFE"
        case "大商所": return "DCE"
        case "郑商所": return "CZCE"
        case "广期所": return "GFEX"
        case "能源中心": return "INE"
        case "中金所": return "CFFEX"
        default: return nil
        }
    }

    private func quote(for id: String) -> MarketDataService.MainContract? {
        if let live = contracts[id], live.last != nil { return live }
        return onDemandQuotes[id] ?? contracts[id]
    }

    private var mergedQuotes: [String: MarketDataService.MainContract] {
        onDemandQuotes.merging(contracts) { _, current in current.last != nil ? current : onDemandQuotes[current.code] ?? current }
    }

    private var quoteRequestKey: String {
        [scope.rawValue, selectedCategory, search,
         favorites.ids.joined(separator: ","), String(catalog.count)].joined(separator: "|")
    }

    private var quoteRequestIDs: [String] {
        let keyword = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var options = keyword.isEmpty && scope == .favorites
            ? favorites.ids
            : catalog.map(\.id)
        if let exchange = exchangeCode(for: selectedCategory) {
            let supported = Set(catalog.filter { $0.exchange == exchange }.map(\.id))
            options = options.filter { supported.contains($0) }
        }
        if !keyword.isEmpty {
            let matching = Set(catalog.filter { item in
                item.name.localizedCaseInsensitiveContains(keyword) ||
                    item.id.localizedCaseInsensitiveContains(keyword)
            }.map(\.id))
            options = options.filter { matching.contains($0) }
        }
        return options
    }

    @MainActor
    private func refreshVisibleQuotes() async {
        let ids = quoteRequestIDs
        for start in stride(from: 0, to: ids.count, by: 40) {
            if Task.isCancelled { return }
            let chunk = Array(ids[start..<min(start + 40, ids.count)])
            if let received = try? await MarketDataService.selectedProductQuotes(chunk) {
                onDemandQuotes.merge(received) { _, new in new }
            }
            // Sequential requests prevent a full-market subscription burst.
            if start + 40 < ids.count {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func changePercentage(_ item: FuturesInstrument) -> Double? {
        guard let quote = quote(for: item.id), let change = quote.change,
              let settlement = quote.settlement, settlement > 0 else { return nil }
        return change / settlement
    }

    private var instruments: [FuturesInstrument] {
        let keyword = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var base = scope == .favorites && keyword.isEmpty
            ? favorites.ids.compactMap { id in catalog.first(where: { $0.id == id }) }
            : catalog
        if !keyword.isEmpty {
            base = base.filter { item in
                item.name.localizedCaseInsensitiveContains(keyword)
                    || item.id.localizedCaseInsensitiveContains(keyword)
                    || item.exchange.localizedCaseInsensitiveContains(keyword)
                    || (quote(for: item.id)?.month.contains(keyword) ?? false)
                    || (quote(for: item.id)?.code.localizedCaseInsensitiveContains(keyword) ?? false)
            }
        }
        if selectedCategory != "全部" {
            base = base.filter { $0.exchange == exchangeCode(for: selectedCategory) }
        }
        let order = scope == .rankings ? "涨幅" : sortBy
        if order != "默认" {
            base.sort { lhs, rhs in
                let left: Double?
                let right: Double?
                switch order {
                case "成交量":
                    left = contracts[lhs.id]?.volume
                    right = contracts[rhs.id]?.volume
                case "日增仓":
                    left = contracts[lhs.id]?.interestChange
                    right = contracts[rhs.id]?.interestChange
                default:
                    left = changePercentage(lhs)
                    right = changePercentage(rhs)
                }
                if left == nil { return false }
                if right == nil { return true }
                if left != right { return left! > right! }
                return lhs.id < rhs.id
            }
        }
        return base
    }

    private var connectedCount: Int {
        catalog.filter { quote(for: $0.id)?.last != nil }.count
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                searchField
                scopeSelector
                categorySelector
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
            .task(id: quoteRequestKey) {
                while !Task.isCancelled {
                    await refreshVisibleQuotes()
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                }
            }
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
            if scope == .favorites && search.isEmpty && sortBy == "默认" && !favorites.ids.isEmpty {
                Button(editing ? "完成" : "调整") { editing.toggle() }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MarketPalette.accent)
                    .padding(.bottom, 7)
            }
            Menu {
                Picker("排序", selection: $sortBy) {
                    Text("默认").tag("默认")
                    Text("涨幅").tag("涨幅")
                    Text("成交量").tag("成交量")
                    Text("日增仓").tag("日增仓")
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 13))
                    .foregroundStyle(MarketPalette.muted)
                    .frame(width: 25, height: 30)
            }
            .padding(.bottom, 6)
        }
        .padding(.horizontal, 19)
        .padding(.top, 19)
    }

    private var categorySelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                ForEach(categories, id: \.self) { group in
                    Button {
                        selectedCategory = group
                        editing = false
                    } label: {
                        Text(group)
                            .font(.system(size: 12, weight: selectedCategory == group ? .semibold : .regular))
                            .foregroundStyle(selectedCategory == group ? MarketPalette.accent : MarketPalette.muted)
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(selectedCategory == group ? MarketPalette.accent.opacity(0.08) : MarketPalette.surface,
                                        in: Capsule())
                            .overlay(Capsule().stroke(MarketPalette.divider, lineWidth: 0.8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
        }
        .padding(.top, 8)
        .padding(.bottom, 7)
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
        let quote = quote(for: item.id)
        let isFavorite = favorites.ids.contains(item.id)
        return HStack(spacing: 8) {
            NavigationLink {
                InstrumentDetailView(instrument: item)
                    .environment(\.mainContracts,
                                 contracts.merging(onDemandQuotes) {
                                     live, extra in live.last == nil ? extra : live
                                 })
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
