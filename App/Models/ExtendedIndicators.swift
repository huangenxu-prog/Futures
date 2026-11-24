import Foundation
import TradingChart

private func indicatorBars(_ input: IndicatorInput) -> [FuturesIndicatorMath.OHLC] {
    input.candles.map { .init(high: $0.high, low: $0.low, close: $0.close) }
}
private func plotted(_ values: [Double?], _ input: IndicatorInput) -> [IndicatorValue] {
    zip(input.candles, values).compactMap { bar, value in
        guard let value, value.isFinite else { return nil }
        return IndicatorValue(time: bar.time, value: value)
    }
}

struct QihuiKDJ: ChartIndicator {
    let period: Int
    let kPeriod: Int
    let dPeriod: Int
    var id: String { "qihui.kdj(\(period),\(kPeriod),\(dPeriod))" }
    var displayName: String { "KDJ(\(period),\(kPeriod),\(dPeriod))" }
    var shortName: String { "KDJ" }
    var placement: IndicatorPlacement { .pane }
    func calculate(_ input: IndicatorInput) -> IndicatorOutput {
        let result = FuturesIndicatorMath.kdj(indicatorBars(input), period: period, kPeriod: kPeriod, dPeriod: dPeriod)
        let lines = [("K",result.k,"F18B31"),("D",result.d,"4C8DFF"),("J",result.j,"B57CFF")].map { name, values, color in
            IndicatorLine(id: id+"."+name, name: name, values: plotted(values,input),
                          style: IndicatorLineStyle(color: ChartColor(hex: color)))
        }
        return IndicatorOutput(lines: lines, levels: [
            IndicatorLevel(id: id+".20", value: 20), IndicatorLevel(id: id+".80", value: 80)])
    }
}

struct QihuiATR: ChartIndicator {
    let period: Int
    var id: String { "qihui.atr(\(period))" }
    var displayName: String { "ATR(\(period))" }
    var shortName: String { "ATR" }
    var placement: IndicatorPlacement { .pane }
    func calculate(_ input: IndicatorInput) -> IndicatorOutput {
        IndicatorOutput(lines: [IndicatorLine(id: id+".line", name: "ATR",
            values: plotted(FuturesIndicatorMath.atr(indicatorBars(input), period: period),input),
            style: IndicatorLineStyle(color: ChartColor(hex: "F18B31")))])
    }
}

struct QihuiSAR: ChartIndicator {
    let step: Double
    let maximum: Double
    var id: String { "qihui.sar(\(step),\(maximum))" }
    var displayName: String { "SAR" }
    var placement: IndicatorPlacement { .overlay }
    func calculate(_ input: IndicatorInput) -> IndicatorOutput {
        IndicatorOutput(lines: [IndicatorLine(id: id+".line", name: "SAR",
            values: plotted(FuturesIndicatorMath.sar(indicatorBars(input), step: step, maximum: maximum),input),
            style: IndicatorLineStyle(color: ChartColor(hex: "B57CFF"), width: 1.2, dash: [2,2]))])
    }
}


/// Actual closing open interest, never derived from price or volume.
struct QihuiOpenInterest: ChartIndicator {
    var id: String { "qihui.opi" }
    var displayName: String { "OPI" }
    var placement: IndicatorPlacement { .pane }
    func calculate(_ input: IndicatorInput) -> IndicatorOutput {
        let values = input.candles.compactMap { candle -> IndicatorValue? in
            guard let value = candle.closeInterest, value.isFinite, value >= 0 else { return nil }
            return IndicatorValue(time:candle.time,value:value)
        }
        return IndicatorOutput(lines:[IndicatorLine(id:id+".line",name:"OPI",values:values,
            style:IndicatorLineStyle(color:ChartColor(hex:"F18B31")))])
    }
}
