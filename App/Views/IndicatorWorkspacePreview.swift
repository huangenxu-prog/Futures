import SwiftUI
import TradingChart

/// Preview the real indicator implementation on an immutable OHLC snapshot.
/// The synthetic time axis represents bar order only, not actual market timestamps.
struct IndicatorWorkspacePreview: View {
    let bars: [FormulaBar]
    let settings: ChartDisplaySettings
    @Environment(\.colorScheme) private var scheme
    @State private var model = TradingChartModel()
    var body: some View {
        TradingChartView(model:model)
            .allowsHitTesting(false)
            .task(id:try? JSONEncoder().encode(settings)) { update() }
            .onChange(of:scheme) { _,_ in update() }
            .accessibilityLabel("真实K线指标预览")
    }
    private func update() {
        var configuration = TradingChartConfiguration()
        configuration.viewport.candleVisibleBars = 52
        configuration.showsPriceBadge = false
        configuration.showsCurrentPriceLine = false
        configuration.showsHighLowMarkers = false
        configuration.showsLegend = false
        configuration.stylePicker = nil
        configuration.isDrawingEnabled = false
        configuration.isCrosshairEnabled = false
        configuration.isZoomEnabled = false
        configuration.paneHeight = 85
        model.configuration = configuration
        model.style = .candles
        let candles = bars.enumerated().map { i,b in
            Candle(time:Date(timeIntervalSince1970:Double(i)*60),open:b.open,high:b.high,low:b.low,close:b.close,volume:b.volume,openInterest:b.openInterest,closeInterest:b.closeInterest)
        }
        model.indicators = settings.indicators(darkAppearance:scheme == .dark)
        model.setSeries(ChartSeries(candles:candles,interval:ChartInterval(seconds:60)))
    }
}
