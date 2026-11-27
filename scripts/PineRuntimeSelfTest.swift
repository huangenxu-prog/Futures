import Foundation

@main struct PineRuntimeSelfTest {
    static func main() async throws {
        let bundle = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        let bars = (0..<200).map { i -> PineRuntimeBar in
            let price = Double(100+i)
            let time = Int64(1704067200000) + Int64(i)*60000
            return PineRuntimeBar(open: price, high: price+1, low: price-1, close: price, volume: 1000, openTime: time, closeTime: time+59999)
        }
        let source = """
        //@version=6
        indicator("EMA", overlay=true)
        plot(ta.ema(close,20),"EMA")
        """
        let plots = try await PineRuntime.evaluate(source: source, bars: bars, bundleSource: bundle)
        guard let ema = plots.first(where: { $0.name == "EMA" }), ema.points.count == 200,
              let last = ema.points.last?.value, abs(last-289.5)<0.01 else {
            fatalError("Unexpected EMA output")
        }
        print("Swift runtime EMA: \(last), points: \(ema.points.count), first time: \(String(describing: ema.points.first?.time))")
        let invalid = try? await PineRuntime.evaluate(source: source, bars: [], bundleSource: bundle)
        precondition(invalid == nil, "Empty input must fail")
        print("PASS: Swift PineRuntime integration")
    }
}
