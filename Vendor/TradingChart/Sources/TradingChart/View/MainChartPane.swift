import SwiftUI
import Charts
import TradingChartCore

/// The main panel: the series, the overlay indicators, the current price line, the markers, the drawings, the crosshair,
/// the legend and the price badge.
@available(iOS 17.0, *)
struct MainChartPane: View {
    @Bindable var model: TradingChartModel
    /// Whether this pane is the lowest one and therefore carries the time labels.
    let isBottomPane: Bool

    @Environment(\.tradingChartTheme) private var theme
    @Environment(\.tradingChartPriceFormatter) private var priceFormatter

    /// Everything the marks need, computed once per body evaluation.
    private struct Layout {
        var xDomain: ClosedRange<Date>
        /// The Y domain the chart is laid out for; the autoscaled one is shown by a transform (see ``YTransform``).
        var yDomain: ClosedRange<Double>
        /// A domain as wide as the one shown (a doji body is widened by a share of it).
        var bodySpanDomain: ClosedRange<Double>
        /// Bars inside the render window; only these get marks.
        var indices: Range<Int>
        /// The style actually drawn: candles fall back to a line when the series has no OHLC data.
        var drawnStyle: SeriesStyle
        var bodyWidth: CGFloat
        var overlayBands: [IndicatorBandItem]
        var overlayLines: [IndicatorLineItem]
        var series: ChartSeries
    }

