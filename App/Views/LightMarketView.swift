import SwiftUI
import UIKit
import UniformTypeIdentifiers

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

    static let background = adaptive(light: 0xF1F3F6, dark: 0x111318)
    static let surface = adaptive(light: 0xF1F3F6, dark: 0x111318)
    static let raised = adaptive(light: 0xE7EBF0, dark: 0x191F29)
    static let ink = adaptive(light: 0x242D3B, dark: 0xE6EAF0)
    static let muted = adaptive(light: 0x758195, dark: 0x8994A6)
    static let weak = adaptive(light: 0x758195, dark: 0x8994A6)
    static let divider = adaptive(light: 0xD9DFE7, dark: 0x292F39)
    static let accent = adaptive(light: 0x345C91, dark: 0x508FFF)
    static let countdown = adaptive(light: 0x996000, dark: 0xFFD34E)
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
// Home quote-list accents; candle and indicator colors remain independently configured.
private enum HomeMarketPalette {
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

    static let background = adaptive(light: 0xF1F3F6, dark: 0x111318)
    static let surface = background
    static let header = adaptive(light: 0xE7EBF0, dark: 0x191F29)
    static let ink = adaptive(light: 0x242D3B, dark: 0xE6EAF0)
    static let muted = adaptive(light: 0x758195, dark: 0x8994A6)
    static let divider = adaptive(light: 0xD9DFE7, dark: 0x292F39)
    static let accent = adaptive(light: 0x345C91, dark: 0x508FFF)
    static let up = adaptive(light: 0xC83A46, dark: 0xFF5159)
    static let down = adaptive(light: 0x008A68, dark: 0x20B5B8)

    static func movement(_ change: Double?) -> Color {
        guard let change, change.isFinite else { return muted }
        if change > 0 { return up }
        if change < 0 { return down }
        return muted
    }
}
struct LightMarketView: View {
    var backgroundStyle = MarketBackgroundStyle()
    private enum Scope: String, CaseIterable {
        case favorites = "自选"
        case catalog = "全部品种"
        case rankings = "行情排行"
    }

