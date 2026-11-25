import SwiftUI
import TradingChart

/// The interaction engine is supplied by TradingChart (MIT).
/// Qihui retains its own toolbar, quote strip, colors and TqSdk data source.
@available(iOS 17.0, *)
struct ProfessionalChartHost: View {
    let symbol: String
    let period: Int
    let bars: [MarketBar]
    let feed: DirectChartFeed<[MarketBar]>
    let feedKey: String
    let priceTick: Double?
    var contractMultiplier: Double? = nil
    var previousSettlement: Double? = nil
    @Binding var showingIndicatorSettings: Bool
    @Binding var selectedCandleTime: Int64?
    var isReplay = false
    var onReplayApplied: ((MarketBar, Double) -> Void)? = nil
    var onVerticalSwipe: ((Int) -> Void)? = nil
    @State private var feedOwner = UUID()
    @AppStorage(CandleAppearance.hollowKey) private var hollowRising = true
    @AppStorage(CandleAppearance.upKey) private var candleUp = CandleAppearance.automatic
    @AppStorage(CandleAppearance.downKey) private var candleDown = CandleAppearance.automatic
    @AppStorage(CandleAppearance.dojiKey) private var candleDoji = CandleAppearance.automatic


    @State private var model: TradingChartModel = {
        var configuration = TradingChartConfiguration()
        configuration.viewport.candleVisibleBars = 52
        configuration.viewport.minVisibleBars = 5
        // Keep the newest candle immediately before the price axis, like
        // a dense futures terminal. Preserve a fraction of one bar as breathing room.
        // With the large live-price badge disabled there is no badge-overhang
        // requirement forcing several extra bars of blank space.
        configuration.viewport.trailingPaddingBars = 0.7
        configuration.viewport.maxTrailingPaddingFraction = 0.04
        configuration.showsPriceBadge = false
        configuration.showsCurrentPriceLine = true
        configuration.paneHeight = 110
        configuration.maxLiveBarCount = nil
        configuration.showsLegend = true
        configuration.showsHighLowMarkers = true
        configuration.stylePicker = nil
        configuration.isDrawingEnabled = true
        configuration.isCrosshairEnabled = true
        configuration.isZoomEnabled = true
        configuration.historyPrefetchThreshold = .visibleWindows(1)
        // Build defaults before restoring the user's saved preferences.
        let chart = TradingChartModel(style: .candles, configuration: configuration)
        chart.indicators = ChartDisplaySettings.load().indicators()
        configuration.persistence = ChartPersistence(
            key: "qihui.chart.indicators-and-style",
            indicatorCatalog: [],
            persistsStyle: false,
            persistsIndicators: false
        )
        chart.configuration = configuration
        return chart
    }()

    @State private var displaySettings = ChartDisplaySettings.load()
    @State private var sessionAxis = TradingSessionAxis()
    @State private var drawingsRestored = false
    @State private var historyDepth = 1100
    @State private var historyTask: Task<Void, Never>?

    private var interval: ChartInterval {
        ChartInterval(seconds: TimeInterval(period))
    }

    private var priceDigits: Int {
        MarketPricePrecision.digits(tick: priceTick,
            observations: Array(bars.suffix(200).flatMap { [$0.open, $0.high, $0.low, $0.close] }))
    }

    private var chartPriceFormatter: PriceFormatter {
        let digits = priceDigits
        return PriceFormatter { value, context in
            switch context {
            case .compact:
                return PriceFormatter.automatic.format(value, context: .compact)
            case .legend:
                // Keep EMA/MACD line values informative while trimming
                // unnecessary .00 from genuine integer futures prices.
                return MarketPricePrecision.format(value, digits: max(2, digits))
            case .axis, .badge, .crosshair:
                return MarketPricePrecision.format(value, digits: digits)
            }
        }
    }

    private var chartStrings: TradingChartStrings {
        var s = TradingChartStrings.localized(for: Locale(identifier: "zh-Hans"))
        s.time = "时间"
        s.open = "开盘"
        s.high = "最高"
        s.low = "最低"
        s.close = "收盘"
        s.price = "价格"
        s.change = "涨跌"
        s.changePercent = "涨跌幅"
        s.range = "振幅"
        s.volume = "成交量"
        s.lineStyle = "折线图"
        s.areaStyle = "面积图"
        s.candlesStyle = "K线图"
        s.chartStyle = "图表类型"
        s.scrollToLatest = "回到最新K线"
        s.loadingHistory = "正在加载历史K线"
        return s
    }

