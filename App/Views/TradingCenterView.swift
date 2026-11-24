import SwiftUI

/// Local simulation only. Real-trading access cannot be enabled by a toggle.
struct TradingCenterView:View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.futuresCatalog) private var catalog
    @AppStorage("qihui.paper-ledger.v1") private var saved = Data()
    @State private var ledger = PaperLedger()
    @State private var tab:Tab = .account
    @State private var ticket:PaperContract?
    @State private var picking = false
    @State private var resetConfirmation = false
    @State private var error:String?
    @State private var fillConfirmation:PaperOrder?
    @State private var cancelConfirmation:PaperOrder?
    @State private var restored = false
    var initialContract:PaperContract? = nil

    private enum Tab:String,CaseIterable {
        case account = "资金", positions = "持仓", orders = "委托", fills = "成交"
    }
    var body:some View {
        NavigationStack {
            VStack(spacing:0) {
                HStack(spacing:8) {
                    Image(systemName:"shield.lefthalf.filled")
                    Text("本地模拟 · 不连接交易账户").fontWeight(.semibold)
                    Spacer()
                    Text("实盘未开通").foregroundStyle(.secondary)
                }.font(.caption).foregroundStyle(MarketPalette.accent)
                    .padding(12).background(MarketPalette.raised)
                Picker("交易记录",selection:$tab) {
                    ForEach(Tab.allCases,id:\.self){Text($0.rawValue).tag($0)}
                }.pickerStyle(.segmented).padding(12)
                List {
                    switch tab {
                    case .account: accountSection
                    case .positions: positionsSection
                    case .orders: ordersSection
                    case .fills: fillsSection
                    }
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                }.listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    .scrollDismissesKeyboard(.immediately)
                Button {
                    if let initialContract { ticket = initialContract }
                    else { picking = true }
                } label: {
                    Text(initialContract == nil ? "选择合约 · 模拟下单" : "模拟下单 · "+(initialContract?.name ?? ""))
                        .fontWeight(.semibold).frame(maxWidth:.infinity).padding(12)
                }.buttonStyle(.borderedProminent).padding(12)
            }
            .background(MarketPalette.background)
            .navigationTitle("交易")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("关闭"){dismiss()} }
                ToolbarItem(placement:.topBarTrailing) {
                    Menu {
                        Button("重置模拟账户",role:.destructive){resetConfirmation = true}
                    } label:{Image(systemName:"ellipsis.circle")}
                }
            }
            .confirmationDialog("重置5万元模拟账户？",isPresented:$resetConfirmation,titleVisibility:.visible) {
                Button("清空全部模拟记录",role:.destructive){ledger = PaperLedger(); persist()}
            }
            .sheet(isPresented:$picking) {
                PaperContractPicker(instruments:catalog){ contract in
                    pendingTicket = contract
                    picking = false
                }
            }
            .onChange(of:picking){_,active in
                if !active,let pendingTicket {
                    ticket = pendingTicket; self.pendingTicket = nil
                }
            }
            .sheet(item:ticketBinding) { item in
                PaperOrderTicket(contract:item.contract,ledger:ledger,preferredDirection:item.direction,preferredOffset:item.offset) { direction,offset,price,quantity in
                    try ledger.submit(contract:item.contract,direction:direction,offset:offset,price:price,quantity:quantity)
                    persist(); tab = .orders
                }
            }
            .alert("确认模拟成交",isPresented:Binding(get:{fillConfirmation != nil},set:{if !$0 {fillConfirmation = nil}}),presenting:fillConfirmation) { order in
                Button("按限价模拟成交"){ apply{try ledger.fill(order.id)};fillConfirmation = nil }
                Button("取消",role:.cancel){fillConfirmation = nil}
            } message:{ order in
                Text(order.contract.symbol+" · "+order.actionTitle+" "+String(order.quantity)+"手 @ "+order.price.formatted()+"。仅本地演练，不是交易所撮合。")
            }
            .alert("确认撤销模拟委托",isPresented:Binding(get:{cancelConfirmation != nil},set:{if !$0 {cancelConfirmation = nil}}),presenting:cancelConfirmation) { order in
                Button("撤单",role:.destructive){apply{try ledger.cancel(order.id)};cancelConfirmation = nil}
                Button("取消",role:.cancel){cancelConfirmation = nil}
            } message:{ order in Text(order.contract.symbol+" · "+order.actionTitle) }
            .onAppear {
                guard !restored else {return};restored = true
                if !saved.isEmpty {
                    if let decoded = try? JSONDecoder().decode(PaperLedger.self,from:saved) {ledger = decoded}
                    else {error = "旧模拟记录无法读取，未覆盖原记录。请手动重置。"}
                }
                if let initialContract {ticket = initialContract}
            }
        }.tint(MarketPalette.accent)
    }
    @State private var pendingTicket:PaperContract?
    @State private var preferredDirection:PaperDirection = .buy
    @State private var preferredOffset:PaperOffset = .open
    private struct TicketItem:Identifiable {
        let contract:PaperContract
        let direction:PaperDirection
        let offset:PaperOffset
        var id:String {contract.symbol}
    }
    private var ticketBinding:Binding<TicketItem?> {
        Binding(get:{ticket.map{TicketItem(contract:$0,direction:preferredDirection,offset:preferredOffset)}},
                set:{if $0 == nil {ticket = nil;preferredDirection = .buy;preferredOffset = .open}})
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(ledger) {saved = data;error = nil}
        else {error = "保存模拟记录失败"}
    }
    private func apply(_ action:() throws -> Void) {
        do {try action();persist()} catch {self.error = error.localizedDescription}
    }
    private func money(_ value:Double)->String {value.formatted(.number.precision(.fractionLength(2)))+" 元"}

    private var accountSection:some View {
        Group {
            Section("模拟资金") {
                LabeledContent("初始本金",value:money(PaperLedger.initialCapital))
                LabeledContent("账面资金（不含浮盈亏）",value:money(ledger.cash))
                LabeledContent("可用资金（估算）",value:money(ledger.available))
                LabeledContent("持仓占用（估算）",value:money(ledger.margin))
                LabeledContent("委托冻结（估算）",value:money(ledger.frozen))
                LabeledContent("累计平仓盈亏",value:money(ledger.realized))
                LabeledContent("模拟手续费",value:money(ledger.fees))
            }
            Section("模拟规则") {
                Text("固定保证金15%，每手每边5元，仅为演练假设。不计算实时浮盈亏、逐日结算、涨跌停、排队成交或交易所平今费率。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("模拟成交需手动确认。实盘交易入口锁定，未接入任何期货公司。").font(.caption)
            }
        }
    }
    private var positionsSection:some View {
        Section("模拟持仓") {
            if ledger.positions.isEmpty {Text("暂无持仓").foregroundStyle(.secondary)}
            ForEach(ledger.positions){pos in
                VStack(alignment:.leading,spacing:5) {
                    HStack {
                        Text(pos.contract.symbol).fontWeight(.semibold)
                        Spacer()
                        Text(pos.side.title).foregroundStyle(pos.side == .long ? MarketPalette.up : MarketPalette.down)
                    }
                    Text("\(pos.quantity)手 · 均价 \(pos.averagePrice.formatted()) · 可平 \(ledger.closable(symbol:pos.contract.symbol,side:pos.side))手").font(.caption)
                    Button("模拟平仓"){
                        preferredDirection = pos.side == .long ? .sell : .buy
                        preferredOffset = .close
                        ticket = pos.contract
                    }.buttonStyle(.borderless)
                }.padding(.vertical,3)
            }
        }
    }
    private var ordersSection:some View {
        Section("模拟委托") {
            if ledger.orders.isEmpty {Text("暂无委托").foregroundStyle(.secondary)}
            ForEach(ledger.orders.reversed()){order in
                VStack(alignment:.leading,spacing:6) {
                    HStack {Text(order.contract.symbol).fontWeight(.semibold);Spacer();Text(order.status.title).font(.caption).foregroundStyle(.secondary)}
                    Text("\(order.actionTitle) · \(order.quantity)手 · 限价 \(order.price.formatted())").font(.subheadline)
                    Text(order.created.formatted(date:.abbreviated,time:.standard)).font(.caption2).foregroundStyle(.secondary)
                    if order.status == .pending {
                        HStack {
                            Button("模拟成交"){fillConfirmation = order}.buttonStyle(.borderless)
                            Spacer()
                            Button("撤单",role:.destructive){cancelConfirmation = order}.buttonStyle(.borderless)
                        }
                    }
                }.padding(.vertical,4)
            }
        }
    }
    private var fillsSection:some View {
        Section("模拟成交") {
            if ledger.fills.isEmpty {Text("暂无成交").foregroundStyle(.secondary)}
            ForEach(ledger.fills.reversed()){fill in
                VStack(alignment:.leading,spacing:5){
                    HStack{Text(fill.symbol).fontWeight(.semibold);Spacer();Text(fill.action)}
                    Text("\(fill.quantity)手 @ \(fill.price.formatted()) · 手续费 \(money(fill.fee))").font(.caption)
                    Text("平仓盈亏 \(money(fill.realized)) · \(fill.time.formatted(date:.omitted,time:.standard))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct PaperOrderTicket:View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var input:String?
    let contract:PaperContract
    let ledger:PaperLedger
    let onSubmit:(PaperDirection,PaperOffset,Double,Int)throws->Void
    @State private var direction:PaperDirection
    @State private var offset:PaperOffset
    @State private var price:String
    @State private var quantity = 1
    @State private var confirming = false
    @State private var error:String?

    init(contract:PaperContract,ledger:PaperLedger,preferredDirection:PaperDirection,preferredOffset:PaperOffset,onSubmit:@escaping(PaperDirection,PaperOffset,Double,Int)throws->Void) {
        self.contract = contract;self.ledger = ledger;self.onSubmit = onSubmit
        _direction = State(initialValue:preferredDirection);_offset = State(initialValue:preferredOffset)
        _price = State(initialValue:contract.last.map{String($0)} ?? "")
    }
    private var numericPrice:Double? {Double(price.trimmingCharacters(in:.whitespacesAndNewlines))}
    private var side:PaperPositionSide {(offset == .open ? direction == .buy : direction == .sell) ? .long : .short}
    private var valid:Bool {
        guard let numericPrice else {return false}
        var copy = ledger
        return (try? copy.submit(contract:contract,direction:direction,offset:offset,price:numericPrice,quantity:quantity)) != nil
    }
    var body:some View {
        NavigationStack {
            Form {
                Section("模拟 · 限价委托") {
                    LabeledContent("合约",value:contract.symbol)
                    LabeledContent("最小变动价位",value:contract.tick.map{String($0)} ?? "未获取")
                    LabeledContent("合约乘数",value:contract.multiplier.map{String($0)} ?? "未获取")
                    Text("以下是进入页面时的行情快照，并非实时交易报价。").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        quoteButton("买一",contract.bid)
                        Spacer()
                        quoteButton("最新",contract.last)
                        Spacer()
                        quoteButton("卖一",contract.ask)
                    }
                }
                Section("委托参数") {
                    Picker("方向",selection:$direction){ForEach(PaperDirection.allCases,id:\.self){Text($0.title).tag($0)}}.pickerStyle(.segmented)
                    Picker("开平",selection:$offset){ForEach(PaperOffset.allCases,id:\.self){Text($0.title).tag($0)}}.pickerStyle(.segmented)
                    HStack{
                        Text("限价")
                        Spacer()
                        Button {adjust(-1)} label:{Image(systemName:"minus.circle")}.buttonStyle(.borderless)
                        TextField("价格",text:$price).keyboardType(.decimalPad).focused($input,equals:"price").multilineTextAlignment(.trailing).frame(width:92)
                        Button {adjust(1)} label:{Image(systemName:"plus.circle")}.buttonStyle(.borderless)
                    }
                    Stepper("手数：\(quantity)",value:$quantity,in:1...999)
                    if offset == .close {LabeledContent("可平手数",value:String(ledger.closable(symbol:contract.symbol,side:side)))}
                    if let p = numericPrice,let m = contract.multiplier,p.isFinite,p>0,m>0 {
                        LabeledContent("模拟保证金",value:(offset == .open ? p*m*Double(quantity)*PaperLedger.marginRate : 0).formatted(.number.precision(.fractionLength(2))))
                    }
                    LabeledContent("模拟手续费",value:(Double(quantity)*PaperLedger.feePerLot).formatted(.number.precision(.fractionLength(2))))
                }
                Section {
                    if !contract.hasMetadata {Text("缺少有效合约参数或不是具体月份期货，禁止提交。").foregroundStyle(.red).font(.caption)}
                    Button("提交模拟"+direction.title+offset.title){
                        hideKeyboard()
                        guard let numericPrice else {error = "请输入有效价格";return}
                        var copy = ledger
                        do {try copy.submit(contract:contract,direction:direction,offset:offset,price:numericPrice,quantity:quantity);confirming = true;error = nil}
                        catch {self.error = error.localizedDescription}
                    }.disabled(!contract.hasMetadata)
                    if let error {Text(error).font(.caption).foregroundStyle(.red)}
                    Text("不会发往交易所。提交后在委托页面手动确认模拟成交，或撤销。").font(.caption).foregroundStyle(.secondary)
                }
            }
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("模拟下单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar{
                ToolbarItem(placement:.cancellationAction){Button("取消"){hideKeyboard();dismiss()}}
                ToolbarItemGroup(placement:.keyboard){Spacer();Button("完成"){hideKeyboard()}}
            }
            .confirmationDialog("确认模拟委托",isPresented:$confirming,titleVisibility:.visible){
                Button("确认模拟委托"){
                    guard let numericPrice,valid else {error = "委托参数不再有效";return}
                    do{try onSubmit(direction,offset,numericPrice,quantity);dismiss()}catch{self.error = error.localizedDescription}
                }
                Button("取消",role:.cancel){}
            } message:{Text(contract.symbol+" · "+direction.title+offset.title+" · "+String(quantity)+"手 @ "+price+"。不是真实订单。")}
        }
    }
    private func hideKeyboard(){input = nil;IndicatorKeyboard.dismiss()}
    private func quoteButton(_ title:String,_ quote:Double?)->some View {
        Button{
            if let quote,quote.isFinite,quote>0 {price = String(quote);hideKeyboard()}
        }label:{
            VStack{Text(title).font(.caption);Text(quote.map{$0.formatted()} ?? "--").monospacedDigit()}
        }.buttonStyle(.borderless).disabled(quote == nil)
    }
    private func adjust(_ delta:Int){
        guard let tick = contract.tick,tick.isFinite,tick>0,let p = numericPrice,p.isFinite else{return}
        let new = ((p/tick).rounded()+Double(delta))*tick
        if new > 0 {price = String(new)}
    }
}

private struct PaperContractPicker:View {
    @Environment(\.dismiss) private var dismiss
    let instruments:[FuturesInstrument]
    let onPick:(PaperContract)->Void
    @State private var search = ""
    var body:some View{
        NavigationStack{
            List{
                ForEach(instruments.filter{search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search)}){item in
                    NavigationLink(item.name){PaperContractList(instrument:item,onPick:onPick)}
                }
            }
            .searchable(text:$search,prompt:"搜索品种")
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("选择交易合约")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar{ToolbarItem(placement:.cancellationAction){Button("取消"){dismiss()}}}
        }
    }
}
private struct PaperContractList:View {
    let instrument:FuturesInstrument
    let onPick:(PaperContract)->Void
    @State private var quotes:[MarketDataService.ContractQuote] = []
    @State private var loading = true
    @State private var error:String?
    var body:some View{
        List{
            if loading{ProgressView("读取挂牌合约")}
            if let error{Text(error).font(.caption);Button("重试"){Task{await load()}}}
            ForEach(quotes){q in
                let contract = PaperContract(symbol:q.code,name:instrument.name,tick:q.priceTick,multiplier:q.volumeMultiple,last:q.last,bid:q.bid,ask:q.ask)
                Button{onPick(contract)}label:{
                    HStack{Text(q.code);Spacer();Text(q.last.map{$0.formatted()} ?? "--").foregroundStyle(.secondary)}
                }.disabled(!contract.hasMetadata)
            }
        }.navigationTitle(instrument.name).task{await load()}
    }
    @MainActor private func load()async{
        loading = true;error = nil;defer{loading = false}
        do{quotes = try await MarketDataService.listedContracts(for:instrument.id);if quotes.isEmpty{error = "暂无挂牌合约"}}
        catch{self.error = error.localizedDescription}
    }
}
