import SwiftUI
import Foundation

struct IntradayPane: View {
    let symbol: String
    let previousSettlement: Double?
    @Environment(\.scenePhase) private var scenePhase
    @State private var bars: [MarketBar] = []
    @State private var status = "加载中"
    @State private var selected: Int?
    @State private var streamTimes: Set<Int64> = []
    @State private var historyReady = false
    private var session: [MarketBar] { IntradaySession.latest(bars) }

    var body: some View {
        let data = session
        let averages = IntradaySession.averages(data)
        let reference = previousSettlement.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        VStack(alignment:.leading,spacing:3) {
            Divider()
            HStack(spacing:6) {
                Text("分时").fontWeight(.semibold)
                if let last = data.last {
                    Text(IntradaySession.label(last.time,format:"MM/dd HH:mm"))
                    Text(last.close.formatted()).foregroundStyle(MarketPalette.accent)
                }
                Spacer(minLength:0)
                Text(status).lineLimit(1)
            }.font(.system(size:10)).foregroundStyle(MarketPalette.muted)
            if data.isEmpty {
                Spacer()
                Text("暂无分钟行情").font(.caption).foregroundStyle(.secondary).frame(maxWidth:.infinity)
                Spacer()
            } else {
                IntradayCanvas(bars:data,averages:averages,reference:reference,selected:$selected)
                HStack(spacing:6) {
                    Text("分钟价").foregroundStyle(MarketPalette.accent)
                    Text(historyReady ? "估算均价" : "样本均价").foregroundStyle(.orange)
                    if let reference { Text("昨结 \(reference.formatted())") }
                    Spacer(minLength:0)
                    if let selected, data.indices.contains(selected) {
                        Text(IntradaySession.label(data[selected].time,format:"HH:mm")+" "+data[selected].close.formatted())
                    } else { Text("最新交易时段") }
                }.font(.system(size:9)).foregroundStyle(MarketPalette.muted)
            }
        }
        .padding(.horizontal,5)
        .background(MarketPalette.surface)
        .task(id:symbol+(scenePhase == .active ? "/active" : "/paused")) {
            guard scenePhase == .active else { return }
            await load()
        }
    }

    @MainActor private func merge(_ incoming:[MarketBar], live:Bool = false) {
        let oldDay = bars.last.map { IntradaySession.day($0.time) }
        bars = IntradaySession.merge(existing:bars,incoming:incoming,preserve:live ? [] : streamTimes)
        if live {
            streamTimes.formUnion(incoming.map(\.time))
            streamTimes.formIntersection(Set(bars.map(\.time)))
        }
        if oldDay != bars.last.map({IntradaySession.day($0.time)}) {
            selected = nil
            historyReady = false
        }
        if let selected, !session.indices.contains(selected) { self.selected = nil }
    }

    @MainActor private func load() async {
        merge(MarketDataService.cached(symbol:symbol,period:60) ?? [])
        // The gateway may send a two-bar handshake. Fetch historical minutes
        // separately; then merge SSE updates by timestamp, never replace a day.
        streamTimes.removeAll()
        historyReady = false
        let history = Task { @MainActor in
            do {
                let recent = try await MarketDataService.fetch(symbol:symbol,period:60,count:500,mergeCached:false)
                try Task.checkCancellation()
                merge(recent)
                if let first = recent.first, let last = recent.last {
                    if IntradaySession.day(first.time) != IntradaySession.day(last.time) {
                        historyReady = true
                    } else {
                        let older = try await MarketDataService.fetchOlder(symbol:symbol,period:60,before:first.time,count:300,depth:1200)
                        try Task.checkCancellation()
                        merge(older)
                        if let oldest = older.first {
                            historyReady = IntradaySession.day(oldest.time) != IntradaySession.day(last.time)
                        }
                    }
                }
            } catch {}
        }
        defer { history.cancel() }
        while !Task.isCancelled {
            do {
                try await MarketDataService.streamCandles(symbol:symbol,period:60,count:500) { event in
                    guard !Task.isCancelled,event.symbol == symbol else { return }
                    if let full = event.bars { merge(full,live:true) }
                    if let bar = event.bar { merge([bar],live:true) }
                    if let first = bars.first,let last = bars.last,IntradaySession.day(first.time) != IntradaySession.day(last.time) { historyReady = true }
                    status = "已连接"
                }
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled else { return }
                status = "重连中"
                do { try await Task.sleep(for:.seconds(3)) } catch { return }
            }
        }
    }
}

