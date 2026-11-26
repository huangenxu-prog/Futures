import SwiftUI

/// T-shaped options chain and exact-contract quick order entry.
/// Missing prices are shown as "--"; no fabricated IV or Greeks.
struct OptionChainView: View {
    let code: String
    let underlyingLast: Double?
    let underlyingName:String

    init(code: String, underlyingLast: Double? = nil,underlyingName:String? = nil) {
        self.code = code
        self.underlyingLast = underlyingLast
        self.underlyingName = underlyingName ?? code
    }

    @Environment(\.dismiss) private var dismiss
    @State private var rows: [MarketDataService.OptionQuote] = []
    @State private var loading = true
    @State private var error: String?
    @State private var displayVolume = false
    @State private var side: Side = .both
    @State private var selectedOption:MarketDataService.OptionQuote?

    private enum Side {
        case both, call, put
    }

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

    private var visiblePairs: [StrikePair] {
        switch side {
        case .both: return pairedRows
        case .call: return pairedRows.filter { $0.call != nil }
        case .put: return pairedRows.filter { $0.put != nil }
        }
    }

    private var visibleContractCount: Int {
        switch side {
        case .both: return rows.count
        case .call: return rows.filter { $0.side == "CALL" }.count
        case .put: return rows.filter { $0.side == "PUT" }.count
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
                        HStack(spacing: 8) {
                            sideButton("看涨 CALL", value: .call)
                            sideButton("全部", value: .both)
                            sideButton("看跌 PUT", value: .put)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)

                        HStack(spacing: 0) {
                            if side != .put {
                                headerCell(displayVolume ? "成交量" : "买一")
                                headerCell("最新")
                            }
                            Text("行权价")
                                .frame(width: 72)
                                .foregroundStyle(MarketPalette.ink)
                            if side != .call {
                                headerCell("最新")
                                headerCell(displayVolume ? "成交量" : "卖价")
                            }
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MarketPalette.muted)
                        .frame(height: 35)
                        .background(MarketPalette.background)

                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(visiblePairs) { pair in
                                    HStack(spacing: 0) {
                                        if side != .put {
                                            optionCells(pair.call,isCall:true)
                                        }
                                        Text(label(pair.strike))
                                            .font(.system(size: 13, weight: .bold, design: .rounded))
                                            .foregroundStyle(MarketPalette.ink)
                                            .frame(width: 72, height: 48)
                                            .background(underlyingLast.map {
                                                abs($0 - pair.strike) < max(1, $0 * 0.0025)
                                            } == true ? MarketPalette.accent.opacity(0.08) : .clear)
                                        if side != .call {
                                            optionCells(pair.put,isCall:false)
                                        }
                                    }
                                    .padding(.horizontal, 8)
                                    .overlay(alignment: .bottom) {
                                        Rectangle().fill(MarketPalette.divider).frame(height: 0.5)
                                    }
                                }
                            }
                        }
                        .refreshable {await load()}
                        HStack(spacing: 8) {
                            Button(displayVolume ? "查看买卖报价" : "查看成交量") {
                                displayVolume.toggle()
                            }
                            Spacer()
                            Text("\(visibleContractCount) 个合约 · \(visiblePairs.count) 个行权价")
                                .foregroundStyle(MarketPalette.muted)
                        }
                        .font(.system(size: 11))
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .background(MarketPalette.background)
                    }
                }

                Text("点击看涨或看跌报价即可下单 · 模拟买方交易")
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
            .sheet(item:$selectedOption) { option in
                QuickTradeSheet(contract:option.paperContract(underlying:code,name:underlyingName))
                    .presentationDetents([.height(460), .large])
                    .presentationDragIndicator(.visible)

            }
            .task(id: code) { await load() }
        }
        .tint(MarketPalette.accent)
    }

    private func sideButton(_ title: String, value: Side) -> some View {
        Button {
            side = value
        } label: {
            Text(title)
                .font(.system(size: 12, weight: side == value ? .semibold : .medium))
                .foregroundStyle(side == value ? MarketPalette.accent : MarketPalette.muted)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(side == value ? MarketPalette.accent.opacity(0.10) : MarketPalette.background)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(side == value ? .isSelected : [])
    }

    private func headerCell(_ title: String) -> some View {
        Text(title).frame(maxWidth: .infinity)
    }

    private func optionCells(_ option:MarketDataService.OptionQuote?,isCall:Bool)->some View {
        Button {
            if let option {selectedOption = option}
        } label:{
            HStack(spacing:0) {
                if isCall {
                    valueCell(displayVolume ? option?.volume : option?.bid)
                    valueCell(option?.last)
                } else {
                    valueCell(option?.last)
                    valueCell(displayVolume ? option?.volume : option?.ask)
                }
            }.frame(maxWidth:.infinity).frame(height:48).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(option == nil)
            .accessibilityLabel(option.map{(isCall ? "看涨 " : "看跌 ")+label($0.strike)+" 下单"} ?? "无合约")
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
