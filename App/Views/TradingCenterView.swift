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
                    Text("模拟账户").fontWeight(.semibold)
                    Spacer()
                    Text("实盘未连接").foregroundStyle(.secondary)
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
                    Text("下单")
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
            .sheet(isPresented:$picking,onDismiss:{
                if let pendingTicket {
                    ticket = pendingTicket; self.pendingTicket = nil
                }
            }) {
                PaperContractPicker(instruments:catalog){ contract in
                    pendingTicket = contract
                    picking = false
                }
            }
            .sheet(item:ticketBinding) { item in
                PaperOrderTicket(contract:item.contract,ledger:ledger,preferredDirection:item.direction,preferredOffset:item.offset) { direction,offset,price,quantity in
                    try ledger.submit(contract:item.contract,direction:direction,offset:offset,price:price,quantity:quantity)
                    persist(); tab = .orders
                }
                .presentationDetents([.height(360),.large])
                .presentationDragIndicator(.visible)
            }
            .alert("确认模拟成交",isPresented:Binding(get:{fillConfirmation != nil},set:{if !$0 {fillConfirmation = nil}}),presenting:fillConfirmation) { order in
                Button("按限价模拟成交"){ apply{try ledger.fill(order.id)};fillConfirmation = nil }
                Button("取消",role:.cancel){fillConfirmation = nil}
            } message:{ order in
                Text("\(order.contract.symbol) · \(order.actionTitle) \(order.quantity)手 @ \(order.price.formatted())。仅本地演练，不是交易所撮合。")
            }
            .alert("确认撤销模拟委托",isPresented:Binding(get:{cancelConfirmation != nil},set:{if !$0 {cancelConfirmation = nil}}),presenting:cancelConfirmation) { order in
                Button("撤单",role:.destructive){apply{try ledger.cancel(order.id)};cancelConfirmation = nil}
                Button("取消",role:.cancel){cancelConfirmation = nil}
            } message:{ order in Text("\(order.contract.symbol) · \(order.actionTitle)") }
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
            Section {
                Text("模拟参数：保证金15%，每手每边5元。未计浮盈亏、逐日结算；成交需手动确认。")
                    .font(.caption).foregroundStyle(.secondary)
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
                }.padding(.vertical,3)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        preferredDirection = pos.side == .long ? .sell : .buy
                        preferredOffset = .close
                        ticket = pos.contract
                    }
                    .accessibilityAction(named:"平仓") {
                        preferredDirection = pos.side == .long ? .sell : .buy
                        preferredOffset = .close
                        ticket = pos.contract
                    }
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
                    HStack{Text(fill.symbol).fontWeight(.semibold);Spacer();Text(fill.displayAction)}
                    Text("\(fill.quantity)手 @ \(fill.price.formatted()) · 手续费 \(money(fill.fee))").font(.caption)
                    Text("平仓盈亏 \(money(fill.realized)) · \(fill.time.formatted(date:.omitted,time:.standard))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct QuickTradeSheet:View {
    let contract:PaperContract
    @AppStorage("qihui.paper-ledger.v1") private var saved = Data()
    @Environment(\.dismiss) private var dismiss
    private var ledger:PaperLedger? {
        saved.isEmpty ? PaperLedger() : try? JSONDecoder().decode(PaperLedger.self,from:saved)
    }
    var body:some View {
        if let ledger {
            PaperOrderTicket(contract:contract,ledger:ledger,preferredDirection:.buy,preferredOffset:.open) { direction,offset,price,quantity in
                guard var current = self.ledger else {throw PaperFailure("模拟记录读取失败")}
                try current.submit(contract:contract,direction:direction,offset:offset,price:price,quantity:quantity)
                saved = try JSONEncoder().encode(current)
            }
        } else {
            VStack(spacing:12) {
                Text("模拟账户记录读取失败")
                Button("关闭"){dismiss()}
            }.padding()
        }
    }
}

