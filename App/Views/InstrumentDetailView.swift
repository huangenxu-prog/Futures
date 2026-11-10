import SwiftUI
import Charts

struct InstrumentDetailView: View {
    let instrument: FuturesInstrument
    @Environment(\.dismiss) private var dismiss
    @State private var period = "15分"
    @State private var showIndicators = true
    @State private var selectedCandleIndex: Int? = nil
    @State private var visibleStart = 0.0
    @State private var visibleCount = 100.0
    @State private var zoomBaseCount: Double? = nil
    @State private var dragBaseStart: Double? = nil
    private let periods = ["1分","5分","15分","30分","60分","日线"]
    private var candles: [DemoCandle] { DemoCandle.make(base:instrument.lastPrice,count:100) }
    private var priceDomain: ClosedRange<Double> {
        let low = candles.map(\.low).min() ?? instrument.lastPrice * 0.97
        let high = candles.map(\.high).max() ?? instrument.lastPrice * 1.03
        let padding = max((high - low) * 0.10, instrument.lastPrice * 0.002)
        return (low - padding)...(high + padding)
    }
    private var visibleDomain: ClosedRange<Double> { visibleStart...(visibleStart + visibleCount - 1) }
    private var macdDomain: ClosedRange<Double> {
        let peak = candles.map { max(abs($0.hist), abs($0.dif), abs($0.dea)) }.max() ?? 1
        let limit = max(peak * 1.25, instrument.lastPrice * 0.0005)
        return -limit...limit
    }
    var body: some View {
        ScrollView {
            VStack(spacing:10) {
                topBar
                candleChart
                macdPanel
                quotePanel
                Text("本地生成的演示行情，不代表真实市场行情").font(.caption2).foregroundStyle(.gray).padding(.bottom,8)
            }.padding(.horizontal,10).padding(.top,-24)
        }
        .background(Color.black)
        .toolbar(.hidden, for:.navigationBar)
        .preferredColorScheme(.dark)
    }
    private var topBar: some View {
        HStack(spacing:8) {
            Button { dismiss() } label: {
                Image(systemName:"chevron.left")
                    .font(.system(size:18,weight:.medium))
                    .foregroundStyle(.white)
                    .frame(width:36,height:36)
            }
            Text(instrument.name).font(.system(size:15,weight:.semibold))
            Text(instrument.id).font(.caption).foregroundStyle(.gray)
            Rectangle().fill(.white.opacity(0.3)).frame(width:1,height:20)
            Text(Date.now.formatted(date:.numeric,time:.shortened))
                .font(.caption).foregroundStyle(.white.opacity(0.8))
                .lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength:2)
            Menu { ForEach(periods,id:\.self){ p in Button(p){period=p} } } label: {
                Text(period+"⌄").font(.caption.weight(.semibold))
                    .padding(.horizontal,10).padding(.vertical,8)
                    .background(.white.opacity(0.12),in:Capsule())
            }
            Button { showIndicators.toggle() } label: {
                Image(systemName:"eye").padding(8)
                    .background(.white.opacity(0.12),in:Circle())
            }
        }
        .padding(.horizontal,7).padding(.vertical,6)
        .background(.ultraThinMaterial,in:Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.35),lineWidth:1))
    }
    private var candleChart: some View {
        VStack(alignment:.leading,spacing:6) {
            HStack { Text("K线").font(.caption).foregroundStyle(.gray); Spacer(); if showIndicators { Text("EMA20").foregroundStyle(.orange); Text("EMA50").foregroundStyle(.cyan) } }.font(.caption2)
            if let index = selectedCandleIndex, candles.indices.contains(index) {
                selectedCandleInfo(candles[index], index:index)
            }
            Chart {
                ForEach(Array(candles.enumerated()),id:\.offset) { i,c in
                    RuleMark(x:.value("序号",i),yStart:.value("低",c.low),yEnd:.value("高",c.high)).foregroundStyle(c.close >= c.open ? .red : .green).lineStyle(StrokeStyle(lineWidth:1))
                    RectangleMark(x:.value("序号",i),yStart:.value("开",min(c.open,c.close)),yEnd:.value("收",max(c.open,c.close)),width:4).foregroundStyle(c.close >= c.open ? .red : Color(red:0.0,green:0.88,blue:0.92))
                    if selectedCandleIndex == i {
                        RuleMark(x:.value("选中K线",i))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineStyle(StrokeStyle(lineWidth:1,dash:[4,3]))
                    }
                    if showIndicators {
                        LineMark(x:.value("序号",i),y:.value("EMA20",c.ema20),series:.value("均线","EMA20")).foregroundStyle(.orange).lineStyle(StrokeStyle(lineWidth:1.4))
                        LineMark(x:.value("序号",i),y:.value("EMA50",c.ema50),series:.value("均线","EMA50")).foregroundStyle(.cyan).lineStyle(StrokeStyle(lineWidth:1.4))
                    }
                }
            }
            .chartYScale(domain: priceDomain)
            .chartXScale(domain: visibleDomain)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisValueLabel().foregroundStyle(.white.opacity(0.65))
                    AxisGridLine().foregroundStyle(.red.opacity(0.16))
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing) { _ in
                    AxisValueLabel().foregroundStyle(.white.opacity(0.7))
                    AxisGridLine().foregroundStyle(.white.opacity(0.12))
                }
            }
            .frame(height:300)
            .chartXSelection(value:$selectedCandleIndex)
            .simultaneousGesture(MagnificationGesture().onChanged { scale in
                if zoomBaseCount == nil { zoomBaseCount = visibleCount }
                guard let base = zoomBaseCount else { return }
                let nextCount = min(100, max(20, base / Double(scale)))
                let center = visibleStart + (visibleCount - 1) / 2
                visibleCount = nextCount
                visibleStart = min(max(0, center - (nextCount - 1) / 2), 100 - nextCount)
            }.onEnded { _ in zoomBaseCount = nil })
            .simultaneousGesture(DragGesture(minimumDistance: 18).onChanged { value in
                if dragBaseStart == nil { dragBaseStart = visibleStart }
                guard let base = dragBaseStart else { return }
                let shift = Double(value.translation.width / 320) * visibleCount
                visibleStart = min(max(0, base - shift), 100 - visibleCount)
            }.onEnded { _ in dragBaseStart = nil })
            .onTapGesture(count:2) {
                withAnimation(.easeOut(duration:0.2)) {
                    visibleStart = 0
                    visibleCount = 100
                    selectedCandleIndex = nil
                }
            }
        }.padding(10).background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:16)).overlay(RoundedRectangle(cornerRadius:16).stroke(.white.opacity(0.22),lineWidth:1))
    }

    private func selectedCandleInfo(_ candle:DemoCandle,index:Int)->some View {
        let change = candle.close - candle.open
        let percent = candle.open == 0 ? 0 : change / candle.open * 100
        let date = Calendar.current.date(byAdding:.minute,value:(index - 99) * 15,to:Date()) ?? Date()
        return VStack(alignment:.leading,spacing:4) {
            HStack {
                Text("选中 K线").foregroundStyle(.white)
                Spacer()
                Text(date.formatted(date:.numeric,time:.shortened)).foregroundStyle(.gray)
            }
            HStack(spacing:12) {
                valueCell("开盘",candle.open)
                valueCell("最高",candle.high)
                valueCell("最低",candle.low)
                valueCell("收盘",candle.close)
                Spacer(minLength:0)
                Text(String(format:"%+.2f%%",percent))
                    .foregroundStyle(change >= 0 ? .red : .green)
            }
        }
        .font(.system(size:10,design:.rounded))
        .padding(7)
        .frame(maxWidth:.infinity,alignment:.leading)
        .background(Color.black.opacity(0.72),in:RoundedRectangle(cornerRadius:7))
        .overlay(RoundedRectangle(cornerRadius:7).stroke(.white.opacity(0.18),lineWidth:0.7))
    }

    private func valueCell(_ title:String,_ value:Double)->some View {
        VStack(alignment:.leading,spacing:2) {
            Text(title).foregroundStyle(.gray)
            Text(value.formatted(.number.precision(.fractionLength(0...2))))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private var macdPanel: some View {
        VStack(alignment:.leading,spacing:5) {
            HStack { Text("MACD(12, 26, 9)").font(.caption.weight(.semibold)); Spacer(); Text("DIF"); Text("DEA") }.foregroundStyle(.white.opacity(0.75)).font(.caption2)
            Chart {
                ForEach(Array(candles.enumerated()),id:\.offset) { i,c in
                    BarMark(x:.value("序号",i),y:.value("MACD",c.hist),width:.fixed(4)).foregroundStyle(c.hist >= 0 ? .red : .green)
                    LineMark(x:.value("序号",i),y:.value("DIF",c.dif),series:.value("MACD线","DIF")).foregroundStyle(.orange).lineStyle(StrokeStyle(lineWidth:1.2))
                    LineMark(x:.value("序号",i),y:.value("DEA",c.dea),series:.value("MACD线","DEA")).foregroundStyle(.cyan).lineStyle(StrokeStyle(lineWidth:1.2))
                }
                RuleMark(y:.value("零轴",0)).foregroundStyle(.white.opacity(0.3))
            }.chartYScale(domain: macdDomain).chartXScale(domain: visibleDomain).chartXAxis(.hidden).chartYAxis(.hidden).frame(height:150)
        }.padding(10).background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:16)).overlay(RoundedRectangle(cornerRadius:16).stroke(.white.opacity(0.2),lineWidth:1))
    }
    private var quotePanel: some View {
        HStack(spacing:8) {
            VStack(alignment:.leading,spacing:8) {
                quoteRow("卖盘",price:instrument.lastPrice+1,size:"52")
                quoteRow("买盘",price:instrument.lastPrice,size:"63")
                HStack { Text("持仓量"); Spacer(); Text("391338"); Text("-24978").foregroundStyle(.green) }.font(.system(size:13,design:.rounded))
            }.padding(9).background(.white.opacity(0.06),in:RoundedRectangle(cornerRadius:10))
            VStack(alignment:.leading,spacing:4) {
                Text(instrument.lastPrice.formatted()).font(.system(size:29,weight:.medium,design:.rounded)).foregroundStyle(instrument.isRising ? .red : .green).minimumScaleFactor(0.7).lineLimit(1)
                Text(String(format:"%.2f / %.2f%%",instrument.change,instrument.changePercent)).font(.system(size:13,design:.rounded)).foregroundStyle(instrument.isRising ? .red : .green)
                Text("成交量 387415").font(.caption).foregroundStyle(.white.opacity(0.65))
            }.frame(maxWidth:.infinity,alignment:.leading)
        }.padding(8).background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:16)).overlay(RoundedRectangle(cornerRadius:16).stroke(.white.opacity(0.2),lineWidth:1))
    }
    private func quoteRow(_ title:String,price:Double,size:String)->some View { HStack { Text(title); Spacer(); Text(price.formatted()).foregroundStyle(.red); Text(size) }.font(.system(size:13,design:.rounded)) }
}

