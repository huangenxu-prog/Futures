import SwiftUI
import TradingChart

/// The interaction engine is supplied by TradingChart (MIT).
/// Qihui retains its own toolbar, quote strip, colors and TqSdk data source.
@available(iOS 17.0, *)
struct ProfessionalChartHost: View {
    let symbol: String
    let period: Int
    let bars: [MarketBar]
    @Binding var showingIndicatorSettings: Bool
    @Binding var selectedCandleTime: Int64?


    @State private var model: TradingChartModel = {
        var configuration = TradingChartConfiguration()
        configuration.viewport.candleVisibleBars = 52
        // Previous 6-bar right gap consumed too much chart width on iPhone.
        // Leave only a small breathing room; the chart engine still adds
        // enough space if the live-price badge would cover the last candle.
        configuration.viewport.trailingPaddingBars = 1.25
        configuration.viewport.maxTrailingPaddingFraction = 0.06
        configuration.paneHeight = 110
        configuration.maxLiveBarCount = nil
        configuration.showsLegend = true
        configuration.showsHighLowMarkers = true
        configuration.stylePicker = StylePickerOptions(
            titles: [.line: "折线图", .area: "面积图", .candles: "K线图"],
            accessibilityLabel: "图表类型"
        )
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

    private var chartTimeFormatter: TimeFormatter {
        // The chart's X values are synthetic, while labels must always reflect
        // the original China futures exchange timestamps.
        let mapping = sessionAxis
        let daily = period == 86_400
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
        // Compact the live price marker without removing the useful
        // tap-to-latest affordance when viewing older candles.
        value.priceBadgeFont = .system(size: 10, weight: .semibold, design: .monospaced)
        value.yAxisLabelWidth = 64
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
        return value
    }

    var body: some View {
        VStack(spacing: 0) {
            TradingChartView(model: model)
                .frame(maxHeight: .infinity)
            HStack(spacing: 6) {
                indicatorToolbar
                drawingMenu
            }
            .padding(.horizontal, 6)
            .background(MarketPalette.surface)
        }
        .tradingChartTheme(theme)
        .tradingChartTimeFormatter(chartTimeFormatter)
        .background(MarketPalette.surface)
        .onAppear {
            model.indicators = displaySettings.indicators()
            configureChart()
            synchronizeBars(previous: [], incoming: bars)
        }
        .onChange(of: displaySettings) { _, current in
            model.indicators = current.indicators()
            current.save()
        }
        .sheet(isPresented: $showingIndicatorSettings) {
            IndicatorSettingsView(settings: displaySettings) { updated in
                displaySettings = updated
            }
        }
        .onChange(of: bars) { previous, incoming in
            synchronizeBars(previous: previous, incoming: incoming)
        }
        .onDisappear {
            model.onEvent = nil
            historyTask?.cancel()
            historyTask = nil
            model.activeDrawingTool = nil
        }
    }

    private var indicatorToolbar: some View {
        HStack(spacing: 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(ChartIndicatorKind.allCases) { kind in
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
                    ForEach(displaySettings.additionalAverages) { average in
                        Button {
                            var updated = displaySettings
                            updated.toggleAverage(id: average.id)
                            // Leave invalid combinations for the settings sheet to fix.
                            if updated.isValid { displaySettings = updated }
                            else { showingIndicatorSettings = true }
                        } label: {
                            Text("\(average.type.rawValue)\(average.period)")
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
                guard historyTask == nil else { return }
                historyTask = Task { @MainActor in
                    await fetchOlderHistory()
                    historyTask = nil
                }
            default:
                break
            }
        }
    }

    @MainActor
    private func synchronizeBars(previous: [MarketBar], incoming: [MarketBar]) {
        guard !incoming.isEmpty else { return }
        sessionAxis.register(incoming.map(\.time), period: period)
        if !drawingsRestored {
            restoreDrawings()
            drawingsRestored = true
        }
        let requiresReset = model.series.isEmpty
            || incoming.count < previous.count
            || previous.first?.time != incoming.first?.time
            || (previous.last?.time ?? 0) > (incoming.last?.time ?? 0)
            || incoming.count > previous.count + 1

        if requiresReset {
            // A fresh 500-bar snapshot must not discard older pages that the
            // user has already scrolled into.
            guard let incomingStart = sessionAxis.chartTime(for: incoming[0].time) else { return }
            let retained = model.series.candles?.filter { $0.time < incomingStart } ?? []
            let combined = retained + incoming.map(chartCandle)
            model.setSeries(ChartSeries(candles: combined, interval: interval),
                            scroll: .automatic)
            model.currentPrice = incoming.last?.close
            model.hasMoreHistory = combined.count >= 300
        } else if let last = incoming.last, last != previous.last {
            model.update(chartCandle(last), interval: interval)
            model.currentPrice = last.close
        }
    }

    private func chartCandle(_ bar: MarketBar) -> Candle {
        Candle(time: sessionAxis.chartTime(for: bar.time)
                   ?? Date(timeIntervalSince1970: Double(bar.time)),
               open: bar.open, high: bar.high, low: bar.low, close: bar.close,
               volume: Double(bar.volume))
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
                    count: 300, depth: historyDepth
                )
                if !older.isEmpty {
                    sessionAxis.register(older.map(\.time), period: period)
                    model.prependHistory(ChartSeries(candles: older.map(chartCandle),
                                                     interval: interval))
                    historyDepth = min(8964, historyDepth + 450)
                    if older.count < 300 && historyDepth == 8964 {
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
            model.hasMoreHistory = false
        }
    }
}
