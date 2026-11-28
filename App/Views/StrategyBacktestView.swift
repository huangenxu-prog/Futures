import SwiftUI
import Charts

struct StrategyBacktestView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.qihuiInPageStack) private var inPageStack
    @FocusState private var focusedField: String?
    let instruments: [FuturesInstrument]
    let favoriteIDs: [String]
    let mainCodes: [String:String]
    let formulas: [FormulaDefinition]
    @State private var productID = ""
    @State private var symbol = ""
    @State private var period = 1800
    @State private var strategyID = "default"
    @AppStorage("qihui.backtest.strategy-parameters.v1") private var savedParameters = Data()
    private struct StrategyParameters: Codable {
        var risk: Double = 1000
        var target: Double = 2
        var protectProfit: Bool = true
        var customSource: String? = nil
    }
    @State private var contracts: [MarketDataService.ContractQuote] = []
    @State private var loadingContracts = false
    @State private var contractError: String?
    @State private var showTrades = false
    private var chosen: MarketDataService.ContractQuote? { contracts.first { $0.code == symbol } }
    private var sortedProducts: [FuturesInstrument] {
        instruments.sorted {
            let a = favoriteIDs.firstIndex(of: $0.id) ?? Int.max
            let b = favoriteIDs.firstIndex(of: $1.id) ?? Int.max
            return a == b ? $0.name.localizedCompare($1.name) == .orderedAscending : a < b
        }
    }
    @State private var source = "LONG:CROSS(EMA(C,20),EMA(C,50));\nSHORT:CROSS(EMA(C,50),EMA(C,20));"
    private let initial = 50_000.0
    private let lots = 1
    @State private var risk = 1000.0
    @State private var target = 2.0
    @State private var protectProfit = true
    private let historyCount = 500
    private let warmupCount = 500
    @State private var resultTimes: [Int64] = []
    @State private var phase = ""
    @State private var running = false
    @State private var result: BacktestResult?
    @State private var error: String?
    @State private var coverage = ""
    @State private var task: Task<Void,Never>?

    var body: some View {
        QihuiPageStack {
            Form {
                Section("回测条件") {
                    Picker("策略", selection: $strategyID) {
                        Text("EMA20/50 交叉").tag("default")
                        ForEach(formulas) { formula in Text(formula.name).tag(formula.id.uuidString) }
                        Text("自定义策略").tag("custom")
                    }
                    Picker("品种", selection: $productID) {
                        Text("请选择").tag("")
                        ForEach(sortedProducts) { item in Text(item.name).tag(item.id) }
                    }
                    if loadingContracts { ProgressView("读取合约") }
                    if let contractError {
                        Text(contractError).font(.caption).foregroundStyle(.red)
                        Button("重试") { Task { await loadContracts(productID) } }
                    }
                    Picker("合约", selection: $symbol) {
                        Text("请选择").tag("")
                        ForEach(contracts) { contract in
                            Text(contract.code + (contract.code == mainCodes[productID] ? " · 主力" : "")).tag(contract.code)
                        }
                    }.disabled(loadingContracts || contracts.isEmpty)
                    Picker("周期", selection: $period) {
                        ForEach([60,180,300,600,900,1800,3600,7200,86400,604800], id: \.self) { seconds in
                            Text(seconds == 86400 ? "日线" : seconds == 604800 ? "周线" : "\(seconds/60)分钟").tag(seconds)
                        }
                    }
                    Text("本金5万元 · 最近500根已收盘K线 · 固定1手").font(.caption).foregroundStyle(.secondary)
                }.disabled(running)
                if strategyID == "custom" {
                    Section("自定义策略") {
                        TextEditor(text: $source).font(.system(size:12,design:.monospaced))
                            .focused($focusedField,equals:"source").frame(minHeight:110)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                        Text("LONG / SHORT：入场；EXIT：平仓；STOP：结构止损。").font(.caption)
                    }.disabled(running)
                }
                Section {
                    DisclosureGroup("策略参数") {
                        HStack {
                            Text("计划净亏损上限")
                            Spacer()
                            TextField("风险", value: $risk, format: .number).keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing).frame(width:100)
                        }
                        HStack {
                            Text("止盈倍数")
                            Spacer()
                            TextField("倍数", value: $target, format: .number).keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing).frame(width:90)
                        }
                        Toggle("盈利回撤归零离场", isOn: $protectProfit)
                    }
                }.disabled(running)
                Section {
                    Button(running ? "正在回测…" : "开始回测") { start() }
                        .disabled(running || chosen == nil || loadingContracts)
                    if running {
                        ProgressView(phase)
                        Button("取消回测",role:.cancel) { task?.cancel() }
                    }
                    if let error { Text(error).foregroundStyle(.red).font(.caption) }
                }
                if let result {
                    Section("回测结果") {
                        LabeledContent("期末权益",value:result.final.formatted(.currency(code:"CNY")))
                        LabeledContent("理论盈亏",value:(result.final-result.initial).formatted(.currency(code:"CNY")))
                        LabeledContent("收益率",value:((result.final/result.initial)-1).formatted(.percent.precision(.fractionLength(2))))
                        LabeledContent("胜率",value:result.winRate.map{$0.formatted(.percent.precision(.fractionLength(1)))} ?? "无成交")
                        LabeledContent("交易次数",value:String(result.trades.count))
                        LabeledContent("盈利 / 亏损 / 保本",value:"\(result.wins) / \(result.losses) / \(result.breakevens)")
                        LabeledContent("盈利因子",value:result.profitFactor.map{$0.formatted(.number.precision(.fractionLength(2)))} ?? "—")
                        LabeledContent("平均每笔R",value:result.averageR.map{$0.formatted(.number.precision(.fractionLength(2)))} ?? "—")
                        LabeledContent("最大回撤",value:result.maxDrawdown.formatted(.percent.precision(.fractionLength(2))))
                        LabeledContent("拒绝入场",value:String(result.rejected))
                        LabeledContent("同根止盈止损冲突",value:String(result.ambiguous))
                        Text("每边1跳滑点；未计入手续费及保证金限制").font(.caption).foregroundStyle(.secondary)
                        if result.trades.count < 30 { Text("交易样本较少").font(.caption).foregroundStyle(.orange) }
                        Text(coverage).font(.caption).foregroundStyle(.secondary)
                        Chart(Array(result.equity.enumerated()),id:\.offset) { item in
                            LineMark(x:.value("K线",item.offset),y:.value("权益",item.element))
                        }
                        .chartYScale(domain:.automatic(includesZero:false))
                        .frame(height:150)
                    }
                    Section("最近成交") {
                        DisclosureGroup("交易明细", isExpanded: $showTrades) {
                        ForEach(result.trades.suffix(50)) { trade in
                            VStack(alignment:.leading) {
                                Text("\(trade.side > 0 ? "多" : "空") · \(trade.reason)")
                                Text("\(barTime(trade.entryIndex)) → \(barTime(trade.exitIndex))")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("成交 \(trade.entry.formatted()) → \(trade.exit.formatted()) · \(trade.net.formatted(.currency(code:"CNY")))")
                                    .font(.caption)
                                Text("初始止损 \(trade.initialStop.formatted()) · 计划风险 \(trade.plannedRisk.formatted(.currency(code:"CNY"))) · \(trade.realizedR.formatted(.number.precision(.fractionLength(2))))R")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.immediately)
            .onSubmit { dismissInput() }
            .navigationTitle("策略中心")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !inPageStack {
                    ToolbarItem(placement:.cancellationAction) { Button("关闭") { dismissInput(); dismiss() } }
                }
                ToolbarItemGroup(placement:.keyboard) {
                    Spacer()
                    Button("完成") { dismissInput() }.fontWeight(.semibold)
                }
            }
            .task(id: productID) { await loadContracts(productID) }
            .onAppear { restoreParameters(for: strategyID) }
            .onChange(of: strategyID) { old, value in
                persistParameters(for: old)
                if value == "default" { source = "LONG:CROSS(EMA(C,20),EMA(C,50));\nSHORT:CROSS(EMA(C,50),EMA(C,20));" }
                else if let formula = formulas.first(where: { $0.id.uuidString == value }) { source = formula.source }
                restoreParameters(for: value)
                result = nil; error = nil
            }
            .onChange(of: risk) { _, _ in result = nil; error = nil }
            .onChange(of: target) { _, _ in result = nil; error = nil }
            .onChange(of: protectProfit) { _, _ in result = nil; error = nil }
            .onChange(of: source) { _, _ in result = nil; error = nil }
            .onChange(of: symbol) { _, _ in result = nil; error = nil }
            .onChange(of: period) { _, _ in result = nil; error = nil }
            .onDisappear { persistParameters(for: strategyID); task?.cancel() }
        }
    }

    private func restoreParameters(for id: String) {
        let all = (try? JSONDecoder().decode([String: StrategyParameters].self, from: savedParameters)) ?? [:]
        let p = all[id] ?? StrategyParameters()
        risk = p.risk; target = p.target; protectProfit = p.protectProfit
        if id == "custom" {
            source = p.customSource ?? "LONG:CROSS(EMA(C,20),EMA(C,50));\nSHORT:CROSS(EMA(C,50),EMA(C,20));"
        }
    }

    private func persistParameters(for id: String) {
        guard risk.isFinite, risk > 0, target.isFinite, (0...100).contains(target) else { return }
        var all = (try? JSONDecoder().decode([String: StrategyParameters].self, from: savedParameters)) ?? [:]
        all[id] = StrategyParameters(risk: risk, target: target, protectProfit: protectProfit,
                                     customSource: id == "custom" ? source : nil)
        if let data = try? JSONEncoder().encode(all) { savedParameters = data }
    }

    private func dismissInput() {
        focusedField = nil
        IndicatorKeyboard.dismiss()
    }

    private func barTime(_ index:Int) -> String {
        guard resultTimes.indices.contains(index) else { return "—" }
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier:"Asia/Shanghai")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from:Date(timeIntervalSince1970:Double(resultTimes[index])))
    }

    @MainActor private func loadContracts(_ id: String) async {
        contracts = []; symbol = ""; contractError = nil
        guard !id.isEmpty else { loadingContracts = false; return }
        loadingContracts = true
        defer { if productID == id { loadingContracts = false } }
        do {
            let rows = try await MarketDataService.listedContracts(for: id)
            guard !Task.isCancelled, productID == id else { return }
            contracts = rows
            symbol = rows.first(where: { $0.code == mainCodes[id] })?.code ?? rows.first?.code ?? ""
            if rows.isEmpty { contractError = "暂无挂牌合约" }
        } catch {
            guard !Task.isCancelled, productID == id else { return }
            contractError = error.localizedDescription
        }
    }
    private func start() {
        dismissInput()
        guard let chosen, let m = chosen.volumeMultiple, let t = chosen.priceTick else {
            error = "缺少合约乘数或最小变动价位，请核对合约数据。"; return
        }
        var parameters = BacktestParameters(initial:initial,multiplier:m,tick:t,marginRate:1,feePerSide:0,
                                   slippageTicks:1,lots:lots,stopRisk:risk,targetR:target)
        parameters.ignoreMargin = true
        parameters.breakEvenAfterProfit = protectProfit
        let p = parameters
        let requested = historyCount, warmup = warmupCount
        guard p.valid else { error = "回测参数无效"; return }
        persistParameters(for: strategyID)
        let code = source, executionPeriod = period, executionSymbol = symbol
        running = true; error = nil; result = nil; resultTimes = []; phase = "获取历史K线"
        task = Task {
            defer { running = false }
            do {
                let history = try await MarketDataService.backtestHistory(symbol:executionSymbol,period:executionPeriod,count:requested+warmup+1)
                // Exclude newest bar conservatively, including when market
                // is closed, to avoid accidental unfinished-bar signals.
                let closed = Array(history.dropLast().suffix(requested + warmup))
                guard closed.count >= 50 else { throw FormulaFailure("有效历史不足50根") }
                // Preserve at least 50 tradable bars when the exchange
                // returns less history than requested; never invent data.
                let startIndex = max(0, closed.count-requested)
                let testCount = closed.count-startIndex
                let bars = closed.map { FormulaBar(open:$0.open,high:$0.high,low:$0.low,close:$0.close,
                    volume:Double($0.volume),openInterest:$0.openInterest,closeInterest:$0.closeInterest) }
                phase = "计算信号与模拟成交"
                let calculation = Task.detached(priority:.userInitiated) {
                    let signals = try FuturesBacktest.formulaSignals(code,bars:bars)
                    return (try FuturesBacktest.run(bars:bars,signals:signals,p:p,startIndex:startIndex),"")
                }
                let (value,researchNote) = try await withTaskCancellationHandler {
                    try await calculation.value
                } onCancel: { calculation.cancel() }
                try Task.checkCancellation()
                resultTimes = closed.map(\.time)
                result = value
                let formatter = DateFormatter()
                formatter.timeZone = TimeZone(identifier:"Asia/Shanghai")
                formatter.dateFormat = "yyyy-MM-dd HH:mm"
                if let first = closed.dropFirst(startIndex).first, let last = closed.last {
                    coverage = "目标样本\(requested)根，实际\(testCount)根，预热\(startIndex)/\(warmup)根，排除最新一根。\(formatter.string(from:Date(timeIntervalSince1970:Double(first.time)))) 至 \(formatter.string(from:Date(timeIntervalSince1970:Double(last.time))))。样本内结果，不代表未来收益。\(researchNote)"
                }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}