    var body: some View {
        let _ = model.renderCounters.mainBodies += 1
        let input = model.renderInput
        let layout = makeLayout(input)
        model.renderCounters.builtWindows["main"] = model.renderWindow
        model.renderCounters.builtBases["main"] = model.mainYBase
        return VStack(spacing: 0) {
            MainLegendRow(model: model)
            GeometryReader { proxy in
                paneBody(layout: layout, geometry: PaneGeometry(size: proxy.size, theme: theme, isBottomPane: isBottomPane))
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func makeLayout(_ input: RenderData) -> Layout {
        let series = input.series
        let baseSpan = (model.mainYBase.upperBound - model.mainYBase.lowerBound) / YTransformMath.frameRatio
        let bodySpan = baseSpan.isFinite ? baseSpan : 0
        let xDomain = model.chartXDomain(for: series)
        let overlays = overlayOutputs(input)
        let renderRange = model.renderWindow
        let drawnStyle: SeriesStyle = model.style == .candles && !series.hasCandles ? .line : model.style
        return Layout(
            xDomain: xDomain,
            yDomain: model.mainYBase,
            bodySpanDomain: 0...bodySpan,
            indices: series.indexRange(in: renderRange),
            drawnStyle: drawnStyle,
            bodyWidth: ViewportMath.candleBodyWidth(
                plotWidth: model.plotWidth,
                visibleBars: model.visibleBars,
                factor: theme.candleBodyWidthFactor,
                min: theme.minCandleBodyWidth,
                max: theme.maxCandleBodyWidth
            ),
            overlayBands: overlays.flatMap { bandItems(of: $0.output, base: $0.base, range: renderRange) },
            overlayLines: overlays.flatMap { lineItems(of: $0.output, base: $0.base, range: renderRange) },
            series: series
        )
    }

    /// The cached outputs of the overlay indicators, in indicator order, with their first palette index.
    private func overlayOutputs(_ input: RenderData) -> [(output: IndicatorOutput, base: Int)] {
        model.indicators.compactMap { indicator in
            guard indicator.placement == .overlay, let output = input.outputs[indicator.id] else { return nil }
            return (output, input.paletteBase(for: indicator.id))
        }
    }

    private func lineItems(of output: IndicatorOutput, base: Int, range: ClosedRange<Date>) -> [IndicatorLineItem] {
        output.lines.map { line in
            let color = line.style.color.map(Color.init)
                ?? theme.paletteColor(at: base + Swift.max(line.paletteSlot, 0))
            return IndicatorLineItem(
                id: line.id,
                color: color,
                width: CGFloat(line.style.width),
                dash: line.style.dash.map { CGFloat($0) },
                values: IndicatorRendering.slice(line.values, in: range)
            )
        }
    }

    private func bandItems(of output: IndicatorOutput, base: Int, range: ClosedRange<Date>) -> [IndicatorBandItem] {
        output.bands.map { band in
            let color = band.fill.map(Color.init)
                ?? theme.paletteColor(at: base + Swift.max(band.paletteSlot, 0))
            return IndicatorBandItem(
                id: band.id,
                color: color,
                opacity: band.fillOpacity,
                points: IndicatorRendering.bandPoints(upper: band.upper, lower: band.lower, in: range)
            )
        }
    }

    /// The pane below the legend: the axes behind, the chart (moved by the transform to the autoscaled domain and
    /// clipped to the plot), the marks drawn by hand and the overlays.
    private func paneBody(layout: Layout, geometry: PaneGeometry) -> some View {
        let plot = geometry.plot
        return ZStack(alignment: .topLeading) {
            PaneAxes(
                model: model,
                geometry: geometry,
                yTarget: { model.mainYTarget },
                yDesiredCount: model.configuration.yAxisDesiredCount,
                yLabel: { priceFormatter.format($0, context: .axis) },
                showsTimeLabels: isBottomPane
            )
            chart(layout)
                .allowsHitTesting(false)
                .frame(width: plot.width, height: plot.height * YTransformMath.frameRatio)
                .modifier(YTransform(model: model, state: nil, plotHeight: plot.height))
                .frame(width: plot.width, height: plot.height, alignment: .top)
                .clipped()
            hollowCandleLayer(layout: layout, plot: plot)
            ChartInputLayer(model: model, takesDrawingTouches: true)
                .frame(width: plot.width, height: plot.height)
            MainMarksOverlay(model: model, plot: plot, drawnStyle: layout.drawnStyle)
            DrawingsOverlay(model: model, plot: plot)
            overlays(layout: layout, geometry: geometry)
        }
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        // The pane is the accessibility container of the chart: what VoiceOver says about it, and its scroll gesture and
        // actions, are here (the scroll view of Swift Charts below it takes the gesture and does nothing with it). A container,
        // so that the badge button and the chart's own elements keep their labels.
        .accessibilityElement(children: .contain)
        .modifier(ChartAccessibility(model: model))
        .onChange(of: geometry, initial: true) { _, new in
            model.updateLayoutMetrics(plotWidth: new.plot.width, yAxisColumnWidth: new.columnWidth)
        }
        .background {
            // Measures the badge so that the right padding of the x domain keeps the last bar clear of it.
            PriceBadgeHost(model: model, plot: plot, chartWidth: geometry.size.width, isProbe: true)
        }
    }


    /// Locally customized candlesticks: hollow rising bodies, solid falling
    /// bodies, and white doji. Use the same scroll window and autoscaled
    /// Y-domain as the chart axes, so history paging and zoom remain aligned.
    @ViewBuilder
    private func hollowCandleLayer(layout: Layout, plot: CGRect) -> some View {
        if theme.hollowRisingCandles,
           layout.drawnStyle == .candles,
           let candles = layout.series.candles {
            let visible = model.visibleTimeRange
            let priceRange = model.mainYTarget
            let width = layout.bodyWidth
            let theme = theme
            Canvas { context, _ in
                let span = visible.upperBound.timeIntervalSince(visible.lowerBound)
                guard span > 0, plot.width > 0, plot.height > 0 else { return }
                let yMapping = YMapping(domain: priceRange, height: plot.height)
                for candle in candles[layout.indices] {
                    let seconds = candle.time.timeIntervalSince(visible.lowerBound)
                    let x = CGFloat(seconds / span) * plot.width
                    guard x >= -width, x <= plot.width + width else { continue }
                    let yHigh = yMapping.y(of: candle.high)
                    let yLow = yMapping.y(of: candle.low)
                    let yOpen = yMapping.y(of: candle.open)
                    let yClose = yMapping.y(of: candle.close)
                    guard [x, yHigh, yLow, yOpen, yClose].allSatisfy(\.isFinite) else { continue }

                    let doji = candle.open == candle.close
                    let rising = candle.close > candle.open
                    let color = doji ? theme.dojiCandleColor
                        : (rising ? theme.bullish : theme.bearish)

                    var wick = Path()
                    wick.move(to: CGPoint(x: x, y: yHigh))
                    wick.addLine(to: CGPoint(x: x, y: yLow))
                    context.stroke(wick, with: .color(color), lineWidth: theme.wickWidth)

                    if doji {
                        var crossbar = Path()
                        crossbar.move(to: CGPoint(x: x - width / 2, y: yOpen))
                        crossbar.addLine(to: CGPoint(x: x + width / 2, y: yOpen))
                        context.stroke(crossbar, with: .color(color), lineWidth: max(1.3, theme.wickWidth))
                    } else {
                        let yTop = min(yOpen, yClose)
                        let rect = CGRect(x: x - width / 2, y: yTop,
                                          width: width, height: max(1, abs(yClose - yOpen)))
                        let body = Path(rect)
                        if rising {
                            context.fill(body, with: .color(theme.hollowCandleFill))
                            context.stroke(body, with: .color(color), lineWidth: max(1, theme.wickWidth))
                        } else {
                            context.fill(body, with: .color(color))
                        }
                    }
                }
            }
            .frame(width: plot.width, height: plot.height)
            .clipped()
            .allowsHitTesting(false)
        }
    }

    private func chart(_ layout: Layout) -> some View {
        let _ = model.renderCounters.chartBuilds += 1
        return Chart {
            bandMarks(layout.overlayBands)
            seriesMarks(layout)
            overlayLineMarks(layout.overlayLines)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartXScale(domain: layout.xDomain)
        .chartYScale(domain: layout.yDomain)
        .chartScrollableAxes(.horizontal)
        .chartXVisibleDomain(length: model.chartVisibleDuration)
        .modifier(ChartScrollBridge(model: model))
        .accessibilityElement(children: .contain)
    }

    /// The price badge, the crosshair (its lines, labels and tooltip, and its haptic tick) and the history spinner, over the plot and
    /// the price column.
    @ViewBuilder
    private func overlays(layout: Layout, geometry: PaneGeometry) -> some View {
        let plot = geometry.plot
        HistoryLoadingOverlay(model: model, visiblePlot: plot)
        PriceBadgeHost(model: model, plot: plot, chartWidth: geometry.size.width, isProbe: false)
        CrosshairLayer(
            model: model,
            geometry: geometry,
            isBottomPane: isBottomPane,
            valueDomain: { model.mainYTarget },
            showsPriceLabel: true,
            tooltip: model.configuration.showsLegend
                ? TooltipContent(drawnStyle: layout.drawnStyle)
                : nil
        )
        CrosshairHaptic(model: model)
    }

    // MARK: - Marks

    @ChartContentBuilder
    private func seriesMarks(_ layout: Layout) -> some ChartContent {
        let series = layout.series
        if layout.drawnStyle == .candles, let candles = series.candles {
            if !theme.hollowRisingCandles {
                ForEach(candles[layout.indices]) { candle in
                let color = candle.isBullish ? theme.bullish : theme.bearish
                let body = ViewportMath.candleBodyRange(candle, yDomain: layout.bodySpanDomain)
                RuleMark(
                    x: .value("Time", candle.time),
                    yStart: .value("Low", candle.low),
                    yEnd: .value("High", candle.high)
                )
                .lineStyle(StrokeStyle(lineWidth: theme.wickWidth))
                .foregroundStyle(color)

                RectangleMark(
                    x: .value("Time", candle.time),
                    yStart: .value("Open", body.lowerBound),
                    yEnd: .value("Close", body.upperBound),
                    width: .fixed(layout.bodyWidth)
                )
                .foregroundStyle(color)
                .cornerRadius(theme.candleCornerRadius)
                }
            }
        } else {
            ForEach(series.points[layout.indices]) { point in
                LineMark(
                    x: .value("Time", point.time),
                    y: .value("Price", point.value),
                    series: .value("Series", "price")
                )
                .foregroundStyle(theme.line)
                .lineStyle(StrokeStyle(lineWidth: theme.lineWidth, lineCap: .round, lineJoin: .round))
                .interpolationMethod(theme.lineInterpolation.chartsMethod)

                if layout.drawnStyle == .area {
                    AreaMark(
                        x: .value("Time", point.time),
                        yStart: .value("Min", layout.yDomain.lowerBound),
                        yEnd: .value("Price", point.value)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                theme.line.opacity(theme.areaTopOpacity),
                                theme.line.opacity(theme.areaBottomOpacity),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(theme.lineInterpolation.chartsMethod)
                }
            }
        }
    }

    @ChartContentBuilder
    private func bandMarks(_ bands: [IndicatorBandItem]) -> some ChartContent {
        ForEach(bands) { band in
            ForEach(band.points, id: \.time) { point in
                AreaMark(
                    x: .value("Time", point.time),
                    yStart: .value("Lower", point.lower),
                    yEnd: .value("Upper", point.upper),
                    series: .value("Band", band.id)
                )
                .foregroundStyle(band.color.opacity(band.opacity))
            }
        }
    }

    @ChartContentBuilder
    private func overlayLineMarks(_ lines: [IndicatorLineItem]) -> some ChartContent {
        ForEach(lines) { line in
            ForEach(line.values, id: \.time) { value in
                LineMark(
                    x: .value("Time", value.time),
                    y: .value("Value", value.value),
                    series: .value("Indicator", line.id)
                )
                .foregroundStyle(line.color)
                .lineStyle(StrokeStyle(lineWidth: line.width, lineCap: .round, lineJoin: .round, dash: line.dash))
                .interpolationMethod(.linear)
            }
        }
    }
}
