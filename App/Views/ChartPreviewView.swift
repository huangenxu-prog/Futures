import SwiftUI
import TradingChart

struct ChartPreviewView: View {
    @State private var model = TradingChartModel(style: .candles)

    var body: some View {
        TradingChartView(model: model)
            .frame(height: 320)
    }
}
