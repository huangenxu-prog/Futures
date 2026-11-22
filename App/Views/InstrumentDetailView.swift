import SwiftUI
import Charts

struct InstrumentDetailView: View {
    let instrument: FuturesInstrument
    @Environment(\.dismiss) private var dismiss
    @State private var period = "15分"
    @State private var candles: [DemoCandle] = []
    @State private var loadError: String? = nil
    @State private var loading = false
    @State private var showQuote = false
    @State private var showIndicators = true
    @State private var selectedCandleIndex: Int? = nil
    @State private var selectedPrice: Double? = nil
    @State private var visibleStart = 0.0
    @State private var visibleCount = 100.0
    @State private var zoomBaseCount: Double? = nil
    @State private var zoomBaseStart: Double? = nil
    @State private var dragBaseStart: Double? = nil
    private let periods = ["1分","5分","15分","30分","60分","日线"]
    private var latestPrice: Double { candles.last?.close ?? instrument.lastPrice }
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
                    candleChart(height: max(240, geometry.size.height * 0.65))
                    macdPanel(height: max(115, geometry.size.height * 0.24))
                    quotePanel
                    Spacer(minLength: 0)
                } else {
                    Spacer()
                }
            }
            .padding(.horizontal, 3)
            .padding(.top, 2)
        }
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
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            let bars = try await MarketDataService.fetch(symbol: instrument.id, period: periodSeconds)
            try Task.checkCancellation()
            candles = DemoCandle.from(bars)
            visibleCount = Double(min(100, candles.count))
            visibleStart = Double(max(0, candles.count - Int(visibleCount)))
            selectedCandleIndex = nil
            selectedPrice = nil
        } catch is CancellationError {
            return
        } catch {
            candles = []
            loadError = error.localizedDescription
        }
    }
    private var topBar: some View {
        HStack(spacing: 7) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 30, height: 36)
            }
            Text(instrument.name).font(.system(size: 15, weight: .semibold))
            Text(instrument.id).font(.system(size: 11)).foregroundStyle(.gray)
                .lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 2)
            Text(latestPrice.formatted(.number.precision(.fractionLength(0...2))))
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(.red)
                .monospacedDigit()
            Menu {
                ForEach(periods, id: \.self) { p in Button(p) { period = p } }
            } label: {
                Text(period + "⌄").font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 7)
                    .background(.white.opacity(0.10), in: Capsule())
            }
            Button { showIndicators.toggle() } label: {
                Image(systemName: showIndicators ? "eye" : "eye.slash")
                    .font(.system(size: 15)).frame(width: 30, height: 36)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
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
                } else {
                    Text("K线").foregroundStyle(.gray)
                    Spacer(minLength: 2)
                    if showIndicators {
                        Text("EMA20").foregroundStyle(.orange)
                        Text("EMA50").foregroundStyle(.cyan)
                    }
                }
            }
            .frame(height: 18)
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
                    AxisGridLine().foregroundStyle(.white.opacity(0.08))
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing) { _ in
                    AxisValueLabel().foregroundStyle(.white.opacity(0.7))
                    AxisGridLine().foregroundStyle(.white.opacity(0.12))
                }
            }
            .frame(height:height - 28)
            .chartXSelection(value:$selectedCandleIndex)
            .simultaneousGesture(MagnificationGesture().onChanged { scale in
                if zoomBaseCount == nil {
                    zoomBaseCount = visibleCount
                    zoomBaseStart = visibleStart
                    dragBaseStart = nil
                }
                guard let baseCount = zoomBaseCount, let baseStart = zoomBaseStart else { return }
                let total = Double(candles.count)
                let nextCount = min(total, max(min(20,total), baseCount / Double(scale)))
                let fixedCenter = baseStart + (baseCount - 1) / 2
                let nextStart = fixedCenter - (nextCount - 1) / 2
                visibleCount = nextCount
                visibleStart = min(max(0, nextStart), total - nextCount)
            }.onEnded { _ in
                zoomBaseCount = nil
                zoomBaseStart = nil
            })
            .simultaneousGesture(DragGesture(minimumDistance: 18).onChanged { value in
                guard zoomBaseCount == nil else { return }
                if dragBaseStart == nil { dragBaseStart = visibleStart }
                guard let base = dragBaseStart else { return }
                let plotWidth = max(UIScreen.main.bounds.width - 48, 1)
                let shift = Double(value.translation.width / plotWidth) * visibleCount
                visibleStart = min(max(0, base - shift), Double(candles.count) - visibleCount)
            }.onEnded { _ in dragBaseStart = nil })
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
        VStack(alignment:.leading,spacing:5) {
            HStack { Text("MACD(12, 26, 9)").font(.caption.weight(.semibold)); Spacer(); Text("DIF"); Text("DEA") }.foregroundStyle(.white.opacity(0.75)).font(.caption2)
            Chart {
                ForEach(Array(candles.enumerated()),id:\.offset) { i,c in
                    BarMark(x:.value("序号",i),y:.value("MACD",c.hist),width:.fixed(4)).foregroundStyle(c.hist >= 0 ? .red : .green)
                    LineMark(x:.value("序号",i),y:.value("DIF",c.dif),series:.value("MACD线","DIF")).foregroundStyle(.orange).lineStyle(StrokeStyle(lineWidth:1.2))
                    LineMark(x:.value("序号",i),y:.value("DEA",c.dea),series:.value("MACD线","DEA")).foregroundStyle(.cyan).lineStyle(StrokeStyle(lineWidth:1.2))
                }
                RuleMark(y:.value("零轴",0)).foregroundStyle(.white.opacity(0.3))
                if let index = selectedCandleIndex, candles.indices.contains(index) {
                    RuleMark(x: .value("选中时间", index))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
                }
            }.chartYScale(domain: macdDomain).chartXScale(domain: visibleDomain).chartXAxis(.hidden).chartYAxis(.hidden).frame(height:height - 24)
        }.padding(.horizontal, 4).padding(.top, 3)
    }
    private var quotePanel: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showQuote.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text("行情详情")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.gray)
                    Spacer(minLength: 0)
                    Text("K线收盘 " + latestPrice.formatted())
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75))
                    Image(systemName: showQuote ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.gray)
                }
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showQuote {
                Divider().overlay(.white.opacity(0.1))
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 7) {
                        detailValue("卖一", "--")
                        detailValue("卖量", "--")
                        detailValue("买一", "--")
                        detailValue("买量", "--")
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .leading, spacing: 7) {
                        detailValue("最新价", "--")
                        detailValue("涨跌幅", "--")
                        detailValue("成交量", "--")
                        detailValue("持仓量", "--")
                        detailValue("增减仓", "--")
                    }
                }
                .padding(.vertical, 10)
                Text("实时盘口尚未接入 · 上方价格为最新K线收盘价")
                    .font(.system(size: 10))
                    .foregroundStyle(.gray.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 8)
            }
        }
        .padding(.horizontal, 9)
        .background(Color.white.opacity(0.035))
    }

    private func detailValue(_ label: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Text(label).foregroundStyle(.gray).frame(width: 43, alignment: .leading)
            Text(value).foregroundStyle(.white.opacity(0.8)).monospacedDigit()
        }
        .font(.system(size: 12, design: .rounded))
    }

}

private struct DemoCandle {
    let time: Int64
    let open, high, low, close, ema20, ema50, dif, dea, hist: Double
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
                              hist: 2 * (dif[i] - dea[i]), volume: bar.volume)
        }
    }
}
