import SwiftUI
import TradingChart

struct InstrumentDetailView: View {
    let instrument: FuturesInstrument
    @State private var chartModel = TradingChartModel(style: .candles)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                priceHeader
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("K线").font(.headline)
                        Spacer()
                        Text("15分钟").font(.caption).foregroundStyle(.secondary)
                    }
                    TradingChartView(model: chartModel)
                        .frame(height: 340)
                        .background(Color(uiColor: .secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                Text("当前K线为本地生成的演示数据，不代表真实市场行情。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle(instrument.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { loadDemoCandles() }
    }

    private var priceHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(instrument.name).font(.title2.weight(.bold))
            Text("\(instrument.id) · \(instrument.exchange)")
                .font(.caption).foregroundStyle(.secondary)
            Text(instrument.lastPrice.formatted())
                .font(.largeTitle.monospacedDigit().weight(.bold))
            Text("\(instrument.change >= 0 ? "+" : "")\(instrument.change.formatted())  \(instrument.changePercent, format: .number.precision(.fractionLength(2)))%")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(instrument.isRising ? .red : .green)
        }
    }

    private func loadDemoCandles() {
        let now = Date()
        let base = instrument.lastPrice
        let candles = (0..<80).map { index -> Candle in
            let wave = sin(Double(index) * 0.37) * base * 0.002
            let drift = Double(index - 40) * base * 0.00012
            let open = base + wave + drift
            let close = open + cos(Double(index) * 0.61) * base * 0.0015
            let high = max(open, close) + base * (0.0004 + Double(index % 4) * 0.0001)
            let low = min(open, close) - base * (0.0004 + Double(index % 3) * 0.0001)
            return Candle(
                time: now.addingTimeInterval(Double(index - 79) * 15 * 60),
                open: open, high: high, low: low, close: close,
                volume: Double(120 + (index * 37) % 260)
            )
        }
        chartModel.setSeries(ChartSeries(candles: candles, interval: .minutes(15)))
        chartModel.currentPrice = candles.last?.close
    }
}
