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
        precondition(result.final == 50_046 && result.winRate == 1)
        let both = [bars[0],bar(101,110,90,101),bars[2],bars[3]]
        let adverse = try FuturesBacktest.run(bars:both,signals:[.init(long:true),.init(),.init(),.init()],p:p)
        precondition(adverse.ambiguous == 1 && adverse.final == 49_946)
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
        print("Backtest next-open, fees, stop-first, Chan confirmation and causal hunt prefix checks passed")
    }
}
