import SwiftUI

/// TqSdk's real listed delivery months, not a hard-coded contract calendar.
struct ContractListView: View {
    @AppStorage("qihui.change.basis.v1") private var changeBasis = "settlement"
    let instrument: FuturesInstrument
    var currentCode: String? = nil
    var onSelect: ((MarketDataService.ContractQuote) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.mainContracts) private var mainQuotes
    @State private var contracts: [MarketDataService.ContractQuote] = []
    @State private var isLoading = true
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("查询挂牌合约")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorText {
                    VStack(spacing: 12) {
                        Text(errorText)
                            .font(.subheadline)
                            .foregroundStyle(MarketPalette.muted)
                        Button("重试") { Task { await load() } }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if contracts.isEmpty {
                    ContentUnavailableView("暂无挂牌合约", systemImage: "list.bullet.rectangle")
                } else {
                    List {
                        ForEach(contracts) { contract in
                            if let onSelect {
                                Button { onSelect(contract) } label: {
                                    contractRow(contract)
                                }.buttonStyle(.plain)
                            } else {
                                NavigationLink {
                                    InstrumentDetailView(instrument: instrument, selectedContract: contract)
                                } label: {
                                    contractRow(contract)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .refreshable { await load() }
                }
            }
            .background(MarketPalette.background.ignoresSafeArea())
            .navigationTitle(instrument.name + " · 交割月份")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await load() }
        }
        .tint(MarketPalette.accent)
    }

    private func contractRow(_ contract: MarketDataService.ContractQuote) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(instrument.name + contract.month)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(MarketPalette.ink)
                        if mainQuotes[instrument.id]?.code == contract.code {
                            Text("主力")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(MarketPalette.accent)
                        }
                    }
                    Text(contract.code)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(MarketPalette.muted)
                }
                Spacer(minLength: 5)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(contract.last?.formatted() ?? "--")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text(contract.changePercent(basis: changeBasis))
                        .font(.system(size: 12, design: .rounded))
                }
                .monospacedDigit()
                .foregroundStyle(MarketPalette.movement(contract.change(basis: changeBasis)))
            }
            .padding(.vertical, 6)
            if currentCode == contract.code {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MarketPalette.accent)
            }
        }
        .contentShape(Rectangle())
    }

    @MainActor
    private func load() async {
        isLoading = contracts.isEmpty
        defer { isLoading = false }
        do {
            contracts = try await MarketDataService.listedContracts(for: instrument.id)
            errorText = nil
        } catch {
            errorText = "合约月份暂不可用，请确认行情网关已升级。"
        }
    }
}
