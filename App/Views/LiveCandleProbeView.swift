#if QIHUI_LIVE_PROBE
import SwiftUI
import TradingChart

/// Separate, read-only device build. The only network request is the existing
/// real K-line SSE endpoint. No quotes, HTTP polling, history prefetch,
/// local history cache, synthetic prices, or ProfessionalChartHost.
@MainActor
struct LiveCandleProbeView: View {
    private static let symbol = "CZCE.CF701"
    private static let period = 300
    private static let interval = ChartInterval(seconds: 300)
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: TradingChartModel = {
        var config = TradingChartConfiguration()
        config.viewport.candleVisibleBars = 52
        config.maxLiveBarCount = 500
        let chart = TradingChartModel(
            series: ChartSeries(candles: [], interval: Self.interval),
            style: .candles, configuration: config)
        chart.indicators = [EMA(period: 20), EMA(period: 50), MACD()]
        chart.hasMoreHistory = false
        return chart
    }()
    @State private var status = "连接中"
    @State private var count = 0
    @State private var lastBar: MarketBar?
    @State private var lastReceiveUptime: Double?
    @State private var receiveGap: Double?
    @State private var applyLag: Double?
    @State private var lastReceive = "--"
    @State private var modelMS = 0.0
    private var theme: TradingChartTheme {
        var t = TradingChartTheme.standard
        t.bullish = .red
        t.bearish = .green
        // Keep the original upstream candle renderer, not Qihui's Canvas.
        t.hollowRisingCandles = false
        return t
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("棉花 CF701 · 5分钟").font(.headline)
                Spacer()
                Text(status).font(.caption)
                    .foregroundStyle(status == "实时连接" ? Color.green : Color.orange)
            }
            HStack {
                Text(lastBar.map { String(format: "%.0f", $0.close) } ?? "--")
                    .font(.title2.monospacedDigit())
                Spacer()
                Text("本K成交量 \(lastBar.map { String($0.volume) } ?? "--")")
                    .font(.subheadline.monospacedDigit())
            }
            Text("已收 \(count) 条 · 最近 \(lastReceive)")
                .font(.caption.monospacedDigit())
            Text("接收间隔 \(ms(receiveGap)) · 接收至处理 \(ms(applyLag)) · 模型 \(String(format: "%.1f", modelMS)) ms")
                .font(.caption2.monospacedDigit())
            TradingChartView(model: model)
                .tradingChartTheme(theme)
                .frame(maxHeight: .infinity)
            Text("真实行情 / 原版实心K线 / 单一SSE连接 / 无报价修正")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .preferredColorScheme(.dark)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                status = "连接中"
                do {
                    try await MarketDataService.streamCandles(
                        symbol: Self.symbol, period: Self.period, count: 200
                    ) { event in
                        guard !Task.isCancelled, event.symbol == Self.symbol else { return }
                        apply(event)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    status = "重新连接"
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
            }
        }
    }

    private func apply(_ event: MarketDataService.CandlePush) {
        let started = ProcessInfo.processInfo.systemUptime
        let newest: MarketBar
        if let bars = event.bars, !bars.isEmpty {
            // Full snapshot is the gateway's authoritative bounded history,
            // including any corrections to earlier bars.
            let sorted = bars.sorted { $0.time < $1.time }
            guard let last = sorted.last else { return }
            newest = last
            model.setSeries(ChartSeries(candles: sorted.map(candle), interval: Self.interval),
                            scroll: model.series.isEmpty ? .liveEdge : .automatic)
        } else if let bar = event.bar {
            guard model.update(candle(bar), interval: Self.interval) != .ignored else { return }
            newest = bar
        } else { return }
        model.currentPrice = newest.close
        modelMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
        if let received = event.phoneUptime {
            if let previous = lastReceiveUptime { receiveGap = max(0, received - previous) }
            lastReceiveUptime = received
            applyLag = max(0, started - received)
        }
        if let epoch = event.phoneEpoch {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
            lastReceive = formatter.string(from: Date(timeIntervalSince1970: epoch))
        }
        lastBar = newest
        count += 1
        status = "实时连接"
        SSEReceiveTrace.record("probe count=\(count) close=\(newest.close) volume=\(newest.volume) model_ms=\(String(format: "%.2f", modelMS))")
    }

    private func candle(_ bar: MarketBar) -> Candle {
        Candle(time: Date(timeIntervalSince1970: Double(bar.time)),
               open: bar.open, high: bar.high, low: bar.low,
               close: bar.close, volume: Double(bar.volume))
    }

    private func ms(_ seconds: Double?) -> String {
        seconds.map { String(format: "%.1f ms", $0 * 1000) } ?? "--"
    }
}
#endif
