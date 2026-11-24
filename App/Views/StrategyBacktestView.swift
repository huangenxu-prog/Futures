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
    @State private var hunt = false
    @State private var multiPeriod = true
    @State private var requireFifteen = true
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
                    Text("\(symbol) · \(hunt && multiPeriod ? 5 : period/60)分钟")
                    Picker("模式",selection:$hunt) {
                        Text("公式信号").tag(false)
                        Text("猎杀扫回候选").tag(true)
                    }
                    if hunt {
                        Toggle("60/30/5分钟联合研究",isOn:$multiPeriod)
                        if multiPeriod {
                            Toggle("15分钟辅助分型过滤",isOn:$requireFifteen)
                            Text("60分钟方向、30分钟重叠区离开代理、5分钟扫回后二次分型确认。可选15分钟最近确认分型。反向高低点N代理、重入30分钟重叠区或方向失效退出。周五不新开；不引用未收盘大周期K线。研究定义尚非完整心法。")
                                .font(.caption)
                        } else {
                            Text("单周期研究：扫回后二次分型确认，期间极值破坏或反向N代理取消。不是完整猎杀系统。")
                                .font(.caption)
                        }
                    } else {
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
                }
                Section("模拟账户") {
                    LabeledContent("初始本金",value:"¥50,000")
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
                    numberField("保证金比例（%）",text:$margin)
                    numberField("每手单边手续费（元）",text:$fee)
                    Stepper("固定手数 \(lots)",value:$lots,in:1...100)
                    Stepper("单边滑点 \(slip) 跳",value:$slip,in:0...20)
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
                    Text("净风险和止盈倍数包含设定手续费及滑点。收盘确认有净浮盈后，下根K线启用保本止损；同根内先盈后亏顺序无法由OHLC确定。跳空、涨跌停或实际成本可能导致更大亏损。固定每手费用、固定保证金率，不模拟逐日结算、阶梯费率或期权。")
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
                        LabeledContent("净盈亏",value:(result.final-result.initial).formatted(.currency(code:"CNY")))
                        LabeledContent("收益率",value:((result.final/result.initial)-1).formatted(.percent.precision(.fractionLength(2))))
                        LabeledContent("胜率",value:result.winRate.map{$0.formatted(.percent.precision(.fractionLength(1)))} ?? "无成交")
                        LabeledContent("交易次数",value:String(result.trades.count))
                        LabeledContent("盈利 / 亏损 / 保本",value:"\(result.wins) / \(result.losses) / \(result.breakevens)")
                        LabeledContent("盈利因子",value:result.profitFactor.map{$0.formatted(.number.precision(.fractionLength(2)))} ?? "—")
                        LabeledContent("累计手续费",value:result.totalFees.formatted(.currency(code:"CNY")))
                        LabeledContent("平均每笔R",value:result.averageR.map{$0.formatted(.number.precision(.fractionLength(2)))} ?? "—")
                        LabeledContent("最大回撤",value:result.maxDrawdown.formatted(.percent.precision(.fractionLength(2))))
                        LabeledContent("拒绝入场",value:String(result.rejected))
                        LabeledContent("同根止盈止损冲突",value:String(result.ambiguous))
                        LabeledContent("模拟保证金不足",value:String(result.marginCalls))
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
            .onChange(of:hunt) { _,_ in dismissInput() }
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
        guard let m = Double(multiplier), let t = Double(tick),let g = Double(margin),let c = Double(fee) else {
            error = "请填写合约乘数、最小价位、保证金比例和单边手续费。"; return
        }
        var parameters = BacktestParameters(multiplier:m,tick:t,marginRate:g/100,feePerSide:c,
                                   slippageTicks:slip,lots:lots,stopRisk:risk,targetR:target)
        parameters.breakEvenAfterProfit = protectProfit
        let p = parameters
        let requested = historyCount, warmup = warmupCount
        guard p.valid else { error = "回测参数无效"; return }
        let code = source, useHunt = hunt, useMulti = hunt && multiPeriod
        let useFifteen = useMulti && requireFifteen
        let executionPeriod = useMulti ? 300 : period
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
                var thirty: [MultiPeriodHunt.Timed] = []
                var hour: [MultiPeriodHunt.Timed] = []
                var fifteen: [MultiPeriodHunt.Timed] = []
                func timed(_ items:[MarketBar]) -> [MultiPeriodHunt.Timed] {
                    items.dropLast().map { b in
                        MultiPeriodHunt.Timed(time:b.time,bar:FormulaBar(open:b.open,high:b.high,low:b.low,close:b.close,
                            volume:Double(b.volume),openInterest:b.openInterest,closeInterest:b.closeInterest))
                    }
                }
                if useMulti {
                    phase = "获取30分钟历史"
                    thirty = timed(try await MarketDataService.backtestHistory(symbol:symbol,period:1800,count:max(1200,(requested+warmup)/6+600)))
                    phase = "获取60分钟历史"
                    hour = timed(try await MarketDataService.backtestHistory(symbol:symbol,period:3600,count:max(1200,(requested+warmup)/12+600)))
                    if useFifteen {
                        phase = "获取15分钟历史"
                        fifteen = timed(try await MarketDataService.backtestHistory(symbol:symbol,period:900,count:max(1200,(requested+warmup)/3+600)))
                    }
                    guard thirty.count >= 12,hour.count >= 12,!useFifteen || fifteen.count >= 12 else { throw FormulaFailure("多周期历史不足") }
                }
                let thirtyBars = thirty, hourBars = hour, fifteenBars = fifteen
                let five = zip(closed,bars).map { b,v in MultiPeriodHunt.Timed(time:b.time,bar:v) }
                phase = "计算信号与模拟成交"
                let calculation = Task.detached(priority:.userInitiated) {
                    let signals: [BacktestSignal]
                    var researchNote = ""
                    if useHunt {
                        let candidates: [HuntSignals.Signal?]
                        let exitLong: [Bool], exitShort: [Bool]
                        if useMulti {
                            let filtered = MultiPeriodHunt.calculate(five:five,thirty:thirtyBars,hour:hourBars,
                                fifteen:fifteenBars,requireFifteen:useFifteen)
                            guard filtered.covered > 0 else { throw FormulaFailure("多周期历史没有足够的共同覆盖") }
                            candidates = filtered.signals
                            exitLong = filtered.exitsLong; exitShort = filtered.exitsShort
                            researchNote = " · 多周期覆盖\(filtered.covered)根，二次确认\(filtered.confirmed)个，失效\(filtered.invalidated)个，超时\(filtered.expired)个，联合过滤通过\(filtered.accepted)个"
                        } else {
                            let confirmed = HuntConfirmation.calculate(bars,candidates:HuntSignals.calculate(bars))
                            candidates = confirmed.signals
                            exitLong = confirmed.reverseN.map { $0 == -1 }
                            exitShort = confirmed.reverseN.map { $0 == 1 }
                            researchNote = " · 扫回\(confirmed.candidates)个，二次确认\(confirmed.confirmed)个，失效\(confirmed.invalidated)个，超时\(confirmed.expired)个"
                        }
                        signals = candidates.enumerated().map { i,s in
                            var signal = BacktestSignal(exitLong:exitLong[i],exitShort:exitShort[i])
                            if let s {
                                signal.long = s.side > 0 && !exitLong[i]
                                signal.short = s.side < 0 && !exitShort[i]
                                signal.stopPrice = s.extreme-Double(s.side)*p.tick
                            }
                            return signal
                        }
                    } else {
                        signals = try FuturesBacktest.formulaSignals(code,bars:bars)
                    }
                    return (try FuturesBacktest.run(bars:bars,signals:signals,p:p,startIndex:startIndex),researchNote)
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
