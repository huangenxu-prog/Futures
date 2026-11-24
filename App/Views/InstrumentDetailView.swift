import SwiftUI
import Combine

struct InstrumentDetailView: View {
    @Environment(\.mainContracts) private var contracts
    @EnvironmentObject private var favorites: Favorites
    @State private var showOptions = false
    @State private var showContracts = false
    @State private var showChartIndicatorSettings = false
    let instrument: FuturesInstrument
    let selectedContract: MarketDataService.ContractQuote?

    init(instrument: FuturesInstrument, selectedContract: MarketDataService.ContractQuote? = nil) {
        self.instrument = instrument
        self.selectedContract = selectedContract
    }

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var period = "15分"
    @AppStorage("qihui.chart.period-order.v1") private var storedPeriodOrder = ""
    @State private var showPeriodOrder = false
    @State private var rawBars: [MarketBar] = []
    @State private var chartFeed = DirectChartFeed<[MarketBar]>()
    @State private var liveQuote: MarketDataService.MainContract?
    @State private var selectedCandleTime: Int64? = nil
    @State private var loadError: String? = nil
    @State private var loading = false
    @State private var currentPriceTick: Double?
    @State private var currentVolumeMultiple: Double?
    private static let defaultPeriods = ["1分","5分","15分","30分","60分","日线"]
    private var periods: [String] {
        var result: [String] = []
        for item in storedPeriodOrder.split(separator: ",").map(String.init) + Self.defaultPeriods {
            if Self.defaultPeriods.contains(item), !result.contains(item) { result.append(item) }
        }
        return result
    }
    private func periodLabel(_ item: String) -> String {
        ["1分":"1m", "5分":"5m", "15分":"15m", "30分":"30m", "60分":"1h", "日线":"日"][item] ?? item
    }
    private var quote: MarketDataService.MainContract? { liveQuote ?? contracts[instrument.id] }
    private var chartSymbol: String { selectedContract?.code ?? quote?.code ?? instrument.id }
    private var chartKey: String { chartSymbol + "/" + period }
    @State private var displayedKey = ""
    @State private var lastStreamCandleKey: String?
    @State private var mostRecentStreamBar: MarketBar?
    @State private var lastCachedCandleAt: Date?

