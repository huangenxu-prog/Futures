import SwiftUI
import Charts

struct StrategyBacktestView: View {
    @Environment(\.dismiss) private var dismiss
    let symbol: String
    let period: Int
    let formulas: [FormulaDefinition]
    let priceTick: Double?
    @State private var source = "LONG:CROSS(EMA(C,20),EMA(C,50));\nSHORT:CROSS(EMA(C,50),EMA(C,20));"
    @State private var hunt = false
    @State private var multiplier = ""
    @State private var tick = ""
    @State private var margin = ""
    @State private var fee = ""
    @State private var lots = 1
    @State private var slip = 1
    @State private var risk = 1000.0
    @State private var target = 2.0
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
                    Picker("模式",selection:$hunt) {
                        Text("公式信号").tag(false)
                        Text("猎杀扫回候选").tag(true)
                    }
                    if hunt {
                        Text("单周期候选：已确认高低点、HH+HL/LH+LL、刺破后收盘收回；不是完整的1小时/30分钟/5分钟猎杀系统。")
                            .font(.caption)
                    } else {
                        if !formulas.isEmpty {
                            Menu("载入已有公式") {
                                ForEach(formulas) { formula in
                                    Button(formula.name) { source = formula.source }
                                }
                            }
                        }
                        TextEditor(text:$source).font(.system(size:12,design:.monospaced))
                            .frame(minHeight:110).autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Text("LONG/SHORT：多空信号，EXIT：平仓，STOP：可选结构止损价。信号在收盘确认，下一根开盘成交。")
                            .font(.caption)
                    }
                }
                Section("模拟账户") {
                    LabeledContent("初始本金","¥50,000")
                    numberField("合约乘数",text:$multiplier)
                    numberField("最小变动价位",text:$tick)
                    numberField("保证金比例（%）",text:$margin)
                    numberField("每手单边手续费（元）",text:$fee)
                    Stepper("固定手数 \(lots)",value:$lots,in:1...100)
                    Stepper("单边滑点 \(slip) 跳",value:$slip,in:0...20)
                    HStack {
                        Text("单笔价格风险上限（元）")
                        Spacer()
                        TextField("风险",value:$risk,format:.number).keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing).frame(width:100)
                    }
                    HStack {
                        Text("止盈倍数（0关闭）")
                        Spacer()
                        TextField("倍数",value:$target,format:.number).keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing).frame(width:90)
                    }
                    Text("需填写真实合约参数。当前采用固定每手费用、固定保证金率，不模拟交易所逐日结算、涨跌停无法成交、阶梯费率或期权。跳空、费用及滑点可使实际亏损超过风险上限。")
                        .font(.caption)
                }
                Section {
                    Button(running ? "正在回测…" : "开始回测") { start() }
                        .disabled(running)
                    if running { ProgressView() }
                    if let error { Text(error).foregroundStyle(.red).font(.caption) }
                }
                if let result {
                    Section("回测结果") {
                        LabeledContent("期末权益",result.final.formatted(.currency(code:"CNY")))
                        LabeledContent("净盈亏",(result.final-result.initial).formatted(.currency(code:"CNY")))
                        LabeledContent("收益率",((result.final/result.initial)-1).formatted(.percent.precision(.fractionLength(2))))
                        LabeledContent("胜率",result.winRate.map{$0.formatted(.percent.precision(.fractionLength(1)))} ?? "无成交")
                        LabeledContent("交易次数",String(result.trades.count))
                        LabeledContent("盈利 / 亏损","\(result.wins) / \(result.losses)")
                        LabeledContent("最大回撤",result.maxDrawdown.formatted(.percent.precision(.fractionLength(2))))
                        LabeledContent("拒绝入场",String(result.rejected))
                        LabeledContent("同根止盈止损冲突",String(result.ambiguous))
                        LabeledContent("模拟保证金不足",String(result.marginCalls))
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
                                Text("第 \(trade.entryIndex+1) → \(trade.exitIndex+1) 根 · \(trade.net.formatted(.currency(code:"CNY")))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("指标回测")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.cancellationAction) { Button("关闭"){ dismiss() } } }
            .onAppear { if let priceTick, priceTick > 0 { tick = String(priceTick) } }
            .onDisappear { task?.cancel() }
        }
    }

    private func numberField(_ title:String,text:Binding<String>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("填写",text:text).keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing).frame(width:95)
        }
    }
    private func start() {
        guard let m = Double(multiplier), let t = Double(tick),let g = Double(margin),let c = Double(fee) else {
            error = "请填写合约乘数、最小价位、保证金比例和单边手续费。"; return
        }
        let p = BacktestParameters(multiplier:m,tick:t,marginRate:g/100,feePerSide:c,
                                   slippageTicks:slip,lots:lots,stopRisk:risk,targetR:target)
        guard p.valid else { error = "回测参数无效"; return }
        let code = source, useHunt = hunt
        running = true; error = nil; result = nil
        task = Task {
            defer { running = false }
            do {
                let history = try await MarketDataService.fetch(symbol:symbol,period:period,count:1200,mergeCached:false)
                // Exclude newest bar conservatively, including when market
                // is closed, to avoid accidental unfinished-bar signals.
                let closed = Array(history.dropLast())
                guard closed.count >= 50 else { throw FormulaFailure("有效历史不足50根，请稍后补齐") }
                let bars = closed.map { FormulaBar(open:$0.open,high:$0.high,low:$0.low,close:$0.close,
                    volume:Double($0.volume),openInterest:$0.openInterest,closeInterest:$0.closeInterest) }
                let calculation = Task.detached(priority:.userInitiated) {
                    let signals: [BacktestSignal]
                    if useHunt {
                        signals = HuntSignals.calculate(bars).map { s in
                            guard let s else { return BacktestSignal() }
                            let stop = s.extreme-Double(s.side)*p.tick
                            return BacktestSignal(long:s.side > 0,short:s.side < 0,stopPrice:stop)
                        }
                    } else {
                        signals = try FuturesBacktest.formulaSignals(code,bars:bars)
                    }
                    return try FuturesBacktest.run(bars:bars,signals:signals,p:p)
                }
                let value = try await calculation.value
                try Task.checkCancellation()
                result = value
                let formatter = DateFormatter()
                formatter.timeZone = TimeZone(identifier:"Asia/Shanghai")
                formatter.dateFormat = "yyyy-MM-dd HH:mm"
                if let first = closed.first, let last = closed.last {
                    coverage = "\(closed.count) 根已完成K线（保守排除最后一根） · \(formatter.string(from:Date(timeIntervalSince1970:Double(first.time)))) 至 \(formatter.string(from:Date(timeIntervalSince1970:Double(last.time))))。样本内结果，不代表未来收益。"
                }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}