    @Environment(\.scenePhase) private var marketScenePhase
    @Environment(\.mainContracts) private var contracts
    @Environment(\.futuresCatalog) private var catalog
    @EnvironmentObject private var favorites: Favorites
    @State private var scope: Scope = .favorites
    @State private var search = ""
    @State private var editing = false
    @AppStorage("qihui.appearance.mode.v1") private var appearanceMode = AppAppearanceMode.dark.rawValue
    @Environment(\.colorScheme) private var colorScheme
    var quoteAppearance = QuoteAppearanceStyle()
    private struct DetailSelection: Hashable {
        let instrument: FuturesInstrument
        let sequence: [FuturesInstrument]
    }
    @State private var detailSelection: DetailSelection?
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
        guard let live = contracts[id] else { return onDemandQuotes[id] }
        guard live.last == nil, let extra = onDemandQuotes[id], extra.code == live.code else { return live }
        return extra
    }

    private var quoteRequestKey: String {
        [scope.rawValue, selectedCategory, search,
         favorites.ids.joined(separator: ","), catalog.map(\.id).joined(separator: ",")].joined(separator: "|")
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
        // Keep the last valid quote across failed or partial responses.
        // Missing quotes go first, then refresh already populated rows.
        let ids = quoteRequestIDs.filter { contracts[$0]?.last == nil }
        let ordered = ids.filter { onDemandQuotes[$0]?.last == nil }
                    + ids.filter { onDemandQuotes[$0]?.last != nil }
        var missing: [String] = []
        for start in stride(from: 0, to: ordered.count, by: 12) {
            if Task.isCancelled { return }
            let chunk = Array(ordered[start..<min(start + 12, ordered.count)])
            let received = (try? await MarketDataService.selectedProductQuotes(chunk)) ?? [:]
            if Task.isCancelled { return }
            let valid = received.filter { chunk.contains($0.key) && $0.value.last?.isFinite == true }
            onDemandQuotes.merge(valid) { old, new in
                if let oldTime = old.time, let newTime = new.time, newTime < oldTime { return old }
                return new
            }
            missing.append(contentsOf: chunk.filter { valid[$0] == nil })
            if start + 12 < ordered.count {
                do { try await Task.sleep(for: .milliseconds(750)) } catch { return }
            }
        }
        // Retry a bounded subset using smaller requests; leave other missing
        // rows at the front of the next ordinary refresh cycle.
        let retry = Array(missing.prefix(12))
        for start in stride(from: 0, to: retry.count, by: 4) {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            let chunk = Array(retry[start..<min(start + 4, retry.count)])
            guard let received = try? await MarketDataService.selectedProductQuotes(chunk),
                  !Task.isCancelled else { continue }
            onDemandQuotes.merge(received.filter { chunk.contains($0.key) && $0.value.last?.isFinite == true }) { old, new in
                if let oldTime = old.time, let newTime = new.time, newTime < oldTime { return old }
                return new
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
              now.timeIntervalSince(lastWarmRequest) >= 900 else { return }
        // Best effort; retry failed requests without marking them successful.
        do {
            try await MarketDataService.warmFavoriteHistory(codes)
            lastWarmedCodes = signature
            lastWarmRequest = now
        } catch { }
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
                    left = quote(for: lhs.id)?.volume
                    right = quote(for: rhs.id)?.volume
                case "日增仓":
                    left = quote(for: lhs.id)?.interestChange
                    right = quote(for: rhs.id)?.interestChange
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
                        reorderableRow(item)
                            .listRowBackground(backgroundStyle.surface)
                            .listRowSeparatorTint(backgroundStyle.divider)
                            .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if favorites.ids.contains(item.id) {
                                    Button("移出自选", role: .destructive) {
                                        favorites.toggle(item.id)
                                    }
                                } else {
                                    Button("加入自选") { favorites.toggle(item.id) }.tint(HomeMarketPalette.accent)
                                }
                            }

                    }
                    .onMove(perform: move)
                    if instruments.isEmpty {
                        Text(search.isEmpty ? "还没有自选品种，可在全部品种中添加。" : "没有找到匹配的品种")
                            .foregroundStyle(HomeMarketPalette.muted)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 50)
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(backgroundStyle.surface)
                .environment(\.editMode, .constant(editing ? .active : .inactive))
            }
            .background(backgroundStyle.raised.ignoresSafeArea())
            .tint(HomeMarketPalette.accent)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $detailSelection) { selection in
                InstrumentDetailView(instrument: selection.instrument, sequence: selection.sequence)
                    .id(selection.instrument.id)
                    .environment(\.mainContracts, contracts.merging(onDemandQuotes) {
                        live, extra in live.last == nil && live.code == extra.code ? extra : live
                    })
            }
            .navigationDestination(isPresented:$showingTradingCenter) {
                TradingCenterView(favoriteIDs:favorites.ids,mainCodes:contracts.merging(onDemandQuotes) { live,extra in live.last == nil && live.code == extra.code ? extra : live }.mapValues(\.code))
                    .environment(\.qihuiInPageStack,true)
            }
            .navigationDestination(isPresented:$showingStrategyCenter) {
                QihuiSettingsView(instruments:catalog, favoriteIDs:favorites.ids,
                                   mainCodes:contracts.merging(onDemandQuotes) { live,extra in live.last == nil && live.code == extra.code ? extra : live }.mapValues(\.code))
                    .environment(\.qihuiInPageStack,true)
            }
            .task(id: quoteRequestKey + "|" + String(describing: marketScenePhase)) {
                guard marketScenePhase == .active else { return }
                while !Task.isCancelled {
                    await refreshVisibleQuotes()
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                }
            }
            .task(id: favoriteWarmKey + "|" + String(describing: marketScenePhase)) {
                // Start the most useful K-line history warmup as soon as the
                // shared quote feed reveals the main contract identity.
                // It must not wait for sequential on-demand quote batches.
                guard marketScenePhase == .active, !favoriteWarmKey.isEmpty else { return }
                while !Task.isCancelled {
                    await warmFavoritesIfNeeded()
                    do { try await Task.sleep(for: .seconds(900)) } catch { return }
                }
            }
        }
        .tint(MarketPalette.accent)

    }

    private var searchField: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15))
                    .foregroundStyle(HomeMarketPalette.muted)
                TextField("搜索品种、代码", text: $search)
                    .font(.system(size: 14))
                    .foregroundStyle(HomeMarketPalette.ink)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("搜索期货品种")
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(HomeMarketPalette.muted)
                    }
                    .accessibilityLabel("清除搜索")
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 36)
            .background(backgroundStyle.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(backgroundStyle.divider.opacity(0.7), lineWidth: 0.6))
            Button {
                showingStrategyCenter = true
            } label: {
                HStack(spacing:3) {
                    Image(systemName:"gearshape")
                        .font(.system(size:15,weight:.medium))
                    Text("设置").font(.system(size:13,weight:.medium))
                }
                .foregroundStyle(HomeMarketPalette.accent)
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
                    .foregroundStyle(HomeMarketPalette.accent)
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
                } label: {
                    VStack(spacing: 9) {
                        Text(option.rawValue)
                            .font(.system(size: 15, weight: scope == option ? .semibold : .regular))
                            .foregroundStyle(scope == option ? HomeMarketPalette.ink : HomeMarketPalette.muted)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Rectangle()
                            .fill(scope == option ? HomeMarketPalette.accent : .clear)
                            .frame(height: 2)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 4)

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
                    .foregroundStyle(HomeMarketPalette.muted)
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
                            .foregroundStyle(selectedCategory == group ? HomeMarketPalette.accent : HomeMarketPalette.muted)
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(selectedCategory == group ? HomeMarketPalette.accent.opacity(0.08) : backgroundStyle.surface,
                                        in: Capsule())
                            .overlay(Capsule().stroke(backgroundStyle.divider, lineWidth: 0.8))
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
    private let columns = ["最新价", "涨跌幅", "日增仓"]
    private var columnHeadings: some View {
        HStack(spacing: 5) {
            Text("品种").frame(width: nameWidth, alignment: .leading)
            ForEach(columns, id: \.self) { column in
                Text(column).frame(maxWidth: .infinity, alignment: .trailing)
            }
            if showsFavoriteControl || editing { Color.clear.frame(width: 23) }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(HomeMarketPalette.muted)
        .padding(.horizontal, 12).frame(height: 33)
        .background(backgroundStyle.raised)
        .overlay(alignment: .bottom) { Rectangle().fill(backgroundStyle.divider).frame(height: 1) }
    }
    @ViewBuilder private func reorderableRow(_ item: FuturesInstrument) -> some View {
        if scope == .favorites && search.isEmpty && sortBy == "默认" {
            marketRow(item)
                            .onDrag { NSItemProvider(object: item.id as NSString) }
                            .onDrop(of: [.text], isTargeted: nil) { providers in
                                guard scope == .favorites, search.isEmpty, sortBy == "默认", let provider = providers.first, favorites.ids.contains(item.id) else { return false }
                                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                                    guard let id = object as? String else { return }
                                    DispatchQueue.main.async {
                                        guard scope == .favorites, search.isEmpty, sortBy == "默认", favorites.ids.contains(id), let currentTarget = favorites.ids.firstIndex(of: item.id) else { return }
                                        favorites.move(id, to: currentTarget)
                                    }
                                }
                                return true
                            }
        } else {
            marketRow(item)
        }
    }
    private func marketRow(_ item: FuturesInstrument) -> some View {
        let q = quote(for: item.id)
        let isFavorite = favorites.ids.contains(item.id)
        return HStack(spacing: 5) {
            HStack(spacing: 5) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name + (q.map { " " + $0.month } ?? ""))
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(HomeMarketPalette.ink)
                        .lineLimit(1).minimumScaleFactor(0.68)
                    Text(q?.code ?? item.id)
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(HomeMarketPalette.muted)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }.frame(width: nameWidth, alignment: .leading)
                ForEach(0..<3) { index in
                    Text(dataValue(index, q))
                        .font(.system(size: index == 0 ? 14 : 12, weight: .medium, design: .rounded))
                        .foregroundStyle(index == 2 ? HomeMarketPalette.ink : quoteAppearance.movement(q?.change(basis: changeBasis), neutral: HomeMarketPalette.muted))
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(height: 57)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !editing else { return }
                detailSelection = DetailSelection(instrument: item, sequence: instruments)
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                guard !editing else { return }
                detailSelection = DetailSelection(instrument: item, sequence: instruments)
            }
            if showsFavoriteControl {
                Button { favorites.toggle(item.id) } label: {
                    Image(systemName: isFavorite ? "star.fill" : "star").font(.system(size: 12))
                        .foregroundStyle(isFavorite ? HomeMarketPalette.accent : HomeMarketPalette.muted)
                        .frame(width: 23, height: 40)
                }.buttonStyle(.borderless)
            }
        }.frame(height: 57)
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
        case 2:
            guard let change = q.interestChange, change.isFinite else { return "--" }
            return (change > 0 ? "+" : "") + number(change)
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
