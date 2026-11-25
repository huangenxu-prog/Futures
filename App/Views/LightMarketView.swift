import SwiftUI
import UIKit

/// A minimal, light trading terminal shell around the existing TqSdk feed.
/// The chart, rather than decorative cards or account widgets, remains the focus.
enum MarketPalette {
    // UIColor dynamic providers follow the explicitly selected SwiftUI
    // preferredColorScheme AND the device appearance in system mode.
    // Centralize colors so sheets, lists and chart legends never mix themes.
    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255,
                alpha: 1
            )
        })
    }

    static let background = adaptive(light: 0xFBFCFE, dark: 0x0F1115)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x151922)
    static let raised = adaptive(light: 0xF2F5F9, dark: 0x1B2130)
    static let ink = adaptive(light: 0x222B38, dark: 0xF3F5F8)
    static let muted = adaptive(light: 0x7A8594, dark: 0x9AA4B2)
    static let weak = adaptive(light: 0x8794A3, dark: 0x6F7A89)
    static let divider = adaptive(light: 0xE8EDF2, dark: 0x2A3142)
    static let accent = adaptive(light: 0x2B6BB8, dark: 0x4C8DFF)
    // Domestic futures convention: red = rising, cyan/green = falling.
    static let up = adaptive(light: 0xD43B4A, dark: 0xFF5B5B)
    static let down = adaptive(light: 0x0F9166, dark: 0x23C6C8)
    static let ema20 = adaptive(light: 0x366EB8, dark: 0x4C8DFF)
    static let ema50 = adaptive(light: 0xDE812A, dark: 0xF5A623)
    static let sma = adaptive(light: 0x8657BE, dark: 0xB57CFF)
    static let wma = adaptive(light: 0x188B6F, dark: 0x4CD6A7)

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
    @State private var expandedQuoteID: String?
    @AppStorage("qihui.appearance.mode.v1") private var appearanceMode = AppAppearanceMode.dark.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedInstrument: FuturesInstrument?
    @State private var detailSequence: [FuturesInstrument] = []
    @AppStorage("qihui.change.basis.v1") private var changeBasis = "settlement"
    @State private var showingStrategyCenter = false
    @State private var showingTradingCenter = false
    @State private var selectedCategory = "全部"
    @State private var sortBy = "默认"
    @State private var onDemandQuotes: [String: MarketDataService.MainContract] = [:]
    @State private var lastWarmedCodes = ""
    @State private var lastWarmRequest = Date.distantPast
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

    private var quoteRequestKey: String {
        [scope.rawValue, selectedCategory, search,
         favorites.ids.joined(separator: ","), String(catalog.count)].joined(separator: "|")
    }

    private var favoriteWarmKey: String {
        favorites.ids.compactMap { id in
            contracts[id]?.code ?? onDemandQuotes[id]?.code
        }.joined(separator: "|")
    }

    private var quoteRequestIDs: [String] {
        let keyword = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var options = keyword.isEmpty && scope == .favorites
            ? favorites.ids
            : catalog.map(\.id)
        let available = Set(catalog.map(\.id))
        options = options.filter { available.contains($0) }
        if scope != .favorites, let exchange = exchangeCode(for: selectedCategory) {
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
        // Main contracts are already delivered by the shared SSE feed.
        // Re-requesting them starts another TqSdk login every 30 seconds on
        // the older on-demand path and delays the remaining catalog batches.
        let ids = quoteRequestIDs.filter { contracts[$0]?.last == nil }
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

    @MainActor
    private func warmFavoritesIfNeeded() async {
        let codes = favorites.ids.compactMap { quote(for: $0)?.code }
        guard !codes.isEmpty else { return }
        let signature = Array(Set(codes)).sorted().joined(separator: "|")
        let now = Date()
        guard signature != lastWarmedCodes ||
              now.timeIntervalSince(lastWarmRequest) > 600 else { return }
        lastWarmedCodes = signature
        lastWarmRequest = now
        // Best effort; prefetch failure must not block the quote list.
        try? await MarketDataService.warmFavoriteHistory(codes)
    }

    private func changePercentage(_ item: FuturesInstrument) -> Double? {
        quote(for: item.id)?.ratio(basis: changeBasis)
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
        if scope != .favorites, selectedCategory != "全部" {
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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                scopeSelector
                if scope != .favorites { categorySelector }
                columnHeadings

                List {
                    ForEach(instruments) { item in
                        marketRow(item)
                            .listRowBackground(MarketPalette.surface)
                            .listRowSeparatorTint(MarketPalette.divider)
                            .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if favorites.ids.contains(item.id) {
                                    Button("移出自选", role: .destructive) {
                                        if expandedQuoteID == item.id { expandedQuoteID = nil }
                                        favorites.toggle(item.id)
                                    }
                                } else {
                                    Button("加入自选") { favorites.toggle(item.id) }.tint(MarketPalette.accent)
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
            .navigationDestination(item: $selectedInstrument) { item in
                InstrumentDetailView(instrument: item, sequence: detailSequence)
                    .id(item.id)
                    .environment(\.mainContracts, contracts.merging(onDemandQuotes) {
                        live, extra in live.last == nil ? extra : live
                    })
            }
            .fullScreenCover(isPresented:$showingTradingCenter) {
                TradingCenterView(favoriteIDs:favorites.ids,mainCodes:contracts.merging(onDemandQuotes) { live,extra in live.last == nil ? extra : live }.mapValues(\.code))
            }
            .sheet(isPresented:$showingStrategyCenter) {
                QihuiSettingsView(instruments:catalog, favoriteIDs:favorites.ids,
                                   mainCodes:contracts.merging(onDemandQuotes) { live,extra in live.last == nil ? extra : live }.mapValues(\.code))
            }
            .task(id: quoteRequestKey) {
                while !Task.isCancelled {
                    await refreshVisibleQuotes()
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                }
            }
            .task(id: favoriteWarmKey) {
                // Start the most useful K-line history warmup as soon as the
                // shared quote feed reveals the main contract identity.
                // It must not wait for sequential on-demand quote batches.
                guard !favoriteWarmKey.isEmpty else { return }
                await warmFavoritesIfNeeded()
            }
        }
        .tint(MarketPalette.accent)

    }

    private var searchField: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15))
                    .foregroundStyle(MarketPalette.muted)
                TextField("搜索品种、代码", text: $search)
                    .font(.system(size: 14))
                    .foregroundStyle(MarketPalette.ink)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("搜索期货品种")
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(MarketPalette.muted)
                    }
                    .accessibilityLabel("清除搜索")
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 36)
            .background(MarketPalette.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(MarketPalette.divider, lineWidth: 1))
            Button {
                showingStrategyCenter = true
            } label: {
                HStack(spacing:3) {
                    Image(systemName:"gearshape")
                        .font(.system(size:15,weight:.medium))
                    Text("设置").font(.system(size:13,weight:.medium))
                }
                .foregroundStyle(MarketPalette.accent)
                .frame(height:36)
                .padding(.horizontal,3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("设置")
            Button {
                IndicatorKeyboard.dismiss()
                showingTradingCenter = true
            } label: {
                Text("交易").font(.system(size:13,weight:.medium))
                    .foregroundStyle(MarketPalette.accent)
                    .frame(height:36).padding(.horizontal,3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("交易中心")

        }
        .padding(.horizontal, 12)
        .padding(.top, 3)
        .padding(.bottom, 3)
    }

    private var scopeSelector: some View {
        HStack(spacing: 10) {
            ForEach(Scope.allCases, id: \.self) { option in
                Button {
                    scope = option
                    selectedCategory = "全部"
                    editing = false
                    expandedQuoteID = nil
                } label: {
                    VStack(spacing: 9) {
                        Text(option.rawValue)
                            .font(.system(size: 15, weight: scope == option ? .semibold : .regular))
                            .foregroundStyle(scope == option ? MarketPalette.ink : MarketPalette.muted)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Rectangle()
                            .fill(scope == option ? MarketPalette.accent : .clear)
                            .frame(height: 2)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 4)
            if scope == .favorites && search.isEmpty && sortBy == "默认" && !favorites.ids.isEmpty {
                Button(editing ? "完成" : "编辑") { editing.toggle() }
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
        .padding(.horizontal, 12)
        .padding(.top, 10)
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

    private var showsFavoriteControl: Bool { scope != .favorites || !search.isEmpty }

    private let nameWidth: CGFloat = 115
    private let columns = ["最新价","涨跌幅","成交量","持仓量","昨结","日增仓","今开","最高","最低","振幅","中间价"]
    private var columnHeadings: some View {
        HStack(spacing: 5) {
            Text("品种").frame(width: nameWidth, alignment: .leading)
            ForEach(0..<3) { index in
                Text(columns[index]).frame(maxWidth: .infinity, alignment: .trailing)
            }
            if showsFavoriteControl || editing { Color.clear.frame(width: 23) }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(MarketPalette.muted)
        .padding(.horizontal, 12).frame(height: 33)
        .background(MarketPalette.background)
        .overlay(alignment: .bottom) { Rectangle().fill(MarketPalette.divider).frame(height: 1) }
    }
    private func marketRow(_ item: FuturesInstrument) -> some View {
        let q = quote(for: item.id)
        let isFavorite = favorites.ids.contains(item.id)
        let expanded = expandedQuoteID == item.id && !editing
        return VStack(spacing: 0) {
            HStack(spacing: 5) {
                Button {
                    guard !editing else { return }
                    detailSequence = instruments
                    selectedInstrument = item
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name + (q.map { " " + $0.month } ?? ""))
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(MarketPalette.ink)
                            .lineLimit(1).minimumScaleFactor(0.68)
                        Text(q?.code ?? item.id)
                            .font(.system(size: 9, design: .monospaced)).foregroundStyle(MarketPalette.muted)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }.frame(width: nameWidth, alignment: .leading).frame(height: 57)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
                Button {
                    guard !editing else { return }
                    withAnimation(.easeInOut(duration: 0.18)) {
                        expandedQuoteID = expanded ? nil : item.id
                    }
                } label: {
                    HStack(spacing: 5) {
                        ForEach(0..<3) { index in
                            Text(dataValue(index, q))
                                .font(.system(size: index == 0 ? 14 : 12, weight: .medium, design: .rounded))
                                .foregroundStyle(index < 2 ? MarketPalette.movement(q?.change(basis: changeBasis)) : MarketPalette.ink)
                                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }.frame(height: 57).contentShape(Rectangle())
                }.buttonStyle(.plain)
                .accessibilityLabel(expanded ? "收起行情详情" : "展开行情详情")
                if showsFavoriteControl {
                    Button { favorites.toggle(item.id) } label: {
                        Image(systemName: isFavorite ? "star.fill" : "star").font(.system(size: 12))
                            .foregroundStyle(isFavorite ? MarketPalette.accent : MarketPalette.muted)
                            .frame(width: 23, height: 40)
                    }.buttonStyle(.borderless)
                }
            }.frame(height: 57)
            if expanded {
                VStack(spacing: 9) {
                    ForEach(0..<2) { row in
                        HStack(spacing: 10) {
                            ForEach(0..<3) { col in
                                let index = 3 + row * 3 + col
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(columns[index]).font(.caption2).foregroundStyle(MarketPalette.muted)
                                    Text(dataValue(index, q)).font(.subheadline.weight(.medium))
                                        .monospacedDigit().foregroundStyle(MarketPalette.ink)
                                        .lineLimit(1).minimumScaleFactor(0.65)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }.padding(10).background(MarketPalette.raised, in: RoundedRectangle(cornerRadius: 6))
                    .padding(.bottom, 7)
            }
        }
    }
    private func dataValue(_ index: Int, _ q: MarketDataService.MainContract?) -> String {
        func number(_ value: Double?) -> String {
            guard let value, value.isFinite else { return "--" }
            return value.formatted()
        }
        guard let q else { return "--" }
        switch index {
        case 0: return number(q.last)
        case 1: return q.changePercent(basis: changeBasis)
        case 2: return CompactMarketQuantity.format(q.volume)
        case 3: return CompactMarketQuantity.format(q.interest)
        case 4: return number(q.settlement)
        case 5: return number(q.interestChange)
        case 6: return number(q.opening)
        case 7: return number(q.highest)
        case 8: return number(q.lowest)
        case 9:
            guard let h = q.highest, let l = q.lowest, let base = q.settlement, base > 0, h >= l else { return "--" }
            return String(format: "%.2f%%", (h-l)/base*100)
        case 10:
            guard let bid = q.bid, let ask = q.ask, bid > 0, ask >= bid else { return "--" }
            return number((bid+ask)/2)
        default: return "--"
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
