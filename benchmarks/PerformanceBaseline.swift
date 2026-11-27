import Foundation

@main
struct PerformanceBaseline {
    @MainActor static func measure(_ name: String, bars: Int, iterations: Int, _ work: () throws -> Double) rethrows {
        var checksum = 0.0
        for _ in 0..<3 { checksum += try work() }
        var samples: [Double] = []
        samples.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            checksum += try work()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        precondition(checksum.isFinite)
        samples.sort()
        let p95 = samples[min(samples.count - 1, Int(ceil(Double(samples.count) * 0.95)) - 1)]
        let mean = samples.reduce(0,+) / Double(samples.count)
        print(String(format: "BASELINE %@ bars=%d n=%d mean_ms=%.5f p95_ms=%.5f max_ms=%.5f checksum=%.4f",
                     name, bars, iterations, mean, p95, samples.last!, checksum))
    }

    @MainActor static func main() throws {
        let dual = try FormulaProgram("LINE1:EMA(EMA(C,20),50);LINE2:EMA(C,50);")
        let macd = try FormulaProgram("DIF:EMA(C,12)-EMA(C,26);DEA:EMA(DIF,9);HIST:2*(DIF-DEA),COLORSTICK;")
        let custom = try FormulaProgram("A:WMA(C,120);B:HHV(H,120)-LLV(L,120);D:COUNT(C>MA(C,20),50);")
        for n in [200,500,1200,8964] {
            let bars = (0..<n).map { i -> MarketBar in
                let c = 3000 + sin(Double(i)/17)*50 + Double(i%13)
                return MarketBar(time: 1700000000+Int64(i)*300, open:c-1,high:c+3,low:c-3,close:c,preSettlement:nil,volume:Int64(100+i))
            }
            let formula = bars.map { FormulaBar(open:$0.open,high:$0.high,low:$0.low,close:$0.close,volume:Double($0.volume)) }
            let ohlc = bars.map { FuturesIndicatorMath.OHLC(high:$0.high,low:$0.low,close:$0.close) }
            for (name,program) in [("dual_ema",dual),("macd_formula",macd),("custom",custom)] {
                try measure(name,bars:n,iterations:100) {
                    let result = try program.evaluate(formula)
                    precondition(result.allSatisfy { $0.values.count == n })
                    return result.reduce(0) { $0 + ($1.values.last! ?? 0) }
                }
            }
            measure("kdj",bars:n,iterations:100) { FuturesIndicatorMath.kdj(ohlc,period:9,kPeriod:3,dPeriod:3).j.last! ?? 0 }
            measure("atr",bars:n,iterations:100) { FuturesIndicatorMath.atr(ohlc,period:14).last! ?? 0 }
            measure("sar",bars:n,iterations:100) { FuturesIndicatorMath.sar(ohlc,step:0.02,maximum:0.2).last! ?? 0 }
            let encoded = try JSONEncoder().encode(bars)
            try measure("json_encode",bars:n,iterations:30) { Double(try JSONEncoder().encode(bars).count) }
            try measure("json_decode",bars:n,iterations:30) { Double(try JSONDecoder().decode([MarketBar].self,from:encoded).count) }
            measure("history_merge",bars:n,iterations:100) {
                let result = KlineStartupMerge.combine(server:Array(bars.suffix(200)),existing:bars,live:bars.last,limit:n,timestamp:{$0.time})
                precondition(result == bars)
                return Double(result.count)
            }
            var altered = bars
            let b = bars.last!
            altered[n-1] = MarketBar(time:b.time,open:b.open,high:b.high+1,low:b.low,close:b.close+1,preSettlement:nil,volume:b.volume+1)
            let feed = DirectChartFeed<[MarketBar]>()
            let owner = UUID()
            var received = 0
            feed.attach(key:"test",owner:owner,fallback:bars,receiveTail:{ _ in received += 1 },receive:{ _,_ in received += 1 })
            var flip = false
            measure("feed_tail_delivery",bars:n,iterations:10000) {
                flip.toggle()
                feed.publish(key:"test",snapshot:flip ? altered : bars,tailOnly:true)
                return Double(received)
            }
            precondition(received == 10004)
            feed.detach(owner:owner)
            var updatedFormula = formula
            let f = formula.last!
            updatedFormula[n-1] = FormulaBar(open:f.open,high:f.high+1,low:f.low,close:f.close+1,volume:f.volume)
            let before = try dual.evaluate(formula)
            let after = try dual.evaluate(updatedFormula)
            precondition(zip(before,after).allSatisfy { pair in pair.0.values.dropLast().elementsEqual(pair.1.values.dropLast()) })
        }
        let bar = MarketBar(time:1700000000,open:3000,high:3003,low:2999,close:3001,preSettlement:nil,volume:100)
        var frame = Data("data: ".utf8)
        frame.append(try JSONEncoder().encode(bar))
        frame.append(Data("\n\n".utf8))
        var decoder = SSEFrameDecoder<MarketBar>()
        var count = 0
        try measure("sse_decode",bars:1,iterations:10000) {
            try decoder.append(frame,epoch:0,uptime:0) { event in
                precondition(event.value == bar)
                count += 1
            }
            return Double(count)
        }
        precondition(count == 10003)
        print("PASS: numerical tail consistency, history merge, feed and SSE delivery")
    }
}
