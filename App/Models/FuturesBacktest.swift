import Foundation

struct BacktestParameters: Sendable {
    var initial = 50_000.0
    var multiplier: Double
    var tick: Double
    var marginRate: Double
    var feePerSide: Double
    var slippageTicks: Int
    var lots: Int
    var stopRisk: Double
    var targetR: Double
    var valid: Bool {
        [initial,multiplier,tick,marginRate,feePerSide,stopRisk,targetR].allSatisfy(\.isFinite)
        && initial > 0 && multiplier > 0 && tick > 0 && marginRate > 0 && marginRate <= 1
        && feePerSide >= 0 && (0...100).contains(slippageTicks) && (1...1000).contains(lots)
        && stopRisk > 0 && targetR >= 0 && targetR <= 100
    }
}
struct BacktestSignal: Sendable {
    var long = false
    var short = false
    var exit = false
    var stopPrice: Double? = nil
}
struct BacktestTrade: Sendable, Identifiable {
    let id: Int
    let side: Int
    let entryIndex: Int
    let exitIndex: Int
    let entry: Double
    let exit: Double
    let net: Double
    let reason: String
}
struct BacktestResult: Sendable {
    let initial: Double
    let final: Double
    let trades: [BacktestTrade]
    let equity: [Double]
    let maxDrawdown: Double
    let rejected: Int
    let ambiguous: Int
    let marginCalls: Int
    var wins: Int { trades.filter { $0.net > 0 }.count }
    var losses: Int { trades.filter { $0.net < 0 }.count }
    var winRate: Double? { trades.isEmpty ? nil : Double(wins)/Double(trades.count) }
}

enum FuturesBacktest {
    private struct Position {
        let side, index: Int
        let entry, stop, target: Double
    }

    static func formulaSignals(_ source: String, bars: [FormulaBar]) throws -> [BacktestSignal] {
        let outputs = try FormulaProgram(source).evaluate(bars)
        let named = Dictionary(uniqueKeysWithValues:outputs.filter { $0.drawing == nil }.map { ($0.name,$0.values) })
        guard named["LONG"] != nil || named["SHORT"] != nil else {
            throw FormulaFailure("回测公式须输出 LONG 或 SHORT；可选 EXIT 与 STOP。均线本身不是交易规则。")
        }
        func yes(_ name:String,_ i:Int) -> Bool { (named[name]?[i] ?? 0) > 0 }
        return bars.indices.map { i in
            BacktestSignal(long:yes("LONG",i),short:yes("SHORT",i),exit:yes("EXIT",i),
                           stopPrice:named["STOP"]?[i])
        }
    }

    static func run(bars: [FormulaBar], signals: [BacktestSignal], p: BacktestParameters) throws -> BacktestResult {
        guard p.valid, bars.count == signals.count, bars.count >= 2 else {
            throw FormulaFailure("回测参数或历史K线不足")
        }
        let unit = p.multiplier * Double(p.lots)
        let cost = p.feePerSide * Double(p.lots)
        let slip = Double(p.slippageTicks)*p.tick
        let riskDistance = p.stopRisk/unit
        guard unit.isFinite,cost.isFinite,slip.isFinite,riskDistance.isFinite,riskDistance > 0 else {
            throw FormulaFailure("回测参数超出计算范围")
        }
        var cash = p.initial, peak = p.initial, drawdown = 0.0
        var equity = [Double](), trades = [BacktestTrade]()
        var position: Position?
        var rejected = 0, ambiguous = 0, marginCalls = 0

        func close(_ pos:Position,_ price:Double,_ i:Int,_ reason:String) {
            let fill = price-Double(pos.side)*slip
            let net = (fill-pos.entry)*Double(pos.side)*unit-2*cost
            cash += net
            trades.append(BacktestTrade(id:trades.count,side:pos.side,entryIndex:pos.index,
                exitIndex:i,entry:pos.entry,exit:fill,net:net,reason:reason))
            position = nil
        }

        for i in bars.indices {
            let bar = bars[i]
            guard [bar.open,bar.high,bar.low,bar.close].allSatisfy(\.isFinite),
                  bar.high >= bar.low else { throw FormulaFailure("历史K线含无效价格") }
            if i > 0 {
                let signal = signals[i-1] // observed only at previous close
                var exitedAtOpen = false
                if let pos = position {
                    let gapStop = pos.side > 0 ? bar.open <= pos.stop : bar.open >= pos.stop
                    if gapStop { close(pos,bar.open,i,"跳空止损"); exitedAtOpen = true }
                    else if signal.exit || (pos.side > 0 ? signal.short : signal.long) {
                        close(pos,bar.open,i,"信号平仓"); exitedAtOpen = true
                    }
                }
                if position == nil && !exitedAtOpen && i < bars.count-1 && !signal.exit {
                    if signal.long && signal.short { rejected += 1 }
                    else if signal.long || signal.short {
                        let side = signal.long ? 1 : -1
                        let entry = bar.open + Double(side)*slip
                        let stop = signal.stopPrice ?? (entry-Double(side)*riskDistance)
                        let risk = (entry-stop)*Double(side)
                        let margin = abs(entry)*unit*p.marginRate
                        // No adding, no partial margin financing, no entry
                        // with a structural stop farther than the risk cap.
                        if risk > 0 && risk*unit <= p.stopRisk+1e-8 && cash >= margin+2*cost && cash > 0 {
                            position = Position(side:side,index:i,entry:entry,stop:stop,
                                target:entry+Double(side)*risk*p.targetR)
                        } else { rejected += 1 }
                    }
                }
            }
            if let pos = position {
                let hitStop = pos.side > 0 ? bar.low <= pos.stop : bar.high >= pos.stop
                let hitTarget = p.targetR > 0 && (pos.side > 0 ? bar.high >= pos.target : bar.low <= pos.target)
                if hitStop && hitTarget { ambiguous += 1 }
                // OHLC does not reveal intrabar order; assume stop first.
                if hitStop {
                    let price = pos.side > 0 ? min(bar.open,pos.stop) : max(bar.open,pos.stop)
                    close(pos,price,i,"止损")
                } else if hitTarget {
                    // No favorable gap fill beyond the specified target.
                    close(pos,pos.target,i,"止盈")
                } else {
                    let marked = cash+(bar.close-pos.entry)*Double(pos.side)*unit-2*cost
                    if marked < abs(bar.close)*unit*p.marginRate {
                        marginCalls += 1
                        close(pos,bar.close,i,"模拟保证金不足")
                    } else if i == bars.count-1 {
                        close(pos,bar.close,i,"样本结束平仓")
                    }
                }
            }
            let value = position.map { cash+(bar.close-$0.entry)*Double($0.side)*unit-2*cost } ?? cash
            guard value.isFinite else { throw FormulaFailure("回测权益计算溢出") }
            equity.append(value)
            peak = max(peak,value)
            drawdown = max(drawdown,peak > 0 ? (peak-value)/peak : 0)
        }
        return BacktestResult(initial:p.initial,final:cash,trades:trades,equity:equity,
                              maxDrawdown:drawdown,rejected:rejected,ambiguous:ambiguous,marginCalls:marginCalls)
    }
}
