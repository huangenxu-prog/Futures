import SwiftUI
import Charts

struct StrategyBacktestView: View {
    @Environment(\.dismiss) private var dismiss
    let symbol: String
    let period: Int
    let formulas: [FormulaDefinition]
    let priceTick: Double?
    var contractMultiplier: Double? = nil
    @State private var source = "LONG:CROSS(EMA(C,20),EMA(C,50));\nSHORT:CROSS(EMA(C,50),EMA(C,20));"
    @State private var hunt = false
    @State private var multiPeriod = true
    @State private var multiplier = ""
    @State private var tick = ""
    @State private var margin = ""
    @State private var fee = ""
    @State private var lots = 1
    @State private var slip = 1
    @State private var risk = 1000.0
    @State private var target = 2.0
    @State private var protectProfit = true
    @State private var historyCount = 1200
    @State private var running = false
    @State private var result: BacktestResult?
    @State private var error: String?
    @State private var coverage = ""
    @State private var task: Task<Void,Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section("回测策略") {
                    Text("\(symbol) · \(hunt && multiPeriod ? 5 : period/60)分钟")
                    Picker("模式",selection:$hunt) {
                        Text("公式信号").tag(false)
                        Text("猎杀扫回候选").tag(true)
                    }
                    if hunt {
                        Toggle("60/30/5分钟联合研究",isOn:$multiPeriod)
                        if multiPeriod {
                            Text("固定5分钟执行，60分钟结构方向过滤、30分钟三笔重叠区离开方向过滤；不引用未收盘大周期K线。周五不新开。仍为研究版，未包含完整进入段、15分钟辅助分型与N形态放弃规则。")
                                .font(.caption)
                        } else {
                            Text("单周期候选：已确认高低点、HH+HL/LH+LL、刺破后收盘收回；不是完整猎杀系统。")
                                .font(.caption)
                        }
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
                    Picker("目标历史长度",selection:$historyCount) {
                        Text("500根").tag(500)
                        Text("1200根").tag(1200)
                        Text("3000根").tag(3000)
                        Text("6000根").tag(6000)
                    }
                    numberField("合约乘数",text:$multiplier)
                    numberField("最小变动价位",text:$tick)
                    numberField("保证金比例（%）",text:$margin)
                    numberField("每手单边手续费（元）",text:$fee)
                    Stepper("固定手数 \(lots)",value:$lots,in:1...100)
                    Stepper("单边滑点 \(slip) 跳",value:$slip,in:0...20)
                    HStack {
                        Text("计划净亏损上限（元）")
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
                    Toggle("盈利回撤归零离场",isOn:$protectProfit)
                    Text("净风险和止盈倍数包含设定手续费及滑点。收盘确认有净浮盈后，下根K线启用保本止损；同根内先盈后亏顺序无法由OHLC确定。跳空、涨跌停或实际成本可能导致更大亏损。固定每手费用、固定保证金率，不模拟逐日结算、阶梯费率或期权。")
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
                        LabeledContent("盈利 / 亏损 / 保本","\(result.wins) / \(result.losses) / \(result.breakevens)")
                        LabeledContent("盈利因子",result.profitFactor.map{$0.formatted(.number.precision(.fractionLength(2)))} ?? "—")
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
            .onAppear {
                if tick.isEmpty, let priceTick, priceTick > 0 { tick = String(priceTick) }
                if multiplier.isEmpty, let contractMultiplier, contractMultiplier > 0 { multiplier = String(contractMultiplier) }
            }
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
        var parameters = BacktestParameters(multiplier:m,tick:t,marginRate:g/100,feePerSide:c,
                                   slippageTicks:slip,lots:lots,stopRisk:risk,targetR:target)
        parameters.breakEvenAfterProfit = protectProfit
        let p = parameters
        let requested = historyCount
        guard p.valid else { error = "回测参数无效"; return }
        let code = source, useHunt = hunt, useMulti = hunt && multiPeriod
        let executionPeriod = useMulti ? 300 : period
        running = true; error = nil; result = nil
        task = Task {
            defer { running = false }
            do {
                let history = try await MarketDataService.backtestHistory(symbol:symbol,period:executionPeriod,count:requested)
                // Exclude newest bar conservatively, including when market
                // is closed, to avoid accidental unfinished-bar signals.
                let closed = Array(history.dropLast())
                guard closed.count >= 50 else { throw FormulaFailure("有效历史不足50根，请稍后补齐") }
                let bars = closed.map { FormulaBar(open:$0.open,high:$0.high,low:$0.low,close:$0.close,
                    volume:Double($0.volume),openInterest:$0.openInterest,closeInterest:$0.closeInterest) }
                var thirty: [MultiPeriodHunt.Timed] = []
                var hour: [MultiPeriodHunt.Timed] = []
                func timed(_ items:[MarketBar]) -> [MultiPeriodHunt.Timed] {
                    items.dropLast().map { b in
                        MultiPeriodHunt.Timed(time:b.time,bar:FormulaBar(open:b.open,high:b.high,low:b.low,close:b.close,
                            volume:Double(b.volume),openInterest:b.openInterest,closeInterest:b.closeInterest))
                    }
                }
                if useMulti {
                    thirty = timed(try await MarketDataService.backtestHistory(symbol:symbol,period:1800,count:max(1200,requested/6+600)))
                    hour = timed(try await MarketDataService.backtestHistory(symbol:symbol,period:3600,count:max(1200,requested/12+600)))
                    guard thirty.count >= 12,hour.count >= 12 else { throw FormulaFailure("多周期历史不足") }
                }
                let thirtyBars = thirty, hourBars = hour
                let five = zip(closed,bars).map { b,v in MultiPeriodHunt.Timed(time:b.time,bar:v) }
                let calculation = Task.detached(priority:.userInitiated) {
                    let signals: [BacktestSignal]
                    var researchNote = ""
                    if useHunt {
                        let candidates: [HuntSignals.Signal?]
                        if useMulti {
                            let filtered = MultiPeriodHunt.calculate(five:five,thirty:thirtyBars,hour:hourBars)
                            guard filtered.covered > 0 else { throw FormulaFailure("三周期历史没有足够的共同覆盖") }
                            candidates = filtered.signals
                            researchNote = " · 多周期覆盖\(filtered.covered)根，扫回候选\(filtered.candidates)个，方向过滤通过\(filtered.accepted)个"
                        } else { candidates = HuntSignals.calculate(bars) }
                        signals = candidates.map { s in
                            guard let s else { return BacktestSignal() }
                            let stop = s.extreme-Double(s.side)*p.tick
                            return BacktestSignal(long:s.side > 0,short:s.side < 0,stopPrice:stop)
                        }
                    } else {
                        signals = try FuturesBacktest.formulaSignals(code,bars:bars)
                    }
                    return (try FuturesBacktest.run(bars:bars,signals:signals,p:p),researchNote)
                }
                let (value,researchNote) = try await calculation.value
                try Task.checkCancellation()
                result = value
                let formatter = DateFormatter()
                formatter.timeZone = TimeZone(identifier:"Asia/Shanghai")
                formatter.dateFormat = "yyyy-MM-dd HH:mm"
                if let first = closed.first, let last = closed.last {
                    coverage = "目标\(requested)根，实际取得\(history.count)根，\(closed.count) 根用于回测（保守排除最后一根） · \(formatter.string(from:Date(timeIntervalSince1970:Double(first.time)))) 至 \(formatter.string(from:Date(timeIntervalSince1970:Double(last.time))))。样本内结果，不代表未来收益。\(researchNote)"
                }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}