private struct IntradayCanvas: View {
    let bars:[MarketBar]
    let averages:[Double?]
    let reference:Double?
    @Binding var selected:Int?
    var body: some View {
        GeometryReader { geometry in
            let w = max(1,geometry.size.width-43)
            Canvas { context,size in
                let height = max(1,size.height-12)
                var values = bars.map(\.close) + averages.compactMap{$0}
                if let reference { values.append(reference) }
                guard let minValue = values.min(),let maxValue = values.max() else { return }
                let padding = max((maxValue-minValue)*0.08,max(abs(maxValue),1)*0.0001)
                let low = minValue-padding,high = maxValue+padding
                func y(_ p:Double)->CGFloat { height*CGFloat((high-p)/(high-low)) }
                func x(_ i:Int)->CGFloat { w*CGFloat(i)/CGFloat(max(1,bars.count-1)) }
                for k in 0...2 {
                    let v = high-(high-low)*Double(k)/2,py = y(v)
                    var path = Path(); path.move(to:CGPoint(x:0,y:py)); path.addLine(to:CGPoint(x:w,y:py))
                    context.stroke(path,with:.color(MarketPalette.divider),lineWidth:0.5)
                    context.draw(Text(v.formatted(.number.precision(.fractionLength(0...2)))).font(.system(size:8)).foregroundColor(MarketPalette.muted),at:CGPoint(x:w+3,y:max(5,min(height-5,py))),anchor:.leading)
                }
                if let reference {
                    var p = Path(); p.move(to:CGPoint(x:0,y:y(reference))); p.addLine(to:CGPoint(x:w,y:y(reference)))
                    context.stroke(p,with:.color(MarketPalette.muted),style:StrokeStyle(lineWidth:0.7,dash:[3,3]))
                }
                var price = Path(), average = Path(), active = false
                for (i,bar) in bars.enumerated() {
                    let p = CGPoint(x:x(i),y:y(bar.close))
                    if i == 0 { price.move(to:p) } else { price.addLine(to:p) }
                    if let a = averages[i] {
                        let pt = CGPoint(x:x(i),y:y(a))
                        if active { average.addLine(to:pt) } else { average.move(to:pt) }; active = true
                    } else { active = false }
                }
                context.stroke(price,with:.color(MarketPalette.accent),lineWidth:1.3)
                context.stroke(average,with:.color(.orange),lineWidth:1)
                if bars.count > 1 {
                    for i in Set([0,bars.count/2,bars.count-1]).sorted() {
                        let label = IntradaySession.label(bars[i].time,format:"HH:mm")
                        context.draw(Text(label).font(.system(size:8)).foregroundColor(MarketPalette.muted),
                            at:CGPoint(x:max(15,min(w-15,x(i))),y:height+6))
                    }
                }
                if let selected,bars.indices.contains(selected) {
                    var p = Path(); p.move(to:CGPoint(x:x(selected),y:0)); p.addLine(to:CGPoint(x:x(selected),y:height))
                    context.stroke(p,with:.color(MarketPalette.ink.opacity(0.7)),lineWidth:0.6)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance:0).onChanged { value in
                let fraction = min(1,max(0,value.location.x/w))
                selected = Int((fraction*CGFloat(max(0,bars.count-1))).rounded())
            }.onEnded { _ in selected = nil })
        }
    }
}
