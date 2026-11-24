import TradingChart

private func structureBars(_ input: IndicatorInput) -> [FormulaBar] {
    Array(input.candles.dropLast()).map {
        FormulaBar(open:$0.open,high:$0.high,low:$0.low,close:$0.close,volume:$0.volume,
                   openInterest:$0.openInterest,closeInterest:$0.closeInterest)
    }
}

private func structureSeries(_ result: ChanStructure.Result, input: IndicatorInput,
                             strokeColor: String, showZones: Bool) -> [IndicatorSegmentSeries] {
    func value(_ i:Int,_ p:Double) -> IndicatorValue {
        IndicatorValue(time:input.candles[i].time,value:p)
    }
    let segments = zip(result.pivots,result.pivots.dropFirst()).map { a,b in
        IndicatorSegment(start:value(a.index,a.price),end:value(b.index,b.price))
    }
    var series = [IndicatorSegmentSeries(segments:segments,
        style:IndicatorLineStyle(color:ChartColor(hex:strokeColor),width:1.6))]
    if showZones {
        for zone in result.zones {
            for p in [zone.low,zone.high] {
                let segment = IndicatorSegment(start:value(zone.startIndex,p),end:value(zone.endIndex,p))
                series.append(IndicatorSegmentSeries(segments:[segment],
                    style:IndicatorLineStyle(color:ChartColor(hex:"4C8DFF"),width:1.2)))
            }
        }
    }
    return series
}

struct QihuiChanStructure: ChartIndicator {
    var id: String { "qihui.chan.experimental.v2" }
    var displayName: String { "缠论结构（试验）" }
    var placement: IndicatorPlacement { .overlay }
    func calculate(_ input: IndicatorInput) -> IndicatorOutput {
        let result = ChanStructure.analyze(structureBars(input))
        // Fractals remain in the algorithm, not on the chart as text.
        return IndicatorOutput(segmentSeries:structureSeries(result,input:input,strokeColor:"F5A623",showZones:true))
    }
}

struct QihuiHuntPreview: ChartIndicator {
    var showStructure = true
    var id: String { "qihui.hunt.single-period.v2:\(showStructure)" }
    var displayName: String { "猎杀（本周期研究）" }
    var placement: IndicatorPlacement { .overlay }
    func calculate(_ input: IndicatorInput) -> IndicatorOutput {
        let bars = structureBars(input)
        let analysis = HuntSignals.analyze(bars)
        let candidates = analysis.signals
        let confirmation = HuntConfirmation.calculate(bars,candidates:candidates)
        let rawMarks = candidates.enumerated().compactMap { i,s -> IndicatorSignal? in
            guard let s else { return nil }
            return IndicatorSignal(time:input.candles[i].time,value:s.extreme,
                text:s.side > 0 ? "猎杀多" : "猎杀空",color:ChartColor(hex:"F5A623"))
        }
        let confirmedMarks = confirmation.signals.enumerated().compactMap { i,s -> IndicatorSignal? in
            guard let s else { return nil }
            return IndicatorSignal(time:input.candles[i].time,
                value:s.side > 0 ? bars[i].low : bars[i].high,
                text:s.side > 0 ? "确认多" : "确认空",
                color:ChartColor(hex:s.side > 0 ? "FF5B5B" : "23C6C8"))
        }
        let series = showStructure
            ? structureSeries(ChanStructure.analyze(bars),input:input,strokeColor:"F5A623",showZones:true)
            : []
        let trend: String
        switch analysis.trend.last ?? 0 {
        case 1: trend = "多头"
        case -1: trend = "空头"
        default: trend = analysis.hasDirectionData ? "不明确" : "数据不足"
        }
        let status = "本周期 · 趋势：\(trend) · \(confirmation.latestStatus)"
        return IndicatorOutput(signals:(rawMarks+confirmedMarks).sorted{$0.time < $1.time},
                               segmentSeries:series,statusText:status)
    }
}
