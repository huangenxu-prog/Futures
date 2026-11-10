import SwiftUI
import TradingChart

struct InstrumentDetailView: View {
    private struct PeriodOption: Identifiable, Hashable {
        let title: String
        let interval: ChartInterval
        var id: ChartInterval { interval }
    }

    private static let periods: [PeriodOption] = [
        .init(title: "1分", interval: .minutes(1)),
        .init(title: "5分", interval: .minutes(5)),
        .init(title: "15分", interval: .minutes(15)),
        .init(title: "30分", interval: .minutes(30)),
        .init(title: "60分", interval: .hours(1)),
        .init(title: "日线", interval: .days(1))
    ]

    let instrument: FuturesInstrument
    @State private var chartModel = TradingChartModel(style: .candles)
    @State private var selectedPeriod: ChartInterval = .minutes(15)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                priceHeader
                chartSection
                marketStats
                dataNotice
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(instrument.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { loadDemoCandles() }
        .onChange(of: selectedPeriod) { _, _ in loadDemoCandles() }
    }

    private var priceHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(instrument.name).font(.headline)
                    Text("\(instrument.id) · \(instrument.exchange)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("模拟行情")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.12), in: Capsule())
                    .foregroundStyle(.orange)
            }
            Text(instrument.lastPrice.formatted())
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text("\(instrument.change >= 0 ? "+" : "")\(instrument.change.formatted())  \(instrument.changePercent, format: .number.precision(.fractionLength(2)))%")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(instrument.isRising ? .red : .green)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("K线走势").font(.headline)
                Spacer()
                Text("蜡烛图").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 0) {
                ForEach(Self.periods) { option in
                    let selected = selectedPeriod == option.interval
                    Button {
                        selectedPeriod = option.interval
                    } label: {
                        Text(option.title)
                            .font(.system(size: 13, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 9))

            TradingChartView(model: chartModel)
                .frame(height: 340)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 14) {
                indicatorLegend("EMA20", color: .orange)
                indicatorLegend("EMA50", color: .blue)
                indicatorLegend("VOL", color: .secondary)
            }
            .font(.caption2)
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func indicatorLegend(_ title: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).foregroundStyle(.secondary)
        }
    }

    private var marketStats: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("行情概览").font(.headline)
            HStack {
                statItem("最新价", value: instrument.lastPrice.formatted())
                Spacer()
                statItem("涨跌额", value: instrument.change.formatted())
                Spacer()
                statItem("涨跌幅", value: String(format: "%.2f%%", instrument.changePercent))
            }
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func statItem(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.monospacedDigit().weight(.medium))
        }
    }

    private var dataNotice: some View {
        Label("当前图表为本地生成的演示数据，不代表真实市场行情。", systemImage: "info.circle")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func loadDemoCandles() {
        let now = Date()
        let base = instrument.lastPrice
        let interval = selectedPeriod
        let seconds = interval.seconds
        let candles = (0..<160).map { index -> Candle in
            let wave = sin(Double(index) * 0.37) * base * 0.002
            let drift = Double(index - 80) * base * 0.00012
            let open = base + wave + drift
            let close = open + cos(Double(index) * 0.61) * base * 0.0015
            let high = max(open, close) + base * (0.0004 + Double(index % 4) * 0.0001)
            let low = min(open, close) - base * (0.0004 + Double(index % 3) * 0.0001)
            return Candle(
                time: now.addingTimeInterval(Double(index - 159) * seconds),
                open: open,
                high: high,
                low: low,
                close: close,
                volume: Double(120 + (index * 37) % 260)
            )
        }
        chartModel.setSeries(ChartSeries(candles: candles, interval: interval))
        chartModel.currentPrice = candles.last?.close
        chartModel.indicators = [EMA(period: 20), EMA(period: 50), Volume(movingAveragePeriod: 20)]
    }
}