    private var displayedChange: Double? { selectedContract?.change ?? quote?.change }
    private var changeColor: Color { MarketPalette.movement(displayedChange) }
    private var changeText: String { selectedContract?.changePercent ?? quote?.changePercent ?? "--" }
    private var periodSeconds: Int { ["1分":60,"5分":300,"15分":900,"30分":1800,"60分":3600,"日线":86400][period] ?? 900 }
    var body: some View {
        VStack(spacing: 3) {
                topBar
                priceSummary
                marketStatistics
                periodRow
                if let timestamp = selectedCandleTime,
                   let candle = rawBars.first(where: { $0.time == timestamp }) {
                    selectedCandleInfo(candle)
                        .padding(.horizontal, 8)
                        .frame(height: 15)
                }
                if loading && rawBars.isEmpty {
                    Spacer()
                    ProgressView("正在获取行情")
                    Spacer()
                } else if let loadError, rawBars.isEmpty {
                    Spacer()
                    Text(loadError).font(.caption).foregroundStyle(.orange)
                    Spacer()
                } else if !rawBars.isEmpty && displayedKey == chartKey {
                    ProfessionalChartHost(
                        symbol: chartSymbol, period: periodSeconds, bars: rawBars,
                        feed: chartFeed, feedKey: chartKey,
                        priceTick: selectedContract?.priceTick ?? currentPriceTick,
                        contractMultiplier: selectedContract?.volumeMultiple ?? currentVolumeMultiple,
                        previousSettlement: selectedContract == nil ? quote?.settlement : selectedContract?.settlement,
                        showingIndicatorSettings: $showChartIndicatorSettings,
                        selectedCandleTime: $selectedCandleTime
                    )
                    .id(chartKey)
                    .frame(maxHeight: .infinity)
                } else {
                    Spacer()
                }
        }
        .padding(.horizontal, 3)
        .padding(.top, 2)
        .background(MarketPalette.surface.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task(id: chartSymbol) {
            // Contract metadata, not displayed price magnitude, determines
            // precision. The main-contract snapshot does not include priceTick,
            // so request it from the existing listed-contract endpoint.
            let symbol = chartSymbol
            currentPriceTick = selectedContract?.priceTick
            currentVolumeMultiple = selectedContract?.volumeMultiple
            if (currentPriceTick ?? 0) <= 0 || (currentVolumeMultiple ?? 0) <= 0 {
                if let listed = try? await MarketDataService.listedContracts(for: instrument.id) {
                    guard !Task.isCancelled, chartSymbol == symbol else { return }
                    if let contract = listed.first(where: { $0.code == symbol }) {
                        if let tick = contract.priceTick,tick > 0 { currentPriceTick = tick }
                        if let multiple = contract.volumeMultiple,multiple > 0 { currentVolumeMultiple = multiple }
                    }
                }
            }
        }
        .task(id: chartKey + (scenePhase == .active ? "/active" : "/paused")) {
            guard scenePhase == .active else { return }
            let symbol = chartSymbol
            let seconds = periodSeconds
            let key = chartKey
            if displayedKey != key {
                prepareCachedCandles(symbol: symbol, period: seconds)
            }
            // The SSE handshake already contains an authoritative history page.
            // Only hydrate by HTTP if it is incomplete or the stream fails.
            // Never put that request in the live update's critical path.
            var hydration: Task<Void, Never>?
            defer { hydration?.cancel() }
            while !Task.isCancelled {
                do {
                    try await MarketDataService.streamCandles(symbol: symbol, period: seconds) { event in
                        guard !Task.isCancelled, chartSymbol == symbol, periodSeconds == seconds else { return }
                        applyLiveCandle(event)
                        if event.bars != nil, rawBars.count < KlineStartupMerge.initialCount,
                           hydration == nil {
                            hydration = Task { @MainActor in await loadCandles(reset: false) }
                        }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    if hydration == nil, rawBars.count < KlineStartupMerge.initialCount {
                        hydration = Task { @MainActor in await loadCandles(reset: false) }
                    }
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .qihuiLiveQuotes)) { notification in
            guard scenePhase == .active,
                  let updates = notification.object as? [String: MarketDataService.MainContract],
                  let incoming = updates[instrument.id], incoming != liveQuote else { return }
            // A navigation destination may have captured an older environment
            // dictionary. Consume the actual shared live feed directly.
            liveQuote = incoming
        }
        .sheet(isPresented: $showOptions) {
            OptionChainView(code: chartSymbol, underlyingLast: rawBars.last?.close ?? selectedContract?.last ?? quote?.last)
        }
        .sheet(isPresented: $showContracts) { ContractListView(instrument: instrument) }
        .sheet(isPresented: $showPeriodOrder) {
            PeriodOrderView(order: periods, label: periodLabel) { updated in
                storedPeriodOrder = updated.joined(separator: ",")
            }
        }
        .onAppear {
            NotificationCenter.default.post(name: .qihuiDetailVisibility, object: true)
        }
        .onDisappear {
            NotificationCenter.default.post(name: .qihuiDetailVisibility, object: false)
        }
    }
    @MainActor
    private func prepareCachedCandles(symbol: String, period: Int) {
        displayedKey = chartKey
        lastStreamCandleKey = nil
        mostRecentStreamBar = nil
        lastCachedCandleAt = nil
        rawBars = MarketDataService.cached(symbol: symbol, period: period) ?? []
        chartFeed.publish(key: chartKey, snapshot: rawBars)
        selectedCandleTime = nil
        loadError = nil
        loading = rawBars.isEmpty
    }

    @MainActor private func loadCandles(reset: Bool) async {
        let requestedPeriod = periodSeconds
        let symbol = chartSymbol
        if reset { prepareCachedCandles(symbol: symbol, period: requestedPeriod) }
        let requestedKey = chartKey
        loadError = nil
        loading = rawBars.isEmpty
        defer { if !Task.isCancelled { loading = false } }
        do {
            let bars = try await MarketDataService.fetch(symbol: symbol, period: requestedPeriod, count: KlineStartupMerge.initialCount, mergeCached: false)
            try Task.checkCancellation()
            guard symbol == chartSymbol, requestedPeriod == periodSeconds,
                  displayedKey == requestedKey else { return }
            // SSE may have delivered newer ticks while HTTP was in flight.
            // History wins over an older phone cache, but a newer live bar
            // must not be rolled back by the later HTTP completion.
            let hasLive = lastStreamCandleKey == requestedKey
            let merged = KlineStartupMerge.combine(
                server: hasLive ? rawBars : bars,
                existing: hasLive ? bars : rawBars,
                live: hasLive ? mostRecentStreamBar : nil,
                timestamp: { $0.time })
            guard !merged.isEmpty else { return }
            if rawBars != merged { rawBars = merged }
            chartFeed.publish(key: requestedKey, snapshot: rawBars)
            MarketDataService.cache(merged, symbol: symbol, period: requestedPeriod)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            if rawBars.isEmpty {
                loadError = error.localizedDescription
            }
        }
    }
    @MainActor
    private func applyLiveCandle(_ event: MarketDataService.CandlePush) {
        guard event.symbol == chartSymbol, displayedKey == chartKey else { return }
        let applyStarted = ProcessInfo.processInfo.systemUptime
        let updated: [MarketBar]
        var tailOnly = false
        if let full = event.bars, !full.isEmpty {
            // The new gateway sends only two live bars at startup. Merge
            // by exchange K-line time so a short frame cannot replace the
            // phone's existing MA120 history with just two candles.
            var byTime: [Int64: MarketBar] = [:]
            for bar in rawBars { byTime[bar.time] = bar }
            for bar in full { byTime[bar.time] = bar }
            updated = Array(byTime.values.sorted { $0.time < $1.time }.suffix(500))
        } else if let bar = event.bar, let last = rawBars.last {
            var next = rawBars
            if bar.time == last.time {
                next[next.count - 1] = bar
                tailOnly = true
            } else if bar.time > last.time {
                next.append(bar)
                if next.count > 500 { next.removeFirst(next.count - 500) }
                tailOnly = true
            } else if let index = next.lastIndex(where: { $0.time == bar.time }) {
                next[index] = bar
            } else {
                return
            }
            updated = next
        } else {
            return
        }

        if rawBars != updated { rawBars = updated }
        KlineDiagnostics.record(event, period: periodSeconds, newest: updated.last, started: applyStarted)
        // The original TradingChart incremental API consumes each genuine
        // tail update immediately. Only snapshots/history use reconciliation.
        chartFeed.publish(key: chartKey, snapshot: updated, tailOnly: tailOnly)
        lastStreamCandleKey = chartKey
        // Retain the freshest authoritative bar while the parallel history
        // request is pending; never let a late HTTP result roll it back.
        if let newest = event.bar ?? event.bars?.max(by: { $0.time < $1.time }),
           mostRecentStreamBar == nil || newest.time >= mostRecentStreamBar!.time {
            mostRecentStreamBar = newest
        }
        // Save the first authoritative live frame and occasionally refresh it.
        // Throttling prevents thousands of writes per trading session.
        let now = Date()
        if lastCachedCandleAt == nil ||
           now.timeIntervalSince(lastCachedCandleAt!) >= 30 {
            MarketDataService.cache(updated, symbol: chartSymbol, period: periodSeconds)
            lastCachedCandleAt = now
        }
        loadError = nil
        loading = false
    }

    private var topBar: some View {
        HStack(spacing: 6) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 28, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(instrument.name + (selectedContract?.month ?? quote?.month ?? ""))
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(1)
            Text(selectedContract?.code ?? quote?.code ?? (instrument.id + " 主连"))
                .font(.system(size: 11))
                .foregroundStyle(MarketPalette.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
        }
        .foregroundStyle(MarketPalette.ink)
        .padding(.horizontal, 7)
        .frame(height: 34)
    }

    private var priceSummary: some View {
        HStack(alignment: .center, spacing: 7) {
            Text(((displayedKey == chartKey ? rawBars.last?.close : nil) ?? selectedContract?.last ?? quote?.last)?.formatted() ?? "--")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .foregroundStyle(changeColor)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .layoutPriority(1)
            VStack(alignment: .leading, spacing: 3) {
                Text(changeText)
                Text(displayedChange.map { ($0 > 0 ? "+" : "") + $0.formatted() } ?? "--")
            }
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(changeColor)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            Spacer(minLength: 4)
            VStack(spacing: 4) {
                bookQuote("卖1", price: contractQuote(quote?.ask, selectedContract?.ask),
                          quantity: selectedContract == nil ? quote?.askVolume : selectedContract?.askVolume)
                bookQuote("买1", price: contractQuote(quote?.bid, selectedContract?.bid),
                          quantity: selectedContract == nil ? quote?.bidVolume : selectedContract?.bidVolume)
            }
            .frame(width: 132)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 45)
    }

    private var marketStatistics: some View {
        HStack(spacing: 4) {
            smallQuote("成交", CompactMarketQuantity.format(selectedContract == nil ? quote?.volume : selectedContract?.volume), MarketPalette.ink)
            Spacer(minLength: 3)
            smallQuote("持仓", CompactMarketQuantity.format(selectedContract == nil ? quote?.interest : selectedContract?.interest), MarketPalette.ink)
            Spacer(minLength: 3)
            smallQuote("增仓", selectedContract == nil ? (quote?.interestChange?.formatted() ?? "--") : "--", MarketPalette.ink)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
    }

    private var periodRow: some View {
        HStack(spacing: 3) {
            ForEach(periods, id: \.self) { item in
                Button { period = item } label: {
                    Text(periodLabel(item))
                        .font(.system(size: 13, weight: period == item ? .semibold : .medium))
                        .foregroundStyle(period == item ? Color.white : MarketPalette.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 29)
                        .background(period == item ? MarketPalette.accent : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(period == item ? .isSelected : [])
            }
            actions
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .overlay(alignment: .top) { quoteSeparator }
        .overlay(alignment: .bottom) { quoteSeparator }
    }

    private func timeLabel(_ timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = period == "日线" ? "MM/dd" : "MM/dd HH:mm"
        return formatter.string(from: date)
    }
    private func selectedCandleInfo(_ candle: MarketBar) -> some View {
        HStack(spacing: 5) {
            Text(timeLabel(candle.time)).foregroundStyle(MarketPalette.muted)
            Text("开" + candle.open.formatted())
            Text("高" + candle.high.formatted())
            Text("低" + candle.low.formatted())
            Text("收" + candle.close.formatted())
        }
        .font(.system(size: 10, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(MarketPalette.ink.opacity(0.88))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        Menu {
            Button(favorites.ids.contains(instrument.id) ? "移出自选" : "加入自选") {
                favorites.toggle(instrument.id)
            }
            Button("查看期权 T 型报价") { showOptions = true }
                .disabled(selectedContract == nil && quote == nil)
            Button("指标参数设置") { showChartIndicatorSettings = true }
            Button("选择合约月份") { showContracts = true }
            Button("周期排序") { showPeriodOrder = true }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(MarketPalette.ink)
                .frame(width: 32, height: 29)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("合约菜单")
    }

    private func contractQuote(_ mainValue: Double?, _ otherValue: Double?) -> String {
        (selectedContract == nil ? mainValue : otherValue)?.formatted() ?? "--"
    }

    private var quoteSeparator: some View {
        Rectangle().fill(MarketPalette.divider).frame(height: 0.5)
    }

    private func smallQuote(_ label: String, _ value: String, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(MarketPalette.muted)
            Text(value).foregroundStyle(tint)
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.65)
    }

    private func bookQuote(_ label: String, price: String, quantity: Double?) -> some View {
        let size = quantity.flatMap { value in
            value.isFinite && value >= 0
                ? value.formatted(.number.precision(.fractionLength(0))) : nil
        } ?? "--"
        return HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(MarketPalette.muted)
                .fixedSize()
            Text(price)
                .foregroundStyle(MarketPalette.ink)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(size + (size == "--" ? "" : "手"))
                .foregroundStyle(MarketPalette.muted)
                .frame(width: 43, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .accessibilityElement(children: .combine)
    }

}


/// Reorder the existing supported periods without introducing new server intervals.
private struct PeriodOrderView: View {
    @Environment(\.dismiss) private var dismiss
    @State var order: [String]
    let label: (String) -> String
    let onSave: ([String]) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(order, id: \.self) { item in
                    Text(label(item))
                }
                .onMove { source, destination in
                    order.move(fromOffsets: source, toOffset: destination)
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("周期排序")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { onSave(order); dismiss() }
                }
            }
        }
    }
}