private struct DemoCandle {
    let open,high,low,close,ema20,ema50,dif,dea,hist: Double
    static func make(base:Double,count:Int)->[DemoCandle] {
        guard count > 1 else { return [] }
        var closes:[Double] = []
        var price = base * 0.972
        for i in 0..<count {
            let x = Double(i)
            let cycle = sin(x * 0.105) * 0.010 + sin(x * 0.31) * 0.004
            let wave = cos(x * 0.047) * 0.006
            let shock = (sin(x * 12.9898) * 0.5 + sin(x * 4.1414) * 0.5) * 0.0028
            let drift = i < 34 ? 0.00055 : (i < 66 ? -0.00042 : 0.00048)
            price *= 1 + drift + (cycle - (i > 34 && i < 66 ? 0.004 : 0)) * 0.12 + wave * 0.06 + shock
            closes.append(price)
        }
        func ema(_ values:[Double],_ period:Int)->[Double] {
            let k = 2.0 / (Double(period) + 1)
            var result = [values[0]]
            for value in values.dropFirst() { result.append(value * k + result[result.count - 1] * (1 - k)) }
            return result
        }
        let e12 = ema(closes,12), e26 = ema(closes,26)
        let difValues = zip(e12,e26).map { $0 - $1 }
        let deaValues = ema(difValues,9), e20 = ema(closes,20), e50 = ema(closes,50)
        return (0..<count).map { i in
            let previous = i == 0 ? closes[i] * 0.998 : closes[i-1]
            let open = previous + sin(Double(i) * 5.31) * base * 0.0018
            let close = closes[i]
            let wick = base * (0.0018 + abs(sin(Double(i) * 2.17)) * 0.0022)
            return DemoCandle(open:open,high:max(open,close) + wick,low:min(open,close) - wick,close:close,ema20:e20[i],ema50:e50[i],dif:difValues[i],dea:deaValues[i],hist:2 * (difValues[i] - deaValues[i]))
        }
    }
}
