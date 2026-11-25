import SwiftUI
import Charts

struct StrategyBacktestView: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: String?
    let symbol: String
    let period: Int
    let formulas: [FormulaDefinition]
    let priceTick: Double?
    var contractMultiplier: Double? = nil
    @State private var source = "LONG:CROSS(EMA(C,20),EMA(C,50));\nSHORT:CROSS(EMA(C,50),EMA(C,20));"
    @State private var multiplier = ""
    @State private var tick = ""
    @State private var initial = 50_000.0
    @State private var lots = 1
    @State private var risk = 1000.0
    @State private var target = 2.0
    @State private var protectProfit = true
    @State private var historyCount = 1200
    @State private var warmupCount = 500
    @State private var resultTimes: [Int64] = []
    @State private var phase = ""
    @State private var running = false
    @State private var result: BacktestResult?
    @State private var error: String?
    @State private var coverage = ""
    @State private var task: Task<Void,Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section("回测策略") {
                    Text("\(symbol) · \(period/60)分钟")
                        if !formulas.isEmpty {
                            Menu("载入已有公式") {
                                ForEach(formulas) { formula in
                                    Button(formula.name) { dismissInput(); source = formula.source }
                                }
                            }
                        }
                        TextEditor(text:$source).font(.system(size:12,design:.monospaced))
    .focused($focusedField,equals:"source")
                            .frame(minHeight:110).autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Text("LONG/SHORT：多空信号，EXIT：平仓，STOP：可选结构止损价。信号在收盘确认，下一根开盘成交。")
                            .font(.caption)
                }
                Section("模拟账户") {
                    TextField("初始本金（元）", value: $initial, format: .number).keyboardType(.decimalPad)
                    Picker("目标历史长度",selection:$historyCount) {
                        Text("500根").tag(500)
                        Text("1200根").tag(1200)
                        Text("3000根").tag(3000)
                        Text("6000根").tag(6000)
                    }
                    Picker("指标预热",selection:$warmupCount) {
                        Text("200根").tag(200)
                        Text("500根").tag(500)
                        Text("1000根").tag(1000)
                    }
                    Text("预热K线只用于指标和结构计算，不计入模拟交易。实际预热不足会明确提示。").font(.caption)
                    numberField("合约乘数",text:$multiplier)
                    numberField("最小变动价位",text:$tick)
                    Stepper("固定手数 \(lots)",value:$lots,in:1...100)
                    HStack {
                        Text("计划净亏损上限（元）")
                        Spacer()
                        TextField("风险",value:$risk,format:.number).keyboardType(.decimalPad)
    .focused($focusedField,equals:"risk")
                            .multilineTextAlignment(.trailing).frame(width:100)
                    }
                    HStack {
                        Text("止盈倍数（0关闭）")
                        Spacer()
                        TextField("倍数",value:$target,format:.number).keyboardType(.decimalPad)
    .focused($focusedField,equals:"target")
                            .multilineTextAlignment(.trailing).frame(width:90)
                    }
                    Toggle("盈利回撤归零离场",isOn:$protectProfit)
                    Text("理论回测未计入手续费、滑点及保证金限制，不代表实际交易收益或持仓能力。同根止盈止损冲突按止损优先处理。")
                        .font(.caption)
                }
                Section {
                    Button(running ? "正在回测…" : "开始回测") { start() }
                        .disabled(running)
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
                        Text("未计入手续费、滑点及保证金限制").font(.caption).foregroundStyle(.secondary)
                        Text(coverage).font(.caption).foregroundStyle(.secondary)
                        Chart(Array(result.equity.enumerated()),id:\.offset) { item in
                            LineMark(x:.value("K线",item.offset),y:.value("权益",item.element))
                        }
                        .chartYScale(domain:.automatic(includesZero:false))
                        .frame(height:150)
                    }
                    Section("最近成交") {
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
            .scrollDismissesKeyboard(.immediately)
            .onSubmit { dismissInput() }
            .navigationTitle("指标回测")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("关闭") { dismissInput(); dismiss() } }
                ToolbarItemGroup(placement:.keyboard) {
                    Spacer()
                    Button("完成") { dismissInput() }.fontWeight(.semibold)
                }
            }
            .onAppear {
                if tick.isEmpty, let priceTick, priceTick > 0 { tick = String(priceTick) }
                if multiplier.isEmpty, let contractMultiplier, contractMultiplier > 0 { multiplier = String(contractMultiplier) }
            }
            .onDisappear { task?.cancel() }
        }
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

    private func numberField(_ title:String,text:Binding<String>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("填写",text:text).keyboardType(.decimalPad)
    .focused($focusedField,equals:title)
                .multilineTextAlignment(.trailing).frame(width:95)
        }
    }
    private func start() {
        dismissInput()
        guard let m = Double(multiplier), let t = Double(tick) else {
            error = "缺少合约乘数或最小变动价位，请核对合约数据。"; return
        }
        var parameters = BacktestParameters(initial:initial,multiplier:m,tick:t,marginRate:1,feePerSide:0,
                                   slippageTicks:0,lots:lots,stopRisk:risk,targetR:target)
        parameters.ignoreMargin = true
        parameters.breakEvenAfterProfit = protectProfit
        let p = parameters
        let requested = historyCount, warmup = warmupCount
        guard p.valid else { error = "回测参数无效"; return }
        let code = source, executionPeriod = period
        running = true; error = nil; result = nil; resultTimes = []; phase = "获取历史K线"
        task = Task {
            defer { running = false }
            do {
                let history = try await MarketDataService.backtestHistory(symbol:symbol,period:executionPeriod,count:requested+warmup+1)
                // Exclude newest bar conservatively, including when market
                // is closed, to avoid accidental unfinished-bar signals.
                let closed = Array(history.dropLast())
                guard closed.count >= 50 else { throw FormulaFailure("有效历史不足50根") }
                // Preserve at least 50 tradable bars when the exchange
                // returns less history than requested; never invent data.
                let startIndex = min(warmup,max(0,closed.count-50))
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
