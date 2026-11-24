import SwiftUI

/// Strategy research is independent of the selected live chart. The user
/// chooses a concrete listed contract before downloading historical data.
struct StrategyCenterView: View {
    @Environment(\.dismiss) private var dismiss
    let instruments: [FuturesInstrument]
    let favoriteIDs: [String]
    let mainCodes: [String:String]
    @State private var search = ""

    private var matching: [FuturesInstrument] {
        let keyword = search.trimmingCharacters(in:.whitespacesAndNewlines)
        let filtered = instruments.filter { item in
            keyword.isEmpty || item.name.localizedCaseInsensitiveContains(keyword)
                || item.id.localizedCaseInsensitiveContains(keyword)
                || (mainCodes[item.id]?.localizedCaseInsensitiveContains(keyword) ?? false)
        }
        let favoriteOrder = Dictionary(uniqueKeysWithValues:favoriteIDs.enumerated().map { ($0.element,$0.offset) })
        return filtered.sorted { a,b in
            let ai = favoriteOrder[a.id] ?? Int.max, bi = favoriteOrder[b.id] ?? Int.max
            return ai == bi ? a.name.localizedCompare(b.name) == .orderedAscending : ai < bi
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("选择回测品种，再选择具体月份合约及周期。支持自定义公式与猎杀研究；模拟本金5万元，不会发送真实交易指令。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("选择品种") {
                    ForEach(matching) { item in
                        NavigationLink {
                            StrategyContractPicker(instrument:item,mainCode:mainCodes[item.id])
                        } label: {
                            HStack {
                                VStack(alignment:.leading,spacing:4) {
                                    Text(item.name)
                                    Text(item.id).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let main = mainCodes[item.id] {
                                    Text(main).font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if matching.isEmpty { Text("没有匹配的品种").foregroundStyle(.secondary) }
                }
            }
            .searchable(text:$search,prompt:"搜索回测品种")
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("策略中心")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.cancellationAction) { Button("关闭"){ IndicatorKeyboard.dismiss(); dismiss() } } }
        }
        .tint(MarketPalette.accent)
    }
}

private struct StrategyContractPicker: View {
    let instrument: FuturesInstrument
    let mainCode: String?
    @State private var contracts: [MarketDataService.ContractQuote] = []
    @State private var chosenCode = ""
    @State private var period = 300
    @State private var loading = false
    @State private var error: String?
    @State private var showingBacktest = false

    private var chosen: MarketDataService.ContractQuote? {
        contracts.first { $0.code == chosenCode }
    }

    var body: some View {
        Form {
            Section("回测合约") {
                if loading { ProgressView("读取真实合约…") }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                    Button("重试") { Task { await load() } }
                }
                if !contracts.isEmpty {
                    Picker("月份合约",selection:$chosenCode) {
                        ForEach(contracts) { contract in
                            Text(contract.code+(contract.code == mainCode ? " · 主力" : "")).tag(contract.code)
                        }
                    }
                }
                Picker("公式执行周期",selection:$period) {
                    Text("1分钟").tag(60)
                    Text("5分钟").tag(300)
                    Text("15分钟").tag(900)
                    Text("30分钟").tag(1800)
                    Text("60分钟").tag(3600)
                    Text("日线").tag(86400)
                }
                Text("多周期猎杀固定5分钟执行。使用具体月份合约，不拼接不同合约的价格。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("进入回测") { showingBacktest = true }
                    .disabled(chosen == nil || loading)
            }
        }
        .navigationTitle(instrument.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(isPresented:$showingBacktest) {
            if let chosen {
                StrategyBacktestView(symbol:chosen.code,period:period,
                    formulas:ChartDisplaySettings.load().formulas,priceTick:chosen.priceTick,
                    contractMultiplier:chosen.volumeMultiple)
            }
        }
    }

    @MainActor
    private func load() async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let result = try await MarketDataService.listedContracts(for:instrument.id)
            try Task.checkCancellation()
            contracts = result
            if let mainCode, result.contains(where:{$0.code == mainCode}) { chosenCode = mainCode }
            else { chosenCode = result.first?.code ?? "" }
            if result.isEmpty { error = "暂无可回测的月份合约" }
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}