    private var chartTimeFormatter: TimeFormatter {
        // The chart's X values are synthetic, while labels must always reflect
        // the original China futures exchange timestamps.
        let mapping = sessionAxis
        let daily = period >= 86_400
        return TimeFormatter { chartDate, _, context in
            guard let actual = mapping.nearestActual(for: chartDate) else { return "" }
            let formatter = DateFormatter()
            formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
            formatter.dateFormat = context == .crosshair
                ? "MM/dd HH:mm"
                : (daily ? "MM/dd" : "MM/dd HH:mm")
            return formatter.string(from: Date(timeIntervalSince1970: Double(actual)))
        }
    }

    private var theme: TradingChartTheme {
        var value = TradingChartTheme.standard
        value.bullish = MarketPalette.up
        value.bearish = MarketPalette.down
        value.grid = MarketPalette.divider.opacity(0.55)
        value.axisLabel = MarketPalette.muted
        value.crosshair = MarketPalette.ink.opacity(0.65)
        value.line = MarketPalette.accent
        value.currentPriceLine = MarketPalette.accent.opacity(0.65)
        value.priceBadgeBackground = MarketPalette.accent
        value.priceBadgeText = .white
        // The old 64pt dedicated price-label column swallowed too much of
        // the iPhone chart; 32pt still fits numbers like 5,150 at axis font 9.
        // The price is already readable in the contract header and quote strip.
        value.axisFont = .system(size: 9, weight: .medium)
        value.yAxisLabelWidth = 32
        value.indicatorPalette = [MarketPalette.sma, MarketPalette.ema20,
                                  MarketPalette.ema50, MarketPalette.wma]
        value.paneSeparator = MarketPalette.divider
        value.crosshairLabelBackground = MarketPalette.raised
        value.crosshairLabelText = MarketPalette.ink
        value.tooltipBackground = MarketPalette.raised.opacity(0.98)
        value.tooltipText = MarketPalette.ink
        value.legendText = MarketPalette.ink
        value.legendLabel = MarketPalette.muted
        value.candleCornerRadius = 0
        value.candleBodyWidthFactor = 0.75
        // Both styles remain in the native Swift Charts mark pipeline.
        value.hollowRisingCandles = hollowRising
        #if DEBUG
        if isReplay {
            value.hollowRisingCandles = !ProcessInfo.processInfo.arguments.contains("-qihui-native-candles")
        }
        #endif
        value.candleBullish = CandleAppearance.color(candleUp, fallback: MarketPalette.up)
        value.candleBearish = CandleAppearance.color(candleDown, fallback: MarketPalette.down)
        value.showsNeutralDoji = true
        value.dojiCandleColor = CandleAppearance.color(candleDoji, fallback: CandleAppearance.defaultDoji)
        return value
    }

