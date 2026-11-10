import SwiftUI

struct InstrumentDetailView: View {
    let instrument: FuturesInstrument

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(instrument.name)
                        .font(.title2.weight(.bold))
                    Text("\(instrument.id) · \(instrument.exchange)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(instrument.lastPrice.formatted())
                        .font(.largeTitle.monospacedDigit().weight(.bold))
                    Text("\(instrument.change >= 0 ? "+" : "")\(instrument.change.formatted())  \(instrument.changePercent, format: .number.precision(.fractionLength(2)))%")
                        .foregroundStyle(instrument.isRising ? .red : .green)
                }

                ContentUnavailableView(
                    "K线图开发中",
                    systemImage: "chart.xyaxis.line",
                    description: Text("下一阶段接入K线、成交量、EMA20和EMA50。")
                )
                .frame(maxWidth: .infinity, minHeight: 260)

                Text("当前价格为静态演示数据，不代表真实市场报价。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle(instrument.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
