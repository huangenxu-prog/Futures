import TradingChart

struct QihuiExtendedMovingAverage: ChartIndicator {
    let average: AdditionalMovingAverage
    let program: FormulaProgram
    let style: IndicatorLineStyle
    var id: String { "qihui.extended-average:\(average.id):\(average.key):\(average.type.rawValue)" }
    var displayName: String { average.label }
    var placement: IndicatorPlacement { .overlay }

    func calculate(_ input: IndicatorInput) -> IndicatorOutput {
        let bars = input.candles.map {
            FormulaBar(open:$0.open,high:$0.high,low:$0.low,close:$0.close,volume:$0.volume,
                       openInterest:$0.openInterest,closeInterest:$0.closeInterest)
        }
        guard let output = try? program.evaluate(bars).first else { return .empty }
        let values = zip(input.candles,output.values).compactMap { candle,value -> IndicatorValue? in
            guard let value,value.isFinite else { return nil }
            return IndicatorValue(time:candle.time,value:value)
        }
        return IndicatorOutput(lines:[IndicatorLine(id:id+".line",name:displayName,values:values,style:style)])
    }
}
