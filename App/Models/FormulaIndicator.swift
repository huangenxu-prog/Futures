import TradingChart

struct QihuiFormulaIndicator: ChartIndicator {
    let definition: FormulaDefinition
    let program: FormulaProgram
    var id: String { "formula:\(definition.id):\(definition.effectivePlatform.rawValue):\(definition.parameters ?? ""):\(definition.overlay):\(definition.source)" }
    var displayName: String { definition.name }
    var placement: IndicatorPlacement { definition.overlay ? .overlay : .pane }

    func calculate(_ input: IndicatorInput) -> IndicatorOutput {
        let bars = input.candles.map {
            FormulaBar(open:$0.open,high:$0.high,low:$0.low,close:$0.close,volume:$0.volume,
                       openInterest:$0.openInterest,closeInterest:$0.closeInterest)
        }
        guard let outputs = try? program.evaluate(bars) else { return .empty }
        var lines: [IndicatorLine] = []
        var histograms: [IndicatorHistogram] = []
        var sticks: [IndicatorStick] = []
        var signals: [IndicatorSignal] = []
        var segmentSeries: [IndicatorSegmentSeries] = []
        for (index,output) in outputs.enumerated() {
            let color = output.color.flatMap { ChartColor(hex:$0) }
            if let drawing = output.drawing {
                switch drawing {
                case .stick(let starts,let width,let hollow):
                    for i in bars.indices {
                        guard let start = starts[i], let end = output.values[i] else { continue }
                        sticks.append(IndicatorStick(time:input.candles[i].time,start:start,end:end,
                                                    width:width,hollow:hollow,color:color))
                    }
                case .segments(let segments):
                    let plotted = segments.map { segment in
                        IndicatorSegment(start:IndicatorValue(time:input.candles[segment.startIndex].time,value:segment.startValue),
                                         end:IndicatorValue(time:input.candles[segment.endIndex].time,value:segment.endValue))
                    }
                    segmentSeries.append(IndicatorSegmentSeries(segments:plotted,
                        style:IndicatorLineStyle(color:color,width:output.width)))
                case .signal(let label):
                    for (bar,value) in zip(input.candles,output.values) {
                        guard let value else { continue }
                        signals.append(IndicatorSignal(time:bar.time,value:value,text:label,color:color,fontSize:output.fontSize ?? 11))
                    }
                }
            } else if output.histogram {
                var histogramBars: [HistogramBar] = []
                let positive = ChartColor(red:1, green:0, blue:0)
                let negative = ChartColor(red:0, green:1, blue:0)
                for (bar,value) in zip(input.candles,output.values) {
                    guard let value, value.isFinite else { continue }
                    if definition.overlay && definition.effectivePlatform != .native {
                        sticks.append(IndicatorStick(time:bar.time,start:0,end:value,width:3,hollow:false,
                                                     color:color ?? (value < 0 ? negative : positive)))
                        continue
                    }
                    histogramBars.append(HistogramBar(time:bar.time,value:value,
                        tone:value > 0 ? .positive : value < 0 ? .negative : .neutral,color:color))
                }
                if !histogramBars.isEmpty {
                    histograms.append(IndicatorHistogram(id:"output.\(index)",name:output.name,bars:histogramBars))
                }
            } else {
                var values: [IndicatorValue] = []
                for (bar,value) in zip(input.candles,output.values) {
                    if let value, value.isFinite { values.append(IndicatorValue(time:bar.time,value:value)) }
                }
                lines.append(IndicatorLine(id:"output.\(index)",name:output.name,values:values,
                    style:IndicatorLineStyle(color:color,width:output.width),paletteSlot:index))
            }
        }
        return IndicatorOutput(lines:lines,histograms:histograms,
                               sticks:sticks.enumerated().sorted { a,b in a.element.time == b.element.time ? a.offset < b.offset : a.element.time < b.element.time }.map(\.element),
                               signals:signals.sorted { $0.time < $1.time },
                               segmentSeries:segmentSeries)
    }
}
