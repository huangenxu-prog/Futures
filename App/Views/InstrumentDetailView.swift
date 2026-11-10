import SwiftUI
import Charts

struct InstrumentDetailView: View {
    let instrument: FuturesInstrument
    @State private var period = "15分"
    @State private var showIndicators = true
    private let periods = ["1分","5分","15分","30分","60分","日线"]
    private var candles: [DemoCandle] { DemoCandle.make(base:instrument.lastPrice,count:100) }
    var body: some View {
        ScrollView {
            VStack(spacing:10) {
                topBar
                candleChart
                macdPanel
                quotePanel
                Text("本地生成的演示行情，不代表真实市场行情").font(.caption2).foregroundStyle(.gray).padding(.bottom,8)
            }.padding(.horizontal,10).padding(.top,8)
        }
        .background(Color.black)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark,for:.navigationBar)
        .preferredColorScheme(.dark)
    }
    private var topBar: some View {
        HStack(spacing:8) {
            Text(instrument.name).font(.system(size:15,weight:.semibold))
            Text(instrument.id).font(.caption).foregroundStyle(.gray)
            Rectangle().fill(.white.opacity(0.3)).frame(width:1,height:20)
            Text(Date.now.formatted(date:.numeric,time:.shortened)).font(.caption).foregroundStyle(.white.opacity(0.8))
            Spacer()
            Menu { ForEach(periods,id:\.self){ p in Button(p){period=p} } } label: {
                Text(period+"⌄").font(.caption.weight(.semibold)).padding(.horizontal,12).padding(.vertical,8).background(.white.opacity(0.12),in:Capsule())
            }
            Button { showIndicators.toggle() } label: { Image(systemName:"eye").padding(8).background(.white.opacity(0.12),in:Circle()) }
        }.padding(9).background(.ultraThinMaterial,in:Capsule()).overlay(Capsule().stroke(.white.opacity(0.35),lineWidth:1))
    }
    private var candleChart: some View {
        VStack(alignment:.leading,spacing:6) {
            HStack { Text("K线").font(.caption).foregroundStyle(.gray); Spacer(); if showIndicators { Text("EMA20").foregroundStyle(.orange); Text("EMA50").foregroundStyle(.cyan) } }.font(.caption2)
            Chart {
                ForEach(Array(candles.enumerated()),id:\.offset) { i,c in
                    RuleMark(x:.value("序号",i),yStart:.value("低",c.low),yEnd:.value("高",c.high)).foregroundStyle(c.close >= c.open ? .red : .green).lineStyle(StrokeStyle(lineWidth:1))
                    RectangleMark(x:.value("序号",i),yStart:.value("开",min(c.open,c.close)),yEnd:.value("收",max(c.open,c.close)),width:4).foregroundStyle(c.close >= c.open ? .red : .green)
                    if showIndicators {
                        LineMark(x:.value("序号",i),y:.value("EMA20",c.ema20)).foregroundStyle(.orange).lineStyle(StrokeStyle(lineWidth:1.4))
                        LineMark(x:.value("序号",i),y:.value("EMA50",c.ema50)).foregroundStyle(.cyan).lineStyle(StrokeStyle(lineWidth:1.4))
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisValueLabel().foregroundStyle(.white.opacity(0.65))
                    AxisGridLine().foregroundStyle(.white.opacity(0.12))
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing) { _ in
                    AxisValueLabel().foregroundStyle(.white.opacity(0.7))
                    AxisGridLine().foregroundStyle(.white.opacity(0.12))
                }
            }
            .frame(height:300)
        }.padding(10).background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:16)).overlay(RoundedRectangle(cornerRadius:16).stroke(.white.opacity(0.22),lineWidth:1))
    }
    private var macdPanel: some View {
        VStack(alignment:.leading,spacing:5) {
            HStack { Text("MACD(12, 26, 9)").font(.caption.weight(.semibold)); Spacer(); Text("DIF"); Text("DEA") }.foregroundStyle(.white.opacity(0.75)).font(.caption2)
            Chart {
                ForEach(Array(candles.enumerated()),id:\.offset) { i,c in
                    BarMark(x:.value("序号",i),y:.value("MACD",c.hist),width:.fixed(4)).foregroundStyle(c.hist >= 0 ? .red : .green)
                    LineMark(x:.value("序号",i),y:.value("DIF",c.dif)).foregroundStyle(.orange).lineStyle(StrokeStyle(lineWidth:1.2))
                    LineMark(x:.value("序号",i),y:.value("DEA",c.dea)).foregroundStyle(.cyan).lineStyle(StrokeStyle(lineWidth:1.2))
                }
                RuleMark(y:.value("零轴",0)).foregroundStyle(.white.opacity(0.3))
            }.chartXAxis(.hidden).chartYAxis(.hidden).frame(height:112)
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
        var closes:[Double]=[]
        for i in 0..<count { closes.append(base + sin(Double(i)*0.31)*base*0.006 + cos(Double(i)*0.12)*base*0.003 + Double(i-count/2)*base*0.00004) }
        func ema(_ values:[Double],_ period:Int)->[Double] { let k=2.0/(Double(period)+1); var out=[values[0]]; for v in values.dropFirst(){out.append(v*k+out.last!*(1-k))}; return out }
        let e12=ema(closes,12), e26=ema(closes,26), dif=zip(e12,e26).map { $0 - $1 }, dea=ema(dif,9)
        return (0..<count).map { i in
            let o=i == 0 ? closes[i] : closes[i-1], c=closes[i], spread=base*0.001*(1+Double(i%4)*0.15)
            return DemoCandle(open:o,high:max(o,c)+spread,low:min(o,c)-spread,close:c,ema20:ema(closes,20)[i],ema50:ema(closes,50)[i],dif:dif[i],dea:dea[i],hist:2*(dif[i]-dea[i]))
        }
    }
}
