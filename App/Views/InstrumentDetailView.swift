import SwiftUI
import Charts

struct InstrumentDetailView: View {
    @Environment(\.mainContracts) private var contracts
    let instrument: FuturesInstrument
    @Environment(\.dismiss) private var dismiss
    @State private var period = "15分"
    @State private var candles: [DemoCandle] = []
    @State private var loadError: String? = nil
    @State private var loading = false
    @State private var showingCachedData = false
    @State private var showIndicators = true
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
    private var sessionChangePercent: Double? {
        guard let bar = candles.last, let settlement = bar.preSettlement,
              settlement.isFinite, settlement > 0 else { return nil }
        let change = (bar.close / settlement - 1) * 100
        return change.isFinite ? change : nil
    }
    private var changeColor: Color {
        guard let change = sessionChangePercent else { return .white }
        return change > 0 ? .red : change < 0 ? .green : .white
    }
    private var changeText: String {
        guard let change = sessionChangePercent else { return "--" }
        return String(format: "%+.2f%%", change)
    }
    private var periodSeconds: Int { ["1分":60,"5分":300,"15分":900,"30分":1800,"60分":3600,"日线":86400][period] ?? 900 }
    private var priceDomain: ClosedRange<Double> {
        let low = candles.map(\.low).min() ?? latestPrice * 0.97
        let high = candles.map(\.high).max() ?? latestPrice * 1.03
        let padding = max((high - low) * 0.10, latestPrice * 0.002)
        return (low - padding)...(high + padding)
    }
    private var visibleDomain: ClosedRange<Double> { visibleStart...(visibleStart + visibleCount - 1) }
    private var macdDomain: ClosedRange<Double> {
        let peak = candles.map { max(abs($0.hist), abs($0.dif), abs($0.dea)) }.max() ?? 1
        let limit = max(peak * 1.25, latestPrice * 0.0005)
        return -limit...limit
    }
    var body: some View {
        GeometryReader { geometry in
            let quoteHeight: CGFloat = 62
            let macdHeight = min(128, geometry.size.height * 0.16)
            let candleHeight = max(32, geometry.size.height - 43 - quoteHeight - macdHeight - 11)
            VStack(spacing: 3) {
                topBar
                if loading && candles.isEmpty {
                    Spacer()
                    ProgressView("正在获取行情")
                    Spacer()
                } else if let loadError, candles.isEmpty {
                    Spacer()
                    Text(loadError).font(.caption).foregroundStyle(.orange)
                    Spacer()
                } else if !candles.isEmpty {
                    candleChart(height: candleHeight)
                    macdPanel(height: macdHeight)
                    quoteStrip
                } else {
                    Spacer()
                }
            }
            .padding(.horizontal, 3)
            .padding(.top, 2)
        }
        .simultaneousGesture(TapGesture().onEnded {
            selectedCandleIndex = nil
            crosshairActive = false
        })
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.dark)
        .task(id: period) { await loadCandles() }
        .onAppear {
            NotificationCenter.default.post(name: .qihuiDetailVisibility, object: true)
        }
        .onDisappear {
            NotificationCenter.default.post(name: .qihuiDetailVisibility, object: false)
        }
    }
    @MainActor private func loadCandles() async {
        let requestedPeriod = periodSeconds
        let symbol = instrument.id
        // Render persisted data immediately; update it quietly in the background.
        if let cached = MarketDataService.cached(symbol: symbol, period: requestedPeriod) {
            candles = DemoCandle.from(cached)
            visibleCount = Double(min(100, candles.count))
            visibleStart = Double(max(0, candles.count - Int(visibleCount)))
            selectedCandleIndex = nil
            crosshairActive = false
            showingCachedData = true
        } else {
            candles = []
            selectedCandleIndex = nil
            crosshairActive = false
            showingCachedData = false
        }
        loadError = nil
        loading = candles.isEmpty
        defer { loading = false }
        do {
            let bars = try await MarketDataService.fetch(symbol: symbol, period: requestedPeriod)
            try Task.checkCancellation()
            guard requestedPeriod == periodSeconds else { return }
            let wasEmpty = candles.isEmpty
            let wasAtLatest = visibleStart + visibleCount >= Double(candles.count) - 1
            candles = DemoCandle.from(bars)
            showingCachedData = false
            if wasEmpty {
                visibleCount = Double(min(100, candles.count))
                visibleStart = Double(max(0, candles.count - Int(visibleCount)))
                selectedCandleIndex = nil
            } else if wasAtLatest {
                visibleStart = max(0, Double(candles.count) - visibleCount)
            }
        } catch is CancellationError {
            return
        } catch {
            if candles.isEmpty {
                loadError = error.localizedDescription
            } else {
                showingCachedData = true
            }
        }
    }
    private var topBar: some View {
        HStack(spacing: 5) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 25, height: 36)
            }
            Text(instrument.name + (contracts[instrument.id]?.month ?? ""))
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            Text(contracts[instrument.id]?.code ?? instrument.id)
                .font(.system(size: 10))
                .foregroundStyle(.gray)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 1)
            Text(candles.last?.close.formatted(.number.precision(.fractionLength(0...2))) ?? "--")
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
                    .background(.white.opacity(0.10), in: Capsule())
            }
            Button { showIndicators.toggle() } label: {
                Image(systemName: showIndicators ? "eye" : "eye.slash")
                    .font(.system(size: 15))
                    .frame(width: 26, height: 36)
            }
        }
        .foregroundStyle(.white)
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
    private func candleChart(height: CGFloat) -> some View {
        VStack(alignment:.leading,spacing:6) {
            HStack(spacing: 5) {
                if let index = selectedCandleIndex, candles.indices.contains(index) {
                    selectedCandleInfo(candles[index], index: index)
                } else if showIndicators {
                    Text("EMA20").foregroundStyle(.orange)
                    Text("EMA50").foregroundStyle(.cyan)
                    Spacer(minLength: 0)
                }
            }
            .font(.system(size: 10, weight: .medium))
            .frame(height: 18, alignment: .leading)
            .clipped()
            Chart {
                ForEach(Array(candles.enumerated()),id:\.offset) { i,c in
                    RuleMark(x:.value("序号",i),yStart:.value("低",c.low),yEnd:.value("高",c.high)).foregroundStyle(c.close >= c.open ? .red : .green).lineStyle(StrokeStyle(lineWidth:1))
                    RectangleMark(x:.value("序号",i),yStart:.value("开",min(c.open,c.close)),yEnd:.value("收",max(c.open,c.close)),width:4).foregroundStyle(c.close >= c.open ? .red : Color(red:0.0,green:0.88,blue:0.92))

                    if showIndicators {
                        LineMark(x:.value("序号",i),y:.value("EMA20",c.ema20),series:.value("均线","EMA20")).foregroundStyle(.orange).lineStyle(StrokeStyle(lineWidth:1.4))
                        LineMark(x:.value("序号",i),y:.value("EMA50",c.ema50),series:.value("均线","EMA50")).foregroundStyle(.cyan).lineStyle(StrokeStyle(lineWidth:1.4))
                    }
                }
                if let index = selectedCandleIndex, candles.indices.contains(index) {
                    RuleMark(x: .value("十字时间", index))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
                    RuleMark(y: .value("十字价格", candles[index].close))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
                }
            }
            .chartYScale(domain: priceDomain)
            .chartXScale(domain: visibleDomain)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisValueLabel {
                        if let index = value.as(Int.self) {
                            Text(timeLabel(index)).font(.system(size: 9)).foregroundStyle(.gray)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing) { _ in
                    AxisValueLabel().foregroundStyle(.white.opacity(0.7))
                    AxisGridLine().foregroundStyle(.white.opacity(0.075))
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
                                               max(0, Double(candles.count) - visibleCount))
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
                                               max(0, total - nextCount))
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

    private func selectedCandleInfo(_ candle: DemoCandle, index: Int) -> some View {
        HStack(spacing: 5) {
            Text(timeLabel(index)).foregroundStyle(.gray)
            Text("开" + candle.open.formatted())
            Text("高" + candle.high.formatted())
            Text("低" + candle.low.formatted())
            Text("收" + candle.close.formatted())
        }
        .font(.system(size: 10, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white.opacity(0.85))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func macdPanel(height: CGFloat) -> some View {
        VStack(alignment:.leading,spacing:3) {
            HStack { Text("MACD(12,26,9)").font(.system(size: 10, weight: .medium)); Spacer(); Text("DIF"); Text("DEA") }.foregroundStyle(.white.opacity(0.65)).font(.system(size: 10))
            Chart {
                ForEach(Array(candles.enumerated()),id:\.offset) { i,c in
                    BarMark(x:.value("序号",i),y:.value("MACD",c.hist),width:.fixed(4)).foregroundStyle(c.hist >= 0 ? .red : .green)
                    LineMark(x:.value("序号",i),y:.value("DIF",c.dif),series:.value("MACD线","DIF")).foregroundStyle(.orange).lineStyle(StrokeStyle(lineWidth:1.2))
                    LineMark(x:.value("序号",i),y:.value("DEA",c.dea),series:.value("MACD线","DEA")).foregroundStyle(.cyan).lineStyle(StrokeStyle(lineWidth:1.2))
                }
                RuleMark(y:.value("零轴",0)).foregroundStyle(.white.opacity(0.10))
                if let index = selectedCandleIndex, candles.indices.contains(index) {
                    RuleMark(x: .value("选中时间", index))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
                }
            }.chartYScale(domain: macdDomain).chartXScale(domain: visibleDomain).chartXAxis(.hidden).chartYAxis(.hidden).frame(height:height - 20)
        }.padding(.horizontal, 4).padding(.top, 2)
    }
    private var quoteStrip: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                smallQuote("卖1", "--", .white)
                smallQuote("买1", "--", .white)
                smallQuote("持仓", "--", .white)
            }
            .frame(height: 31)
            .overlay(alignment: .top) { quoteSeparator }
            HStack(spacing: 12) {
                smallQuote("成交", "--", .white)
                smallQuote("增仓", "--", .white)
                smallQuote("幅度", changeText, changeColor)
            }
            .frame(height: 31)
            .overlay(alignment: .top) { quoteSeparator }
        }
        .padding(.horizontal, 6)
    }

    private var quoteSeparator: some View {
        Rectangle().fill(.white.opacity(0.075)).frame(height: 0.5)
    }

    private func smallQuote(_ label: String, _ value: String, _ tint: Color) -> some View {
        HStack(spacing: 2) {
            Text(label).foregroundStyle(.gray)
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