    var body: some View {
        VStack(spacing: 0) {
            TradingChartView(model: model)
                .frame(maxHeight: .infinity)
            if displaySettings.enabled.contains(.intraday), !isReplay {
                IntradayPane(symbol:symbol,previousSettlement:previousSettlement)
                    .frame(height:120)
                    .id(symbol)
            }
            HStack(spacing: 6) {
                indicatorToolbar
                // Replaces the badge's historical-window jump action without
                // covering the last candle or reserving chart width for it.
                if !model.isAtLiveEdge {
                    Button {
                        model.scrollToLiveEdge()
                    } label: {
                        Image(systemName: "arrow.right.to.line.compact")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(MarketPalette.accent)
                            .frame(width: 28, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("回到最新K线")
                }
                drawingMenu
            }
            .padding(.horizontal, 6)
            .background(MarketPalette.surface)
        }
        .tradingChartTheme(theme)
        .tradingChartTimeFormatter(chartTimeFormatter)
        .tradingChartPriceFormatter(chartPriceFormatter)
        .tradingChartStrings(chartStrings)
        .background(MarketPalette.surface)
        .onAppear {
            model.onVerticalSwipe = isReplay ? nil : onVerticalSwipe
            model.style = .candles
            model.indicators = displaySettings.indicators()
            configureChart()
            feed.attach(key: feedKey, owner: feedOwner, fallback: bars,
                        receiveTail: { incoming in
                synchronizeTail(incoming)
            }) { previous, incoming in
                synchronizeBars(previous: previous ?? [], incoming: incoming)
            }
        }
        .onChange(of: displaySettings) { _, current in
            model.indicators = current.indicators()
            current.save()
        }
        .sheet(isPresented: $showingIndicatorSettings) {
            IndicatorSettingsView(settings: displaySettings,
                previewBars: Array((model.series.candles ?? []).suffix(20_000)).map {
                    FormulaBar(open:$0.open,high:$0.high,low:$0.low,close:$0.close,
                               volume:$0.volume,openInterest:$0.openInterest,closeInterest:$0.closeInterest)
                }) { updated in
                displaySettings = updated
            }
        }
        .onDisappear {
            feed.detach(owner: feedOwner)
            model.onEvent = nil
            model.onVerticalSwipe = nil
            historyTask?.cancel()
            historyTask = nil
            model.activeDrawingTool = nil
        }
    }

    private var indicatorToolbar: some View {
        HStack(spacing: 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(ChartIndicatorKind.available) { kind in
                        Button {
                            displaySettings = displaySettings.toggle(kind)
                        } label: {
                            Text(displaySettings.label(for: kind))
                                .font(.system(size: 12,
                                              weight: displaySettings.enabled.contains(kind) ? .semibold : .regular))
                                .foregroundStyle(displaySettings.enabled.contains(kind)
                                                 ? MarketPalette.accent : MarketPalette.muted)
                                .padding(.horizontal, 6)
                                .frame(height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("设置参数", systemImage: "slider.horizontal.3") {
                                showingIndicatorSettings = true
                            }
                            Button(displaySettings.enabled.contains(kind) ? "隐藏指标" : "显示指标") {
                                displaySettings = displaySettings.toggle(kind)
                            }
                        }
                    }
                    ForEach(displaySettings.formulas) { formula in
                        Button {
                            var updated = displaySettings
                            if let index = updated.formulas.firstIndex(where: { $0.id == formula.id }) {
                                updated.formulas[index].enabled.toggle()
                                displaySettings = updated
                            }
                        } label: {
                            Text(formula.name)
                                .font(.system(size: 12, weight: formula.enabled ? .semibold : .regular))
                                .foregroundStyle(formula.enabled ? MarketPalette.accent : MarketPalette.muted)
                                .padding(.horizontal, 6)
                                .frame(height: 30)
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(displaySettings.additionalAverages) { average in
                        Button {
                            var updated = displaySettings
                            updated.toggleAverage(id: average.id)
                            // Leave invalid combinations for the settings sheet to fix.
                            if updated.isValid { displaySettings = updated }
                            else { showingIndicatorSettings = true }
                        } label: {
                            Text(average.label)
                                .font(.system(size: 12,
                                              weight: average.enabled ? .semibold : .regular))
                                .foregroundStyle(average.enabled ? MarketPalette.accent : MarketPalette.muted)
                                .padding(.horizontal, 6)
                                .frame(height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("设置参数", systemImage: "slider.horizontal.3") {
                                showingIndicatorSettings = true
                            }
                            Button(average.enabled ? "隐藏指标" : "显示指标") {
                                var updated = displaySettings
                                updated.toggleAverage(id: average.id)
                                if updated.isValid { displaySettings = updated }
                                else { showingIndicatorSettings = true }
                            }
                        }
                    }
                }
            }
            Button {
                showingIndicatorSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14))
                    .foregroundStyle(MarketPalette.ink)
                    .frame(width: 34, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("指标参数设置")
        }
    }

    private var drawingMenu: some View {
        Menu {
            Section("画线工具") {
                Button("水平线", systemImage: "minus") { choose(.horizontalLine) }
                Button("趋势线", systemImage: "chart.line.uptrend.xyaxis") { choose(.trendLine) }
                Button("射线", systemImage: "arrow.up.right") { choose(.ray) }
                Button("水平射线",systemImage:"arrow.right") { choose(.horizontalRay) }
                Button("垂直线",systemImage:"line.diagonal") { choose(.verticalLine) }
                Button("矩形区域",systemImage:"rectangle") { choose(.rectangle) }
                Button("平行通道（三点）",systemImage:"line.3.horizontal") { choose(.parallelChannel) }
                Button("黄金分割",systemImage:"ruler") { choose(.fibonacci) }
                Button("价格测量",systemImage:"arrow.up.and.down") { choose(.priceMeasure) }
                Button("时间测量",systemImage:"arrow.left.and.right") { choose(.timeMeasure) }
            }
            if model.activeDrawingTool != nil {
                Button("取消画线", systemImage: "xmark") { model.activeDrawingTool = nil }
            }
            if model.selectedDrawingID != nil {
                Button("删除选中画线", systemImage: "trash", role: .destructive) {
                    model.deleteSelectedDrawing()
                }
            }
            if !model.drawings.isEmpty {
                Button("清空当前合约画线", systemImage: "trash.slash", role: .destructive) {
                    model.removeAllDrawings()
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.activeDrawingTool == nil ? "pencil.tip" : "pencil.tip.crop.circle.badge.plus")
                Text("画线")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(model.activeDrawingTool == nil ? MarketPalette.ink : MarketPalette.accent)
            .padding(.horizontal, 5)
            .frame(height: 32)
        }
        .accessibilityLabel("图表画线工具")
    }

    private func choose(_ tool: DrawingKind) {
        model.activeDrawingTool = model.activeDrawingTool == tool ? nil : tool
    }

    @MainActor
    private func configureChart() {
        model.onEvent = { event in
            switch event {
            case .crosshairChanged(let state):
                selectedCandleTime = state.flatMap { sessionAxis.actualTime(for: $0.time) }
            case .drawing:
                saveDrawings()
            case .approachedHistoryStart:
                guard !isReplay, historyTask == nil else { return }
                historyTask = Task { @MainActor in
                    await fetchOlderHistory()
                    historyTask = nil
                }
            default:
                break
            }
        }
    }

    /// Real SSE deltas replace or append a single candle, using the upstream
    /// API directly. No full-series comparison, history scan or quote synthesis.
    @MainActor
    private func synchronizeTail(_ incoming: [MarketBar]) {
        guard let last = incoming.last else { return }
        guard !model.series.isEmpty else {
            synchronizeBars(previous: [], incoming: incoming)
            return
        }
        let started = ProcessInfo.processInfo.systemUptime
        if sessionAxis.chartTime(for: last.time) == nil {
            sessionAxis.register([last.time], period: period)
        }
        guard sessionAxis.chartTime(for: last.time) != nil,
              model.update(chartCandle(last), interval: interval) != .ignored else {
            synchronizeBars(previous: [], incoming: incoming)
            return
        }
        model.currentPrice = last.close
        KlineDiagnostics.chartUpdated(symbol: symbol, period: period, newest: last, started: started)
        if isReplay, model.series.candles?.last == chartCandle(last) {
            onReplayApplied?(last, (ProcessInfo.processInfo.systemUptime - started) * 1000)
        }
    }

    @MainActor
    private func synchronizeBars(previous: [MarketBar], incoming: [MarketBar]) {
        guard !incoming.isEmpty else { return }
        let modelStarted = ProcessInfo.processInfo.systemUptime
        defer {
            KlineDiagnostics.chartUpdated(symbol: symbol, period: period, newest: incoming.last, started: modelStarted)
            if isReplay, let last = incoming.last,
               let plotted = model.series.candles?.last, plotted == chartCandle(last) {
                onReplayApplied?(last, (ProcessInfo.processInfo.systemUptime - modelStarted) * 1000)
            }
        }
        sessionAxis.register(incoming.map(\.time), period: period)
        if !drawingsRestored {
            restoreDrawings()
            drawingsRestored = true
        }
        // A TqSdk history reconciliation can revise the *previous* closed
        // candle without changing the number of bars or the newest candle.
        // Updating only the newest candle here silently leaves the prior
        // candlestick (and all following indicators) rendered from stale data.
        let earlierCandleChanged = KlineCorrectionPolicy.hasEarlierCorrection(
            previous: previous, incoming: incoming)
        let requiresReset = model.series.isEmpty
            || incoming.count < previous.count
            || previous.first?.time != incoming.first?.time
            || (previous.last?.time ?? 0) > (incoming.last?.time ?? 0)
            || incoming.count > previous.count + 1
            || earlierCandleChanged

        if requiresReset {
            // A corrected history snapshot must not discard older pages that
            // the user has already scrolled into; preserve the viewport when
            // only OHLCV values of existing candles were corrected.
            guard let incomingStart = sessionAxis.chartTime(for: incoming[0].time) else { return }
            let retained = model.series.candles?.filter { $0.time < incomingStart } ?? []
            let combined = retained + incoming.map(chartCandle)
            model.setSeries(ChartSeries(candles: combined, interval: interval),
                            scroll: earlierCandleChanged ? .preserve : .automatic)
            model.currentPrice = incoming.last?.close
            // A shorter first live page still supports older K-line paging.
            model.hasMoreHistory = historyDepth < 8964
        } else if let last = incoming.last, last != previous.last {
            model.update(chartCandle(last), interval: interval)
            model.currentPrice = last.close
        }
    }

    private func chartCandle(_ bar: MarketBar) -> Candle {
        Candle(time: sessionAxis.chartTime(for: bar.time)
                   ?? Date(timeIntervalSince1970: Double(bar.time)),
               open: bar.open, high: bar.high, low: bar.low, close: bar.close,
               volume: Double(bar.volume), openInterest: bar.openInterest,
                closeInterest: bar.closeInterest)
    }

    // Unlike chart indicator settings, drawing anchors must be stored with real
    // exchange timestamps. The chart uses synthetic, gap-free X coordinates.
    private var drawingsStorageKey: String {
        "qihui.real-time-drawings." + symbol + "." + String(period)
    }

    @MainActor
    private func saveDrawings() {
        let physical: [ChartDrawing] = model.drawings.compactMap { drawing in
            var copy = drawing
            let anchors = drawing.anchors.compactMap { anchor -> ChartAnchor? in
                guard let real = sessionAxis.nearestActual(for: anchor.time) else { return nil }
                return ChartAnchor(time: Date(timeIntervalSince1970: Double(real)), price: anchor.price)
            }
            guard anchors.count == drawing.anchors.count else { return nil }
            copy.anchors = anchors
            return copy
        }
        if let data = try? JSONEncoder().encode(physical) {
            UserDefaults.standard.set(data, forKey: drawingsStorageKey)
        }
    }

    @MainActor
    private func restoreDrawings() {
        guard let data = UserDefaults.standard.data(forKey: drawingsStorageKey),
              let saved = try? JSONDecoder().decode([ChartDrawing].self, from: data) else { return }
        model.drawings = saved.compactMap { drawing in
            var copy = drawing
            let anchors = drawing.anchors.compactMap { anchor -> ChartAnchor? in
                let real = Int64(anchor.time.timeIntervalSince1970)
                guard let mapped = sessionAxis.chartTime(for: real) else { return nil }
                return ChartAnchor(time: mapped, price: anchor.price)
            }
            guard anchors.count == drawing.anchors.count else { return nil }
            copy.anchors = anchors
            return copy
        }
    }

    @MainActor
    private func fetchOlderHistory() async {
        guard !model.isLoadingHistory, model.hasMoreHistory,
              let first = model.series.firstTime else { return }
        model.isLoadingHistory = true
        defer { model.isLoadingHistory = false }
        guard let before = sessionAxis.actualTime(for: first) else {
            model.isLoadingHistory = false
            return
        }
        do {
            // TqSdk's rolling serial has a bounded depth. Expand the lookback
            // only when needed; the chart keeps the user's historical anchor.
            while !Task.isCancelled {
                let older = try await MarketDataService.fetchOlder(
                    symbol: symbol, period: period, before: before,
                    count: KlineStartupMerge.historyPageCount, depth: historyDepth
                )
                try Task.checkCancellation()
                if !older.isEmpty {
                    sessionAxis.register(older.map(\.time), period: period)
                    model.prependHistory(ChartSeries(candles: older.map(chartCandle),
                                                     interval: interval))
                    historyDepth = min(8964, historyDepth + 450)
                    if older.count < KlineStartupMerge.historyPageCount && historyDepth == 8964 {
                        model.hasMoreHistory = false
                    }
                    return
                }
                if historyDepth >= 8964 {
                    model.hasMoreHistory = false
                    model.isLoadingHistory = false
                    return
                }
                historyDepth = min(8964, historyDepth + 900)
            }
        } catch is CancellationError {
            model.isLoadingHistory = false
        } catch {
            // A legacy VPS gateway may not yet support paging. Stop repeated
            // retries rather than freezing the chart's working interactions.
            model.isLoadingHistory = false
            if !Task.isCancelled { model.hasMoreHistory = false }
        }
    }
}
