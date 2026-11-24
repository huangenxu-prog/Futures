import SwiftUI
import TradingChartCore

/// A scrollable trading chart driven by a ``TradingChartModel``.
///
/// The main panel shows the series and the overlay indicators; every indicator that has its own pane
/// (``IndicatorPlacement/pane``) and something to draw gets a panel below, scrolling in sync with the main one.
///
/// ```swift
/// let model = TradingChartModel(series: series, style: .candles)
/// model.indicators = [SMA(period: 20), Volume(), RSI()]
///
/// TradingChartView(model: model)
///     .tradingChartTheme(.standard)
/// ```
@available(iOS 17.0, *)
public struct TradingChartView: View {
    private let model: TradingChartModel

    @Environment(\.tradingChartTheme) private var theme
    @Environment(\.layoutDirection) private var hostLayoutDirection

    /// Creates a chart for `model`.
    public init(model: TradingChartModel) {
        self.model = model
    }

    private struct PaneItem: Identifiable {
        var indicator: any ChartIndicator
        var output: IndicatorOutput
        var state: PaneRenderState
        var id: String { indicator.id }
    }

    /// The indicators that get a pane: placed in a pane and with something to draw.
    private var panes: [PaneItem] {
        let input = model.renderInput
        return model.indicators.compactMap { indicator in
            guard indicator.placement == .pane,
                  let output = input.outputs[indicator.id],
                  !output.isEmpty
            else { return nil }
            return PaneItem(indicator: indicator, output: output, state: model.paneState(for: indicator.id))
        }
    }

    /// The chart.
    public var body: some View {
        let panes = panes
        VStack(spacing: 0) {
            MainChartPane(model: model, isBottomPane: panes.isEmpty)
            ForEach(Array(panes.enumerated()), id: \.element.id) { offset, pane in
                Rectangle()
                    .fill(theme.paneSeparator)
                    .frame(height: 1)
                IndicatorPane(
                    model: model,
                    indicator: pane.indicator,
                    output: pane.output,
                    state: pane.state,
                    isBottomPane: offset == panes.count - 1
                )
            }
        }
        // Time runs from left to right and the price scale is at the right in every language, as in every exchange app: the
        // chart is not mirrored in a right-to-left host. Only the words of the tooltip follow the host (see `CrosshairTooltip`).
        .environment(\.tradingChartHostLayoutDirection, hostLayoutDirection)
        .environment(\.layoutDirection, .leftToRight)
        // What the autoscale at the edges of the window assumes about the width of a candle is the theme's.
        .onChange(of: CandleMetrics(theme: theme), initial: true) { _, metrics in
            model.updateCandleMetrics(metrics)
        }
    }

}
