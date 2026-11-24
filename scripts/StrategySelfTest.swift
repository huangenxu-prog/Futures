import Foundation
@main
struct StrategySelfTest {
    static func bar(_ o:Double,_ h:Double,_ l:Double,_ c:Double)->FormulaBar {
        FormulaBar(open:o,high:h,low:l,close:c,volume:1)
    }
    static func main() throws {
        let bars = [bar(100,101,99,100),bar(101,104,100,103),bar(103,110,102,109),bar(108,109,107,108)]
        let p = BacktestParameters(multiplier:10,tick:1,marginRate:0.1,feePerSide:2,slippageTicks:0,lots:1,stopRisk:50,targetR:1)
        let result = try FuturesBacktest.run(bars:bars,signals:[BacktestSignal(long:true),.init(),.init(),.init()],p:p)
        precondition(result.trades.count == 1)
        precondition(result.trades[0].entryIndex == 1 && result.trades[0].exitIndex == 2)
        // 50 yuan net budget, 4 yuan fees: four ticks risk, then
        // a five-tick gross target to achieve at least 1R net.
        precondition(result.final == 50_046 && result.winRate == 1)
        let both = [bars[0],bar(101,110,90,101),bars[2],bars[3]]
        let adverse = try FuturesBacktest.run(bars:both,signals:[.init(long:true),.init(),.init(),.init()],p:p)
        precondition(adverse.ambiguous == 1 && adverse.final == 49_956)
        var protect = p
        protect.targetR = 0
        protect.breakEvenAfterProfit = true
        let protectBars = [bars[0],bar(101,105,100,104),bar(104,105,100,101),bars[3]]
        let protected = try FuturesBacktest.run(bars:protectBars,signals:[.init(long:true),.init(),.init(),.init()],p:protect)
        precondition(protected.trades.count == 1)
        precondition(protected.trades[0].reason == "盈利回撤归零")
        precondition(protected.final == 50_006)
        let expensiveStop = try FuturesBacktest.run(bars:bars,signals:[.init(long:true,stopPrice:96),.init(),.init(),.init()],p:p)
        precondition(expensiveStop.rejected == 1 && expensiveStop.trades.isEmpty)
        let signals = try FuturesBacktest.formulaSignals("LONG:C>O; EXIT:C<O;",bars:bars)
        precondition(!signals[0].long && signals[1].long)
        let line = try FormulaProgram("A:EMA(C,2);")
        _ = line
        do { _ = try FuturesBacktest.formulaSignals("A:EMA(C,2);",bars:bars); preconditionFailure("accepted no signals") }
        catch is FormulaFailure {}
        let prices:[Double] = [10,12,15,13,11,9,7,9,11,13,16,14,12,10,8,10,12,14,17,15,13,11,9,11,13,15]
        let fixture = prices.map { bar($0,$0+0.4,$0-0.4,$0) }
        let structure = ChanStructure.analyze(fixture)
        precondition(structure.fractals.count >= 4)
        precondition(structure.fractals.allSatisfy{$0.confirmedAt > $0.index})
        precondition(zip(structure.pivots,structure.pivots.dropFirst()).allSatisfy{$0.kind != $1.kind && $1.mergedIndex-$0.mergedIndex >= 4})
        let full = HuntSignals.calculate(fixture)
        for i in 1...fixture.count {
            let prefix = HuntSignals.calculate(Array(fixture.prefix(i)))
            precondition(prefix == Array(full.prefix(i)))
        }
        let timed = fixture.enumerated().map { i,b in
            MultiPeriodHunt.Timed(time:1_790_000_000 + Int64(i)*300,bar:b)
        }
        // A future-only higher timeframe must never authorize an entry.
        let future = fixture.enumerated().map { i,b in
            MultiPeriodHunt.Timed(time:1_900_000_000 + Int64(i)*1800,bar:b)
        }
        let filtered = MultiPeriodHunt.calculate(five:timed,thirty:future,hour:future)
        precondition(filtered.covered == 0 && filtered.signals.allSatisfy{$0 == nil})
        let retest = [bar(100,102,95,101),bar(101,105,100,104),bar(103,103,97,101),bar(102,106,101,105),bar(105,107,102,106)]
        let seed = HuntSignals.Signal(side:1,level:100,extreme:95)
        let raw: [HuntSignals.Signal?] = [seed,nil,nil,nil,nil]
        let confirmed = HuntConfirmation.calculate(retest,candidates:raw)
        precondition(confirmed.signals[0] == nil && confirmed.signals[2] == nil && confirmed.signals[3] == seed)
        for i in 1...retest.count {
            let prefix = HuntConfirmation.calculate(Array(retest.prefix(i)),candidates:Array(raw.prefix(i)))
            precondition(prefix.signals == Array(confirmed.signals.prefix(i)))
        }
        var broken = retest
        broken[2] = bar(103,104,94,101)
        let invalid = HuntConfirmation.calculate(broken,candidates:raw)
        precondition(invalid.invalidated == 1 && invalid.confirmed == 0)
        let directional = try FuturesBacktest.run(bars:bars,signals:[.init(long:true),.init(exitLong:true),.init(),.init()],p:protect)
        precondition(directional.trades.first?.reason == "结构失效")
        let warmed = try FuturesBacktest.run(bars:bars,signals:[.init(long:true),.init(),.init(),.init()],p:p,startIndex:1)
        precondition(warmed.trades.isEmpty && warmed.final == p.initial && warmed.equity.count == 3)
        precondition(result.trades[0].plannedRisk == 44 && result.trades[0].fees == 4)
        precondition(result.trades[0].initialStop == 97 && result.trades[0].initialTarget == 106)
        precondition(abs(result.trades[0].realizedR-46.0/44.0) < 1e-9)
        print("Backtest warmup exclusion, trade audit, net risk, causal retest and timeframe alignment checks passed")
    }
}
