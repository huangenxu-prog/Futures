import Foundation
import TradingChart

/// Immutable snapshot computed outside the chart's synchronous render pipeline.
/// Actual exchange timestamps must be mapped to the synthetic chart axis.
struct PineChartIndicator: ChartIndicator {
    let id: String
    let displayName: String
    let placement: IndicatorPlacement
    let snapshot: IndicatorOutput

    func calculate(_ input: IndicatorInput) -> IndicatorOutput {
        snapshot
    }

    static func make(id: String, name: String, overlay: Bool,
                     plots: [PineRuntimePlot],
                     actualToChart: [Int64: Date]) -> PineChartIndicator {
        let lines = plots.enumerated().map { index, plot in
            var valuesByDate: [Date: Double] = [:]
            for point in plot.points {
                guard let timestamp = point.time, timestamp.isFinite,
                      let milliseconds = Int64(exactly: timestamp),
                      let chartTime = actualToChart[milliseconds],
                      let value = point.value, value.isFinite else { continue }
                valuesByDate[chartTime] = value
            }
            let values = valuesByDate.sorted { $0.key < $1.key }.map {
                IndicatorValue(time: $0.key, value: $0.value)
            }
            return IndicatorLine(id: "pine.\(index)", name: plot.name,
                                 values: values, paletteSlot: index)
        }
        return PineChartIndicator(id: id, displayName: name,
                                  placement: overlay ? .overlay : .pane,
                                  snapshot: IndicatorOutput(lines: lines))
    }
}
