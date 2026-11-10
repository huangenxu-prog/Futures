import SwiftUI

struct MarketHomeView: View {
    @State private var instruments = FuturesInstrument.samples

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    marketHeader
                    marketSummary
                    instrumentSection
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("期汇")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {} label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("搜索合约")
                }
            }
        }
    }

    private var marketHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("国内期货")
                .font(.title2.weight(.bold))
            Text("行情数据为演示数据，非实时行情")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var marketSummary: some View {
        HStack(spacing: 12) {
            summaryCard(title: "上涨", value: "\(instruments.filter(\.isRising).count)", tint: .red)
            summaryCard(title: "下跌", value: "\(instruments.filter { !$0.isRising }.count)", tint: .green)
            summaryCard(title: "自选合约", value: "\(instruments.count)", tint: .primary)
        }
    }

    private func summaryCard(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.monospacedDigit().weight(.semibold))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var instrumentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("重点合约")
                    .font(.headline)
                Spacer()
                Text("模拟")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(instruments) { item in
                NavigationLink {
                    InstrumentDetailView(instrument: item)
                } label: {
                    InstrumentRow(instrument: item)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
