import SwiftUI
import Charts

private enum ChartInk {
    static let up = MarketPalette.up
    static let down = MarketPalette.down
    static let slow = MarketPalette.ema50
}

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
    @State private var candles: [DemoCandle] = []
    @State private var rawBars: [MarketBar] = []
    @State private var selectedCandleTime: Int64? = nil
    @State private var loadError: String? = nil
    @State private var loading = false
    @State private var showingCachedData = false
    @State private var showIndicators = true
    @State private var currentPriceTick: Double?
    @State private var selectedCandleIndex: Int? = nil
    @State private var crosshairActive = false
    @State private var pinchActive = false
    @State private var visibleStart = 0.0
    @State private var visibleCount = 100.0
    @State private var zoomBaseCount: Double? = nil
    @State private var zoomBaseStart: Double? = nil
    @State private var dragBaseStart: Double? = nil
    private let periods = ["1分","5分","15分","30分","60分","日线"]
    private var latestPrice: Double { candles.last?.close ?? 0 }
    private var quote: MarketDataService.MainContract? { contracts[instrument.id] }
    private var chartSymbol: String { selectedContract?.code ?? quote?.code ?? instrument.id }
    private var chartKey: String { chartSymbol + "/" + period }
    @State private var displayedKey = ""
    @State private var lastStreamCandleAt: Date?
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
    private var window: Range<Int> {
        let lower = min(candles.count, max(0, Int(floor(visibleStart)) - 1))
        return lower..<max(lower, min(candles.count, Int(ceil(visibleStart + visibleCount)) + 1))
    }
    private func maxStart(_ count: Double) -> Double {
        max(0, Double(candles.count) - count + floor(count / 2))
    }
    private var priceDomain: ClosedRange<Double> {
        let low = candles[window].map(\.low).min() ?? latestPrice * 0.97
        let high = candles[window].map(\.high).max() ?? latestPrice * 1.03
        let padding = max((high - low) * 0.10, latestPrice * 0.002)
        return (low - padding)...(high + padding)
    }
    private var visibleDomain: ClosedRange<Double> { visibleStart...(visibleStart + visibleCount - 1) }
    private var macdDomain: ClosedRange<Double> {
        let peak = candles[window].map { max(abs($0.hist), abs($0.dif), abs($0.dea)) }.max() ?? 1
        let limit = max(peak * 1.25, latestPrice * 0.0005)
        return -limit...limit
    }
    var body: some View {
        GeometryReader { geometry in
            let quoteHeight: CGFloat = 62
            let professionalChartHeight = max(32, geometry.size.height - 43 - quoteHeight - 18 - 11)
            VStack(spacing: 3) {
                topBar
                indicatorRow
                if loading && candles.isEmpty {
                    Spacer()
                    ProgressView("正在获取行情")
                    Spacer()
                } else if let loadError, candles.isEmpty {
                    Spacer()
                    Text(loadError).font(.caption).foregroundStyle(.orange)
                    Spacer()
                } else if !rawBars.isEmpty && displayedKey == chartKey {
                    ProfessionalChartHost(
                        symbol: chartSymbol, period: periodSeconds, bars: rawBars,
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
        .onChange(of: quote?.time) { _, _ in
            // When a separate candle SSE connection stalls, the existing live
            // main-contract quote can keep the open candle moving. Authoritative
            // SSE bars always take precedence and replace this provisional close.
            if let quote { applyLiveQuoteToOpenCandle(quote) }
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
        lastStreamCandleAt = nil
        lastStreamCandleKey = nil
        mostRecentStreamBar = nil
        lastCachedCandleAt = nil
        if let cached = MarketDataService.cached(symbol: symbol, period: period) {
            rawBars = cached
            selectedCandleTime = nil
            candles = DemoCandle.from(cached)
            visibleCount = Double(min(100, candles.count))
            visibleStart = Double(max(0, candles.count - Int(visibleCount)))
            selectedCandleIndex = nil
            crosshairActive = false
            showingCachedData = true
        } else {
            candles = []
            rawBars = []
            selectedCandleTime = nil
            selectedCandleIndex = nil
            crosshairActive = false
            showingCachedData = false
        }
        loadError = nil
        loading = candles.isEmpty
    }

    @MainActor private func loadCandles(reset: Bool) async {
        let requestedPeriod = periodSeconds
        let symbol = chartSymbol
        if reset { prepareCachedCandles(symbol: symbol, period: requestedPeriod) }
        let requestedKey = chartKey
        loadError = nil
        loading = candles.isEmpty
        defer { if !Task.isCancelled { loading = false } }
        do {
            let bars = try await MarketDataService.fetch(symbol: symbol, period: requestedPeriod, count: 500)
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
            let wasEmpty = candles.isEmpty
            let wasAtLatest = visibleStart + visibleCount >= Double(candles.count) - 1
            let oldCount = candles.count
            let anchor = candles.indices.contains(Int(visibleStart)) ? candles[Int(visibleStart)].time : nil
            let fraction = visibleStart - floor(visibleStart)
            guard !merged.isEmpty else { return }
            rawBars = merged
            candles = DemoCandle.from(merged)
            MarketDataService.cache(merged, symbol: symbol, period: requestedPeriod)
            showingCachedData = false
            if wasEmpty {
                visibleCount = Double(min(100, candles.count))
                visibleStart = Double(max(0, candles.count - Int(visibleCount)))
                selectedCandleIndex = nil
            } else if wasAtLatest {
                visibleStart = min(maxStart(visibleCount), max(0, visibleStart + Double(candles.count - oldCount)))
            } else if let anchor, let index = candles.firstIndex(where: { $0.time >= anchor }) {
                visibleStart = min(maxStart(visibleCount), Double(index) + fraction)
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            if candles.isEmpty {
                loadError = error.localizedDescription
            } else {
                showingCachedData = true
            }
        }
    }
    @MainActor
    private func applyLiveQuoteToOpenCandle(_ live: MarketDataService.MainContract) {
        guard selectedContract == nil, live.code == chartSymbol,
              let price = live.last, price.isFinite, price > 0,
              let time = live.time, time.count >= 19,
              let quoteDate = Self.exchangeQuoteTimeFormatter.date(from: String(time.prefix(19))),
              let last = rawBars.last else { return }
        // A fresh real K-line event has more complete OHLC and volume data.
        if let streamTime = lastStreamCandleAt,
           lastStreamCandleKey == chartKey,
           Date().timeIntervalSince(streamTime) < 2 { return }
        let quoteTime = quoteDate.timeIntervalSince1970
        let first = Double(last.time)
        guard quoteTime >= first, quoteTime < first + Double(periodSeconds) else { return }
        let candidate = MarketBar(time: last.time, open: last.open,
                                  high: max(last.high, price), low: min(last.low, price),
                                  close: price, preSettlement: last.preSettlement,
                                  volume: last.volume)
        guard candidate != last else { return }
        var next = rawBars
        next[next.count - 1] = candidate
        rawBars = next
        candles = DemoCandle.from(next)
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

        let wasEmpty = candles.isEmpty
        let wasAtLatest = visibleStart + visibleCount >= Double(candles.count) - 1
        let oldCount = candles.count
        let anchor = candles.indices.contains(Int(visibleStart)) ? candles[Int(visibleStart)].time : nil
        let fraction = visibleStart - floor(visibleStart)
        rawBars = updated
        candles = DemoCandle.from(updated)
        lastStreamCandleAt = Date()
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
        showingCachedData = false
        loadError = nil
        loading = false
        if wasEmpty {
            visibleCount = Double(min(100, candles.count))
            visibleStart = Double(max(0, candles.count - Int(visibleCount)))
            selectedCandleIndex = nil
        } else if wasAtLatest {
            visibleStart = min(maxStart(visibleCount),
                               max(0, visibleStart + Double(candles.count - oldCount)))
        } else if let anchor, let index = candles.firstIndex(where: { $0.time >= anchor }) {
            visibleStart = min(maxStart(visibleCount), Double(index) + fraction)
        }
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
            Text((selectedContract == nil ? quote?.last : rawBars.last?.close ?? selectedContract?.last)?.formatted() ?? "--")
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
    private func timeLabel(_ index: Int) -> String {
        guard candles.indices.contains(index) else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(candles[index].time))
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = period == "日线" ? "MM/dd" : "MM/dd HH:mm"
        return formatter.string(from: date)
    }
    private var indicatorRow: some View {
            HStack(spacing: 5) {
                if let timestamp = selectedCandleTime,
                   let index = candles.firstIndex(where: { $0.time == timestamp }) {
                    selectedCandleInfo(candles[index], index: index)
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
    private func candleChart(height: CGFloat) -> some View {
        VStack(alignment:.leading,spacing:6) {
            Chart {
                ForEach(window, id: \.self) { i in
                    let c = candles[i]
                    RuleMark(x: .value("序号", i), yStart: .value("低", c.low), yEnd: .value("高", c.high))
                        .foregroundStyle(Color.clear)
                    if showIndicators {
                        LineMark(x:.value("序号",i),y:.value("EMA20",c.ema20),series:.value("均线","EMA20")).foregroundStyle(MarketPalette.ink).lineStyle(StrokeStyle(lineWidth:1.4))
                        LineMark(x:.value("序号",i),y:.value("EMA50",c.ema50),series:.value("均线","EMA50")).foregroundStyle(ChartInk.slow).lineStyle(StrokeStyle(lineWidth:1.4))
                    }
                }
                if let index = selectedCandleIndex, candles.indices.contains(index) {
                    RuleMark(x: .value("十字时间", index))
                        .foregroundStyle(MarketPalette.muted.opacity(0.8))
                        .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
                    RuleMark(y: .value("十字价格", candles[index].close))
                        .foregroundStyle(MarketPalette.muted.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
                }
            }
            .chartBackground { proxy in candleBackground(proxy) }
            .chartYScale(domain: priceDomain)
            .chartXScale(domain: visibleDomain)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisValueLabel {
                        if let index = value.as(Int.self) {
                            Text(timeLabel(index)).font(.system(size: 9)).foregroundStyle(MarketPalette.muted)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing) { _ in
                    AxisValueLabel().foregroundStyle(MarketPalette.muted)
                    AxisGridLine().foregroundStyle(MarketPalette.divider.opacity(0.7))
                }
            }
            .frame(height:height - 28)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    ChartTouchSurface(
                        onPan: { translation, ended in
                            if ended {
                                dragBaseStart = nil
                                return
                            }
                            guard !crosshairActive, !pinchActive else { return }
                            if dragBaseStart == nil {
                                dragBaseStart = visibleStart
                                selectedCandleIndex = nil
                            }
                            guard let base = dragBaseStart else { return }
                            let plotWidth = max(geometry.size.width - 38, 1)
                            let shift = Double(translation / plotWidth) * visibleCount
                            visibleStart = min(max(0, base - shift),
                                               maxStart(visibleCount))
                        },
                        onCrosshair: { locationX, ended in
                            if ended {
                                crosshairActive = false
                                return
                            }
                            guard !pinchActive else { return }
                            crosshairActive = true
                            dragBaseStart = nil
                            guard let plotFrame = proxy.plotFrame else { return }
                            let plot = geometry[plotFrame]
                            if let value: Double = proxy.value(atX: locationX - plot.minX) {
                                let index = Int(value.rounded())
                                if candles.indices.contains(index) {
                                    selectedCandleIndex = index
                                }
                            }
                        },
                        onPinch: { scale, ended in
                            if ended {
                                zoomBaseCount = nil
                                zoomBaseStart = nil
                                pinchActive = false
                                return
                            }
                            pinchActive = true
                            crosshairActive = false
                            selectedCandleIndex = nil
                            dragBaseStart = nil
                            if zoomBaseCount == nil {
                                zoomBaseCount = visibleCount
                                zoomBaseStart = visibleStart
                            }
                            guard let baseCount = zoomBaseCount,
                                  let baseStart = zoomBaseStart else { return }
                            let total = Double(candles.count)
                            let nextCount = min(total, max(min(20, total), baseCount / Double(scale)))
                            let center = baseStart + (baseCount - 1) / 2
                            visibleCount = nextCount
                            visibleStart = min(max(0, center - (nextCount - 1) / 2),
                                               maxStart(nextCount))
                        },
                        onTap: {
                            selectedCandleIndex = nil
                            crosshairActive = false
                        }
                    )
                }
            }
            .onTapGesture(count:2) {
                withAnimation(.easeOut(duration:0.2)) {
                    visibleCount = Double(min(100, candles.count))
                    visibleStart = Double(max(0, candles.count - Int(visibleCount)))
                    selectedCandleIndex = nil
                }
            }
        }.padding(.horizontal, 4).padding(.top, 2)
    }

    private func candleBackground(_ proxy: ChartProxy) -> some View {
        GeometryReader { geometry in
            if let anchor = proxy.plotFrame {
                let plot = geometry[anchor]
                Canvas { context, size in
                    let spacing = size.width / CGFloat(max(1, visibleCount - 1))
                    let bodyWidth = max(0.5, spacing * 0.66)
                    for index in window {
                        let bar = candles[index]
                        guard let x = proxy.position(forX: index),
                              let high = proxy.position(forY: bar.high),
                              let low = proxy.position(forY: bar.low),
                              let open = proxy.position(forY: bar.open),
                              let close = proxy.position(forY: bar.close) else { continue }
                        let top = min(open, close), bottom = max(open, close)
                        let tint: Color = bar.close == bar.open ? MarketPalette.ink : (bar.close > bar.open ? ChartInk.up : ChartInk.down)
                        var lines = Path()
                        lines.move(to: CGPoint(x: x, y: high))
                        lines.addLine(to: CGPoint(x: x, y: top))
                        lines.move(to: CGPoint(x: x, y: bottom))
                        lines.addLine(to: CGPoint(x: x, y: low))
                        if bar.open == bar.close {
                            lines.move(to: CGPoint(x: x - bodyWidth / 2, y: open))
                            lines.addLine(to: CGPoint(x: x + bodyWidth / 2, y: open))
                        } else {
                            let body = Path(CGRect(x: x - bodyWidth / 2, y: top, width: bodyWidth, height: max(0.8, bottom - top)))
                            if bar.close > bar.open {
                                context.stroke(body, with: .color(tint), lineWidth: 0.8)
                            } else {
                                context.fill(body, with: .color(tint))
                            }
                        }
                        context.stroke(lines, with: .color(tint), lineWidth: 1)
                    }
                }
                .frame(width: plot.width, height: plot.height)
                .clipped()
                .position(x: plot.midX, y: plot.midY)
                .allowsHitTesting(false)
            }
        }
    }

    private func selectedCandleInfo(_ candle: DemoCandle, index: Int) -> some View {
        HStack(spacing: 5) {
            Text(timeLabel(index)).foregroundStyle(MarketPalette.muted)
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

    private func volumeChart(height: CGFloat) -> some View {
        VStack(alignment: .leading) {
            Text("成交量").font(.caption2)
            Chart(window, id: \.self) { i in
                BarMark(x: .value("序号", i), y: .value("成交量", candles[i].volume))
                    .foregroundStyle(candles[i].close >= candles[i].open ? ChartInk.up : ChartInk.down)
            }
            .chartXScale(domain: visibleDomain)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
        }
        .frame(height: height)
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

    private func macdPanel(height: CGFloat) -> some View {
        VStack(alignment:.leading,spacing:3) {
            HStack { Text("MACD(12,26,9)").foregroundStyle(ChartInk.slow).font(.system(size: 10, weight: .medium)); Spacer(); Text("DIF").foregroundStyle(MarketPalette.ink); Text("DEA").foregroundStyle(ChartInk.slow) }.foregroundStyle(MarketPalette.muted.opacity(0.8)).font(.system(size: 10))
            GeometryReader { geometry in
                let barWidth = max(0.5, geometry.size.width / CGFloat(max(1, visibleCount - 1)) * 0.26)
                Chart {
                    ForEach(window, id: \.self) { i in
                    let c = candles[i]
                        BarMark(x:.value("序号",i),y:.value("MACD",c.hist),width:.fixed(barWidth)).foregroundStyle(c.hist >= 0 ? ChartInk.up : ChartInk.down)
                        LineMark(x:.value("序号",i),y:.value("DIF",c.dif),series:.value("MACD线","DIF")).foregroundStyle(MarketPalette.ink).lineStyle(StrokeStyle(lineWidth:1.2))
                        LineMark(x:.value("序号",i),y:.value("DEA",c.dea),series:.value("MACD线","DEA")).foregroundStyle(ChartInk.slow).lineStyle(StrokeStyle(lineWidth:1.2))
                    }
                    RuleMark(y:.value("零轴",0)).foregroundStyle(MarketPalette.divider)
                    if let index = selectedCandleIndex, candles.indices.contains(index) {
                        RuleMark(x: .value("选中时间", index))
                            .foregroundStyle(MarketPalette.muted.opacity(0.8))
                            .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
                    }
                }.chartYScale(domain: macdDomain).chartXScale(domain: visibleDomain).chartXAxis(.hidden).chartYAxis(.hidden)
            }.frame(height:height - 20)
        }.padding(.horizontal, 4).padding(.top, 2)
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

private struct DemoCandle {
    let time: Int64
    let open, high, low, close, ema20, ema50, dif, dea, hist: Double
    let preSettlement: Double?
    let volume: Int64

    static func from(_ bars: [MarketBar]) -> [DemoCandle] {
        guard !bars.isEmpty else { return [] }
        let closes = bars.map(\.close)
        func ema(_ values: [Double], _ period: Int) -> [Double] {
            let factor = 2.0 / (Double(period) + 1)
            var result = [values[0]]
            for value in values.dropFirst() {
                result.append(value * factor + result[result.count - 1] * (1 - factor))
            }
            return result
        }
        let ema12 = ema(closes, 12), ema26 = ema(closes, 26)
        let dif = zip(ema12, ema26).map { $0 - $1 }
        let dea = ema(dif, 9), ema20 = ema(closes, 20), ema50 = ema(closes, 50)
        return bars.indices.map { i in
            let bar = bars[i]
            return DemoCandle(time: bar.time, open: bar.open, high: bar.high,
                              low: bar.low, close: bar.close, ema20: ema20[i],
                              ema50: ema50[i], dif: dif[i], dea: dea[i],
                              hist: 2 * (dif[i] - dea[i]), preSettlement: bar.preSettlement, volume: bar.volume)
        }
    }
}
