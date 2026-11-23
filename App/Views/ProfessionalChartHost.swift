import SwiftUI
import TradingChart

/// The interaction engine is supplied by TradingChart (MIT).
/// Qihui retains its own toolbar, quote strip, colors and TqSdk data source.
@available(iOS 17.0, *)
struct ProfessionalChartHost: View {
    let symbol: String
    let period: Int
    let bars: [MarketBar]
    let showEMA: Bool
    let showVolume: Bool
    @Binding var selectedCandleTime: Int64?

    @State private var model: TradingChartModel = {
        var configuration = TradingChartConfiguration()
        configuration.viewport.candleVisibleBars = 80
        configuration.paneHeight = 104
        configuration.maxLiveBarCount = nil
        configuration.showsLegend = false
        configuration.showsHighLowMarkers = false
        configuration.stylePicker = nil
        configuration.isDrawingEnabled = false
        configuration.isCrosshairEnabled = true
        configuration.isZoomEnabled = true
        configuration.historyPrefetchThreshold = .visibleWindows(1)
        return TradingChartModel(style: .candles, configuration: configuration)
    }()

    @State private var sessionAxis = TradingSessionAxis()
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
        value.bullish = Color.red
        value.bearish = Color(red: 0, green: 252.0 / 255, blue: 252.0 / 255)
        value.grid = .white.opacity(0.045)
        value.axisLabel = .white.opacity(0.62)
        value.crosshair = .white.opacity(0.78)
        value.indicatorPalette = [.white, .yellow, .white, .yellow]
        value.paneSeparator = .white.opacity(0.07)
        value.tooltipBackground = .black.opacity(0.94)
        value.tooltipText = .white
        value.legendText = .white
        value.legendLabel = .gray
        value.candleCornerRadius = 0
        value.candleBodyWidthFactor = 0.75
        return value
    }

    var body: some View {
        TradingChartView(model: model)
            .tradingChartTheme(theme)
            .tradingChartTimeFormatter(chartTimeFormatter)
            .background(Color.black)
            .onAppear {
                configureChart()
                synchronizeBars(previous: [], incoming: bars)
            }
            .onChange(of: bars) { previous, incoming in
                synchronizeBars(previous: previous, incoming: incoming)
            }
            .onChange(of: showEMA) { _, _ in applyIndicators() }
            .onChange(of: showVolume) { _, _ in applyIndicators() }
            .onDisappear {
                model.onEvent = nil
                historyTask?.cancel()
                historyTask = nil
            }
    }

    @MainActor
    private func configureChart() {
        applyIndicators()
        model.onEvent = { event in
            switch event {
            case .crosshairChanged(let state):
                selectedCandleTime = state.flatMap { sessionAxis.actualTime(for: $0.time) }
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
    private func applyIndicators() {
        var indicators: [any ChartIndicator] = []
        if showEMA {
            indicators.append(EMA(period: 20))
            indicators.append(EMA(period: 50))
        }
        if showVolume {
            indicators.append(Volume())
        } else {
            indicators.append(MACD(fast: 12, slow: 26, signal: 9))
        }
        model.indicators = indicators
    }

    @MainActor
    private func synchronizeBars(previous: [MarketBar], incoming: [MarketBar]) {
        guard !incoming.isEmpty else { return }
        sessionAxis.register(incoming.map(\.time), period: period)
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
