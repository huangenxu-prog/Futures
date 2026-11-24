import TradingChart

private func structureBars(_ input: IndicatorInput) -> [FormulaBar] {
    Array(input.candles.dropLast()).map {
        FormulaBar(open:$0.open,high:$0.high,low:$0.low,close:$0.close,volume:$0.volume,
                   openInterest:$0.openInterest,closeInterest:$0.closeInterest)
    }
}

struct QihuiChanStructure: ChartIndicator {
    var id: String { "qihui.chan.experimental.v1" }
    var displayName: String { "缠论结构（试验）" }
    var placement: IndicatorPlacement { .overlay }
    func calculate(_ input: IndicatorInput) -> IndicatorOutput {
        let result = ChanStructure.analyze(structureBars(input))
        func value(_ i:Int,_ p:Double) -> IndicatorValue {
            IndicatorValue(time:input.candles[i].time,value:p)
        }
        let segments = zip(result.pivots,result.pivots.dropFirst()).map { a,b in
            IndicatorSegment(start:value(a.index,a.price),end:value(b.index,b.price))
        }
        var series = [IndicatorSegmentSeries(segments:segments,style:IndicatorLineStyle(color:ChartColor(hex:"F5A623"),width:1.6))]
        for zone in result.zones {
            for p in [zone.low,zone.high] {
                let segment = IndicatorSegment(start:value(zone.startIndex,p),end:value(zone.endIndex,p))
                series.append(IndicatorSegmentSeries(segments:[segment],style:IndicatorLineStyle(color:ChartColor(hex:"4C8DFF"),width:1.2)))
            }
        }
        let marks = result.fractals.map { pivot in
            IndicatorSignal(time:input.candles[pivot.index].time,value:pivot.price,
                text:pivot.kind == .top ? "顶" : "底",color:ChartColor(hex:"B57CFF"))
        }
        return IndicatorOutput(signals:marks.sorted{$0.time < $1.time},segmentSeries:series)
    }
}

struct QihuiHuntPreview: ChartIndicator {
    var id: String { "qihui.hunt.single-period.v1" }
    var displayName: String { "猎杀·扫回候选" }
    var placement: IndicatorPlacement { .overlay }
    func calculate(_ input: IndicatorInput) -> IndicatorOutput {
        let marks = HuntSignals.calculate(structureBars(input)).enumerated().compactMap { i,s -> IndicatorSignal? in
            guard let s else { return nil }
            return IndicatorSignal(time:input.candles[i].time,value:s.extreme,
                text:s.side > 0 ? "扫低↑" : "扫高↓",color:ChartColor(hex:s.side > 0 ? "FF5B5B" : "23C6C8"))
        }
        return IndicatorOutput(signals:marks)
    }
}
