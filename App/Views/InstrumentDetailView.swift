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
    @State private var rawBars: [MarketBar] = []
    @State private var liveQuote: MarketDataService.MainContract?
    @State private var quotePreview: MarketBar?
    @State private var selectedCandleTime: Int64? = nil
    @State private var loadError: String? = nil
    @State private var loading = false
    @State private var currentPriceTick: Double?
    private let periods = ["1分","5分","15分","30分","60分","日线"]
    private var quote: MarketDataService.MainContract? { liveQuote ?? contracts[instrument.id] }
    // Keep provisional tick prices out of the authoritative history/cache.
    private var chartBars: [MarketBar] {
        guard let preview = quotePreview, preview.time == rawBars.last?.time,
              displayedKey == chartKey else { return rawBars }
        var display = rawBars
        display[display.count - 1] = preview
        return display
    }
    private var chartSymbol: String { selectedContract?.code ?? quote?.code ?? instrument.id }
    private var chartKey: String { chartSymbol + "/" + period }
    @State private var displayedKey = ""
    @State private var lastStreamCandleKey: String?
    @State private var mostRecentStreamBar: MarketBar?
    @State private var lastCachedCandleAt: Date?

    // TqSdk quote datetimes are exchange-local (China Standard Time).
    // Use them only to confirm a quote belongs to the currently open bar.
    private static let exchangeQuoteTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
    private var displayedChange: Double? { selectedContract?.change ?? quote?.change }
    private var changeColor: Color { MarketPalette.movement(displayedChange) }
    private var changeText: String { selectedContract?.changePercent ?? quote?.changePercent ?? "--" }
    private var periodSeconds: Int { ["1分":60,"5分":300,"15分":900,"30分":1800,"60分":3600,"日线":86400][period] ?? 900 }
    var body: some View {
        GeometryReader { geometry in
            let quoteHeight: CGFloat = 62
            let professionalChartHeight = max(32, geometry.size.height - 43 - quoteHeight - 18 - 11)
            VStack(spacing: 3) {
                topBar
                indicatorRow
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
                        symbol: chartSymbol, period: periodSeconds, bars: chartBars,
                        priceTick: selectedContract?.priceTick ?? currentPriceTick,
                        showingIndicatorSettings: $showChartIndicatorSettings,
                        selectedCandleTime: $selectedCandleTime
                    )
                    .id(chartKey)
                    .frame(height: professionalChartHeight)
                } else {
                    Spacer()
                }
                quoteStrip
            }
            .padding(.horizontal, 3)
            .padding(.top, 2)
        }
        .background(MarketPalette.surface.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task(id: chartSymbol) {
            // Contract metadata, not displayed price magnitude, determines
            // precision. The main-contract snapshot does not include priceTick,
            // so request it from the existing listed-contract endpoint.
            let symbol = chartSymbol
            currentPriceTick = nil
            if let direct = selectedContract?.priceTick, direct > 0 {
                currentPriceTick = direct
            } else if let listed = try? await MarketDataService.listedContracts(for: instrument.id) {
                guard !Task.isCancelled, chartSymbol == symbol else { return }
                if let tick = listed.first(where: { $0.code == symbol })?.priceTick,
                   tick > 0 {
                    currentPriceTick = tick
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
            // The VPS has already prefetched the historical series. Request
            // that snapshot immediately and independently of the SSE setup.
            // The phone's own cache was displayed above with no network wait.
            let initialSnapshot = Task { @MainActor in
                await loadCandles(reset: false)
            }
            defer { initialSnapshot.cancel() }
            while !Task.isCancelled {
                do {
                    try await MarketDataService.streamCandles(symbol: symbol, period: seconds) { event in
                        guard chartSymbol == symbol, periodSeconds == seconds else { return }
                        applyLiveCandle(event)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    // The independent HTTP snapshot is already in progress.
                    // Retry SSE without creating a duplicate 25-second request.
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
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
            applyLiveQuoteToOpenCandle(incoming)
        }
        .sheet(isPresented: $showOptions) {
            OptionChainView(code: chartSymbol, underlyingLast: rawBars.last?.close ?? selectedContract?.last ?? quote?.last)
        }
        .sheet(isPresented: $showContracts) { ContractListView(instrument: instrument) }
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
        quotePreview = nil
        lastStreamCandleKey = nil
        mostRecentStreamBar = nil
        lastCachedCandleAt = nil
        rawBars = MarketDataService.cached(symbol: symbol, period: period) ?? []
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
            let merged = KlineStartupMerge.combine(
                server: bars, existing: rawBars,
                live: lastStreamCandleKey == requestedKey ? mostRecentStreamBar : nil,
                timestamp: { $0.time })
            guard !merged.isEmpty else { return }
            if rawBars.last != merged.last { quotePreview = nil }
            if rawBars != merged { rawBars = merged }
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
    private func applyLiveQuoteToOpenCandle(_ live: MarketDataService.MainContract) {
        guard live.code == chartSymbol, displayedKey == chartKey,
              let price = live.last, price.isFinite,
              let time = live.time, time.count >= 19,
              let quoteDate = Self.exchangeQuoteTimeFormatter.date(from: String(time.prefix(19))),
              let last = rawBars.last,
              OpenCandleQuotePolicy.accepts(quoteTime: quoteDate.timeIntervalSince1970,
                                           barTime: last.time, period: periodSeconds) else { return }
        // React immediately to the real quote, even if a K-line frame arrived
        // a moment ago. Never invent a new bucket or derive bar volume from
        // the exchange's cumulative daily volume.
        let earlier = quotePreview?.time == last.time ? quotePreview : nil
        let candidate = MarketBar(time: last.time, open: last.open,
                                  high: max(last.high, earlier?.high ?? last.high, price),
                                  low: min(last.low, earlier?.low ?? last.low, price),
                                  close: price, preSettlement: last.preSettlement,
                                  volume: last.volume)
        if candidate != (quotePreview ?? last) { quotePreview = candidate }
    }

    @MainActor
    private func applyLiveCandle(_ event: MarketDataService.CandlePush) {
        guard event.symbol == chartSymbol, displayedKey == chartKey else { return }
        let updated: [MarketBar]
        if let full = event.bars, !full.isEmpty {
            // The new gateway sends only two live bars at startup. Merge
            // by exchange K-line time so a short frame cannot replace the
            // phone's existing MA120 history with just two candles.
            var byTime: [Int64: MarketBar] = [:]
            for bar in rawBars { byTime[bar.time] = bar }
            for bar in full { byTime[bar.time] = bar }
            updated = Array(byTime.values.sorted { $0.time < $1.time }.suffix(500))
        } else if let bar = event.bar, !rawBars.isEmpty {
            var next = rawBars
            if let index = next.lastIndex(where: { $0.time == bar.time }) {
                next[index] = bar
            } else if let last = next.last, bar.time > last.time {
                next.append(bar)
                if next.count > 500 { next.removeFirst(next.count - 500) }
            } else {
                return
            }
            updated = next
        } else {
            return
        }

        let applyStarted = ProcessInfo.processInfo.systemUptime
        // Authoritative changes reconcile any provisional quote. An identical
        // snapshot or an older-history correction cannot erase a newer preview.
        if rawBars.last != updated.last { quotePreview = nil }
        if rawBars != updated { rawBars = updated }
        KlineDiagnostics.record(event, period: periodSeconds, newest: updated.last, started: applyStarted)
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
        HStack(spacing: 5) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 25, height: 36)
            }
            Text(instrument.name + (selectedContract?.month ?? contracts[instrument.id]?.month ?? ""))
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            Text(selectedContract?.code ?? quote?.code ?? (instrument.id + " 主连"))
                .font(.system(size: 10))
                .foregroundStyle(MarketPalette.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 1)
            Text((selectedContract == nil ? quote?.last : chartBars.last?.close ?? selectedContract?.last)?.formatted() ?? "--")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(changeColor)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(changeText)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(changeColor)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Menu {
                ForEach(periods, id: \.self) { p in Button(p) { period = p } }
            } label: {
                Text(period + "⌄")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 7)
                    .background(MarketPalette.background, in: Capsule())
            }

        }
        .foregroundStyle(MarketPalette.ink)
        .padding(.horizontal, 4)
        .frame(height: 43)
    }
    private func timeLabel(_ timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = period == "日线" ? "MM/dd" : "MM/dd HH:mm"
        return formatter.string(from: date)
    }
    private var indicatorRow: some View {
            HStack(spacing: 5) {
                if let timestamp = selectedCandleTime,
                   let candle = chartBars.first(where: { $0.time == timestamp }) {
                    selectedCandleInfo(candle)
                } else {
                    Text("技术分析").foregroundStyle(MarketPalette.muted)
                }
                Spacer(minLength: 0)
                actions
            }
            .font(.system(size: 10, weight: .medium))
            .frame(height: 18, alignment: .leading)
            .clipped()
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
        } label: {
            Image(systemName: "ellipsis").frame(width: 38, height: 24)
        }
        .accessibilityLabel("合约菜单")
    }

    private func contractQuote(_ mainValue: Double?, _ otherValue: Double?) -> String {
        (selectedContract == nil ? mainValue : otherValue)?.formatted() ?? "--"
    }

    private var quoteStrip: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                smallQuote("卖1", contractQuote(quote?.ask, selectedContract?.ask), MarketPalette.ink)
                smallQuote("买1", contractQuote(quote?.bid, selectedContract?.bid), MarketPalette.ink)
                smallQuote("持仓", contractQuote(quote?.interest, selectedContract?.interest), MarketPalette.ink)
            }
            .frame(height: 31)
            .overlay(alignment: .top) { quoteSeparator }
            HStack(spacing: 12) {
                smallQuote("成交", contractQuote(quote?.volume, selectedContract?.volume), MarketPalette.ink)
                smallQuote("增仓", selectedContract == nil ? (quote?.interestChange?.formatted() ?? "--") : "--", MarketPalette.ink)
                smallQuote("幅度", changeText, changeColor)
            }
            .frame(height: 31)
            .overlay(alignment: .top) { quoteSeparator }
        }
        .padding(.horizontal, 6)
    }

    private var quoteSeparator: some View {
        Rectangle().fill(MarketPalette.divider).frame(height: 0.5)
    }

    private func smallQuote(_ label: String, _ value: String, _ tint: Color) -> some View {
        HStack(spacing: 2) {
            Text(label).foregroundStyle(MarketPalette.muted)
            Spacer(minLength: 1)
            Text(value).foregroundStyle(tint)
        }
        .font(.system(size: 10, weight: .medium, design: .rounded))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.65)
        .frame(maxWidth: .infinity)
    }

}