/// The same compact order ticket is used from the chart and account center.
/// Only its submit closure changes when an authorized broker backend is added.
private struct PaperOrderTicket:View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var input:String?
    let contract:PaperContract
    let ledger:PaperLedger
    let onSubmit:(PaperDirection,PaperOffset,Double,Int)throws->Void
    @State private var price:String
    @State private var quantity:String = "1"
    @State private var pending:TradeIntent?
    @State private var error:String?
    private let preferredOffset:PaperOffset
    private let preferredDirection:PaperDirection
    private struct TradeIntent:Identifiable {
        let direction:PaperDirection
        let offset:PaperOffset
        let price:Double
        let quantity:Int
        var id:String { direction.rawValue+offset.rawValue }
        var title:String { PaperOrder.actionTitle(direction:direction,offset:offset) }
    }

    init(contract:PaperContract,ledger:PaperLedger,preferredDirection:PaperDirection,preferredOffset:PaperOffset,onSubmit:@escaping(PaperDirection,PaperOffset,Double,Int)throws->Void) {
        self.contract = contract;self.ledger = ledger;self.onSubmit = onSubmit
        self.preferredOffset = preferredOffset;self.preferredDirection = preferredDirection
        _price = State(initialValue:contract.last.flatMap{$0.isFinite && $0 > 0 ? String($0) : nil} ?? "")
    }
    private var numericPrice:Double? {Double(price.trimmingCharacters(in:.whitespacesAndNewlines))}
    private var numericQuantity:Int? {Int(quantity.trimmingCharacters(in:.whitespacesAndNewlines))}
    private var longAvailable:Int {ledger.closable(symbol:contract.symbol,side:.long)}
    private var shortAvailable:Int {ledger.closable(symbol:contract.symbol,side:.short)}
    var body:some View {
        ScrollView {
            VStack(spacing:10) {
                header
                quotes
                priceRow
                quantityRow
                HStack {
                    Text("可用 \(ledger.available.formatted(.number.precision(.fractionLength(0))))")
                    Spacer()
                    Text("可平 多 \(longAvailable) / 空 \(shortAvailable)")
                }.font(.caption).monospacedDigit().foregroundStyle(MarketPalette.muted)
                actionRow
                if !contract.hasMetadata {
                    Text("合约参数未就绪，禁止委托").foregroundStyle(.red).font(.caption)
                }
                if let error {Text(error).font(.caption).foregroundStyle(.red)}
            }.padding(.horizontal,16).padding(.top,18).padding(.bottom,12)
        }
        .scrollDismissesKeyboard(.immediately)
        .background(MarketPalette.surface)
        .safeAreaInset(edge:.bottom) {
            if input != nil {
                HStack {Spacer();Button("完成"){hideKeyboard()}.fontWeight(.semibold)}
                    .padding(.horizontal,16).padding(.vertical,8).background(MarketPalette.raised)
            }
        }
        .alert("确认模拟委托",isPresented:Binding(get:{pending != nil},set:{if !$0 {pending = nil}}),presenting:pending) { intent in
            Button("确认 \(intent.title)") {
                do {try onSubmit(intent.direction,intent.offset,intent.price,intent.quantity);pending = nil;dismiss()}
                catch {self.error = error.localizedDescription;pending = nil}
            }
            Button("取消",role:.cancel){pending = nil}
        } message:{intent in
            Text("\(contract.symbol) · \(intent.title) · \(intent.quantity)手 @ \(intent.price.formatted())")
        }
        .tint(MarketPalette.accent)
    }
    private var header:some View {
        HStack {
            VStack(alignment:.leading,spacing:3) {
                Text(contract.name).font(.headline)
                Text(contract.symbol).font(.caption).foregroundStyle(MarketPalette.muted)
            }
            Spacer()
            Text("模拟").font(.caption.weight(.semibold))
                .padding(.horizontal,8).padding(.vertical,4)
                .background(MarketPalette.raised,in:Capsule())
            Button {hideKeyboard();dismiss()} label:{
                Image(systemName:"xmark.circle.fill").font(.title2).foregroundStyle(MarketPalette.muted)
            }.buttonStyle(.plain)
        }
    }
    private var quotes:some View {
        HStack(spacing:6) {
            quoteButton("买一",contract.bid,MarketPalette.up)
            quoteButton("最新",contract.last,MarketPalette.ink)
            quoteButton("卖一",contract.ask,MarketPalette.down)
        }
        .overlay(alignment:.bottomTrailing) {
            Text("快照").font(.system(size:9)).foregroundStyle(MarketPalette.muted).padding(3)
        }
    }
    private var priceRow:some View {
        HStack(spacing:10) {
            Text("限价").font(.subheadline.weight(.medium))
            Spacer()
            Button {adjust(-1)} label:{Image(systemName:"minus.circle").font(.title3)}.buttonStyle(.plain)
            TextField("价格",text:$price).keyboardType(.decimalPad).focused($input,equals:"price")
                .multilineTextAlignment(.center).monospacedDigit().frame(width:95,height:36)
                .background(MarketPalette.raised,in:RoundedRectangle(cornerRadius:7))
            Button {adjust(1)} label:{Image(systemName:"plus.circle").font(.title3)}.buttonStyle(.plain)
        }
    }
    private var quantityRow:some View {
        HStack(spacing:10) {
            Text("手数").font(.subheadline.weight(.medium))
            Spacer()
            Button {changeQuantity(-1)} label:{Image(systemName:"minus.circle").font(.title3)}.buttonStyle(.plain)
            TextField("1",text:$quantity).keyboardType(.numberPad).focused($input,equals:"quantity")
                .multilineTextAlignment(.center).monospacedDigit().frame(width:95,height:36)
                .background(MarketPalette.raised,in:RoundedRectangle(cornerRadius:7))
            Button {changeQuantity(1)} label:{Image(systemName:"plus.circle").font(.title3)}.buttonStyle(.plain)
        }
    }
    private var actionRow:some View {
        HStack(spacing:7) {
            actionButton(.buy,.open,"开多",MarketPalette.up)
            actionButton(.sell,.open,"开空",MarketPalette.down)
            actionButton(.sell,.close,"平多",MarketPalette.down)
            actionButton(.buy,.close,"平空",MarketPalette.up)
        }
    }
    private func actionButton(_ direction:PaperDirection,_ offset:PaperOffset,_ title:String,_ tint:Color)->some View {
        let eligible = contract.hasMetadata && (offset == .open || (direction == .buy ? shortAvailable : longAvailable)>0)
        let emphasized = preferredOffset == offset && preferredDirection == direction
        return Button {prepare(direction,offset)} label:{
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                .frame(maxWidth:.infinity).frame(height:42)
                .background(tint,in:RoundedRectangle(cornerRadius:7))
                .overlay(RoundedRectangle(cornerRadius:7).strokeBorder(.white.opacity(emphasized ? 0.5 : 0),lineWidth:1))
        }.buttonStyle(.plain).disabled(!eligible).opacity(eligible ? 1 : 0.35)
    }
    private func prepare(_ direction:PaperDirection,_ offset:PaperOffset){
        hideKeyboard()
        guard let p = numericPrice,let q = numericQuantity else {error = "价格或手数无效";return}
        var copy = ledger
        do {
            try copy.submit(contract:contract,direction:direction,offset:offset,price:p,quantity:q)
            error = nil;pending = TradeIntent(direction:direction,offset:offset,price:p,quantity:q)
        } catch {self.error = error.localizedDescription}
    }
    private func hideKeyboard(){input = nil;IndicatorKeyboard.dismiss()}
    private func quoteButton(_ title:String,_ quote:Double?,_ tint:Color)->some View {
        Button{
            if let quote,quote.isFinite,quote>0 {price = String(quote);hideKeyboard()}
        }label:{
            VStack(spacing:4){
                Text(title).font(.caption).foregroundStyle(MarketPalette.muted)
                Text(quote.map{$0.formatted()} ?? "--").font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(tint)
            }.frame(maxWidth:.infinity).padding(.vertical,7).background(MarketPalette.raised,in:RoundedRectangle(cornerRadius:7))
        }.buttonStyle(.plain).disabled(quote.map{!$0.isFinite || $0<=0} ?? true)
    }
    private func changeQuantity(_ delta:Int){
        let old = min(999,max(1,numericQuantity ?? 1))
        quantity = String(min(999,max(1,old+delta)))
    }
    private func adjust(_ delta:Int){
        guard let tick = contract.tick,tick.isFinite,tick>0,let p = numericPrice,p.isFinite else{return}
        let new = ((p/tick).rounded()+Double(delta))*tick
        if new.isFinite && new > 0 {price = String(new)}
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
