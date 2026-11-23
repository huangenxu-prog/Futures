import SwiftUI

/// A read-only T-shaped options chain. Values are genuine TqSdk quotes.
/// Missing prices are shown as "--"; no fabricated IV or Greeks.
struct OptionChainView: View {
    let code: String
    let underlyingLast: Double?

    init(code: String, underlyingLast: Double? = nil) {
        self.code = code
        self.underlyingLast = underlyingLast
    }

    @Environment(\.dismiss) private var dismiss
    @State private var rows: [MarketDataService.OptionQuote] = []
    @State private var loading = true
    @State private var error: String?
    @State private var displayVolume = false

    private struct StrikePair: Identifiable {
        let strike: Double
        let call: MarketDataService.OptionQuote?
        let put: MarketDataService.OptionQuote?
        var id: Double { strike }
    }

    private var pairedRows: [StrikePair] {
        let sorted = rows.sorted { $0.code < $1.code }
        let strikes = Array(Set(sorted.map(\.strike))).sorted()
        return strikes.map { strike in
            StrikePair(
                strike: strike,
                call: sorted.first { $0.strike == strike && $0.side == "CALL" },
                put: sorted.first { $0.strike == strike && $0.side == "PUT" }
            )
        }
    }

    private func label(_ value: Double?) -> String {
        value?.formatted(.number.precision(.fractionLength(0...2))) ?? "--"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("期权 T 型报价")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(MarketPalette.ink)
                        Text(code + " · 挂牌期权")
                            .font(.system(size: 12))
                            .foregroundStyle(MarketPalette.muted)
                    }
                    Spacer()
                    if let underlyingLast {
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("标的最新")
                                .font(.system(size: 10))
                                .foregroundStyle(MarketPalette.muted)
                            Text(label(underlyingLast))
                                .font(.system(size: 17, weight: .semibold, design: .rounded))
                                .foregroundStyle(MarketPalette.ink)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 14)

                if loading {
                    ProgressView("获取期权行情")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    VStack(spacing: 14) {
                        Text(error).foregroundStyle(MarketPalette.muted)
                        Button("重新加载") { Task { await load() } }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if pairedRows.isEmpty {
                    ContentUnavailableView("暂无挂牌期权", systemImage: "chart.bar.xaxis")
                } else {
                    VStack(spacing: 0) {
                        HStack {
                            Text("看涨 CALL")
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("看跌 PUT")
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(MarketPalette.accent)
                        .padding(.horizontal, 12)
                        .frame(height: 31)

                        HStack(spacing: 0) {
                            headerCell(displayVolume ? "成交量" : "买价")
                            headerCell("最新")
                            Text("行权价")
                                .frame(width: 84)
                                .foregroundStyle(MarketPalette.ink)
                            headerCell("最新")
                            headerCell(displayVolume ? "成交量" : "卖价")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MarketPalette.muted)
                        .frame(height: 35)
                        .background(MarketPalette.background)

                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(pairedRows) { pair in
                                    HStack(spacing: 0) {
                                        valueCell(displayVolume ? pair.call?.volume : pair.call?.bid)
                                        valueCell(pair.call?.last)
                                        Text(label(pair.strike))
                                            .font(.system(size: 13, weight: .bold, design: .rounded))
                                            .foregroundStyle(MarketPalette.ink)
                                            .frame(width: 84, height: 48)
                                            .background(underlyingLast.map {
                                                abs($0 - pair.strike) < max(1, $0 * 0.0025)
                                            } == true ? MarketPalette.accent.opacity(0.08) : .clear)
                                        valueCell(pair.put?.last)
                                        valueCell(displayVolume ? pair.put?.volume : pair.put?.ask)
                                    }
                                    .padding(.horizontal, 8)
                                    .overlay(alignment: .bottom) {
                                        Rectangle().fill(MarketPalette.divider).frame(height: 0.5)
                                    }
                                }
                            }
                        }
                        HStack(spacing: 8) {
                            Button(displayVolume ? "查看买卖报价" : "查看成交量") {
                                displayVolume.toggle()
                            }
                            Spacer()
                            Text("\(rows.count) 个合约 · \(pairedRows.count) 个行权价")
                                .foregroundStyle(MarketPalette.muted)
                        }
                        .font(.system(size: 11))
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .background(MarketPalette.background)
                    }
                }

                Text("报价仅供行情分析；隐含波动率与希腊值尚未接入，不展示估算值。")
                    .font(.system(size: 10))
                    .foregroundStyle(MarketPalette.muted)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
            .background(MarketPalette.surface.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top) {
                HStack {
                    Spacer()
                    Button("完成") { dismiss() }
                        .font(.system(size: 14))
                        .padding(.trailing, 16)
                }
                .frame(height: 28)
                .background(MarketPalette.surface)
            }
            .task(id: code) { await load() }
        }
        .tint(MarketPalette.accent)
        .preferredColorScheme(.light)
    }

    private func headerCell(_ title: String) -> some View {
        Text(title).frame(maxWidth: .infinity)
    }

    private func valueCell(_ value: Double?) -> some View {
        Text(label(value))
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(value == nil ? MarketPalette.muted : MarketPalette.ink)
            .frame(maxWidth: .infinity)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }

    @MainActor private func load() async {
        loading = rows.isEmpty
        defer { loading = false }
        do {
            rows = try await MarketDataService.options(for: code)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
