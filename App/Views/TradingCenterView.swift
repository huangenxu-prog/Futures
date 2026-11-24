import SwiftUI
import Combine

/// Local simulation only. Real-trading access cannot be enabled by a toggle.
struct TradingCenterView:View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.futuresCatalog) private var catalog
    @State private var marks:[String:Double] = [:]
    @State private var markReceived:[String:Date] = [:]
    @State private var markClock = Date()
    var favoriteIDs:[String] = []
    var mainCodes:[String:String] = [:]
    @AppStorage("qihui.paper-ledger.v1") private var saved = Data()
    @State private var ledger = PaperLedger()
    @State private var tab:Tab = .positions
    @State private var pendingOnly = true
    @State private var storageFailed = false
    @State private var ticket:PaperContract?
    @State private var picking = false
    @State private var resetConfirmation = false
    @State private var error:String?
    @State private var fillConfirmation:PaperOrder?
    @State private var cancelConfirmation:PaperOrder?
    @State private var restored = false
    @State private var bankTransfer:BankTransferDirection?
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
                accountOverview
                HStack(spacing:6) {
                    tabButton(.positions)
                    tabButton(.orders)
                    tabButton(.fills)
                    tabButton(.account)
                }.padding(.horizontal,12).padding(.vertical,8)
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
                }.buttonStyle(.borderedProminent).padding(12).disabled(storageFailed)
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
                Button("清空全部模拟记录",role:.destructive){ledger = PaperLedger(); storageFailed = false; persist()}
            }
            .sheet(item:$bankTransfer) { direction in
                BankTransferView(initialDirection:direction)
            }
            .sheet(isPresented:$picking,onDismiss:{
                if let pendingTicket {
                    ticket = pendingTicket; self.pendingTicket = nil
                }
            }) {
                PaperContractPicker(instruments:catalog,favoriteIDs:favoriteIDs,mainCodes:mainCodes){ contract in
                    pendingTicket = contract
                    picking = false
                }
            }
            .sheet(item:ticketBinding) { item in
                PaperOrderTicket(contract:item.contract,ledger:ledger,preferredDirection:item.direction,preferredOffset:item.offset) { direction,offset,price,quantity in
                    guard !storageFailed else {throw PaperFailure("模拟记录读取失败")}
                    var current = try loadLedger()
                    try current.submit(contract:item.contract,direction:direction,offset:offset,price:price,quantity:quantity)
                    saved = try JSONEncoder().encode(current)
                    ledger = current
                    tab = .orders;pendingOnly = true
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
            .task(id:markTaskKey) {
                guard scenePhase == .active else {return}
                marks = [:];markReceived = [:]
                while !Task.isCancelled {
                    await refreshMarks()
                    do {try await Task.sleep(for:.seconds(10))} catch {return}
                }
            }
            .onReceive(NotificationCenter.default.publisher(for:.qihuiLiveQuotes)) { notification in
                guard scenePhase == .active,
                    let quotes = notification.object as? [String:MarketDataService.MainContract] else {return}
                let symbols = Set(ledger.positions.map{$0.contract.symbol})
                for q in quotes.values where symbols.contains(q.code) {
                    if let p = q.last,p.isFinite,p>0 {
                        marks[q.code] = p;markReceived[q.code] = Date()
                    }
                }
                markClock = Date()
            }
            .onAppear {
                guard !restored else {return};restored = true
                if !saved.isEmpty {
                    if let decoded = try? JSONDecoder().decode(PaperLedger.self,from:saved) {ledger = decoded}
                    else {storageFailed = true;error = "旧模拟记录无法读取，未覆盖原记录。请手动重置。"}
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
    private func loadLedger() throws -> PaperLedger {
        if saved.isEmpty { return PaperLedger() }
        return try JSONDecoder().decode(PaperLedger.self,from:saved)
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(ledger) {saved = data;error = nil}
        else {error = "保存模拟记录失败"}
    }
    private func apply(_ action:() throws -> Void) {
        do {try action();persist()} catch {self.error = error.localizedDescription}
    }
    private func money(_ value:Double)->String {value.formatted(.number.precision(.fractionLength(2)))+" 元"}

    private var markTaskKey:String {
        let symbols = Set(ledger.positions.map{$0.contract.symbol}).sorted().joined(separator:"|")
        return symbols+(scenePhase == .active ? "/active" : "/paused")
    }
    private var currentMarks:[String:Double] {
        marks.filter { symbol,_ in
            guard let received = markReceived[symbol] else {return false}
            return markClock.timeIntervalSince(received) <= 45
        }
    }
    @MainActor private func refreshMarks() async {
        let symbols = Set(ledger.positions.map{$0.contract.symbol})
        guard !symbols.isEmpty else {marks = [:];markReceived = [:];return}
        let products = Set(symbols.map{symbol in
            String(symbol.dropLast(symbol.reversed().prefix{$0.isNumber}.count))
        })
        // Only held products, and exact month match. Never use entry cost
        // or another month's main-contract quote for valuation.
        for product in products.sorted() {
            guard !Task.isCancelled else {return}
            let started = Date()
            do {
                let quotes = try await MarketDataService.listedContracts(for:product)
                try Task.checkCancellation()
                for q in quotes where symbols.contains(q.code) {
                    guard (markReceived[q.code] ?? .distantPast) <= started else {continue}
                    if let p = q.last,p.isFinite,p>0 {
                        marks[q.code] = p;markReceived[q.code] = Date()
                    } else {
                        marks.removeValue(forKey:q.code);markReceived.removeValue(forKey:q.code)
                    }
                }
            } catch is CancellationError {return} catch {}
            markClock = Date()
        }
    }
    private func signedMoney(_ value:Double?) -> String {
        guard let value else {return "--"}
        return (value > 0 ? "+" : "")+value.formatted(.number.precision(.fractionLength(2)))
    }
    private var accountOverview:some View {
        VStack(alignment:.leading,spacing:10) {
            Text("账户权益（估算）").font(.caption).foregroundStyle(MarketPalette.muted)
            Text(storageFailed ? "--" : ledger.equity(prices:currentMarks).map{money($0)} ?? "--")
                .font(.system(size:28,weight:.semibold,design:.rounded)).monospacedDigit()
            HStack(alignment:.top,spacing:8) {
                overviewMetric("可用资金（账面）",storageFailed ? "--" : signedMoney(ledger.available),MarketPalette.ink)
                overviewMetric("持仓盈亏",storageFailed ? "--" : signedMoney(ledger.unrealized(prices:currentMarks)),MarketPalette.movement(ledger.unrealized(prices:currentMarks)))
                overviewMetric("保证金（估算）",storageFailed ? "--" : signedMoney(ledger.margin),MarketPalette.ink)
            }
            HStack(spacing:12) {
                Button("入金"){bankTransfer = .deposit}
                Button("出金"){bankTransfer = .withdraw}
                Spacer()
                if !ledger.positions.isEmpty {
                    Text(ledger.unrealized(prices:currentMarks) == nil ? "部分报价缺失" : "最近行情估值")
                        .font(.caption2).foregroundStyle(MarketPalette.muted)
                }
            }.font(.subheadline.weight(.medium)).buttonStyle(.borderless)
        }.padding(14).frame(maxWidth:.infinity,alignment:.leading)
            .background(MarketPalette.surface,in:RoundedRectangle(cornerRadius:12))
            .padding(.horizontal,12).padding(.top,8)
    }
    private func overviewMetric(_ label:String,_ value:String,_ tint:Color)->some View {
        VStack(alignment:.leading,spacing:5) {
            Text(label).font(.system(size:10)).foregroundStyle(MarketPalette.muted)
            Text(value).font(.system(size:15,weight:.semibold,design:.rounded)).monospacedDigit()
                .foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.65)
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    private func tabButton(_ value:Tab)->some View {
        Button{tab = value}label:{
            Text(value == .account ? "资金明细" : value.rawValue)
                .font(.subheadline.weight(tab == value ? .semibold : .regular))
                .foregroundStyle(tab == value ? MarketPalette.accent : MarketPalette.muted)
                .frame(maxWidth:.infinity).padding(.vertical,7)
                .background(tab == value ? MarketPalette.raised : Color.clear,in:RoundedRectangle(cornerRadius:7))
        }.buttonStyle(.plain)
    }
    private var accountSection:some View {
        Group {
            Section("银期转账") {
                HStack(spacing:12) {
                    Button {bankTransfer = .deposit} label:{
                        Label("入金",systemImage:"arrow.down.to.line")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth:.infinity).padding(.vertical,12)
                            .background(MarketPalette.raised,in:RoundedRectangle(cornerRadius:9))
                    }.buttonStyle(.plain).foregroundStyle(MarketPalette.accent)
                    Button {bankTransfer = .withdraw} label:{
                        Label("出金",systemImage:"arrow.up.to.line")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth:.infinity).padding(.vertical,12)
                            .background(MarketPalette.raised,in:RoundedRectangle(cornerRadius:9))
                    }.buttonStyle(.plain).foregroundStyle(MarketPalette.accent)
                }
                Text("实盘未连接").font(.caption).foregroundStyle(MarketPalette.muted)
            }
            Section("模拟资金") {
                LabeledContent("初始本金",value:money(PaperLedger.initialCapital))
                LabeledContent("账面资金（不含浮盈亏）",value:money(ledger.cash))
                LabeledContent("持仓盈亏",value:signedMoney(ledger.unrealized(prices:currentMarks)))
                LabeledContent("账户权益（估算）",value:ledger.equity(prices:currentMarks).map{money($0)} ?? "--")
                LabeledContent("可用资金（估算）",value:money(ledger.available))
                LabeledContent("持仓占用（估算）",value:money(ledger.margin))
                LabeledContent("委托冻结（估算）",value:money(ledger.frozen))
                LabeledContent("累计平仓盈亏",value:money(ledger.realized))
                LabeledContent("模拟手续费",value:money(ledger.fees))
            }
            Section {
                Text("模拟参数：保证金15%，每手每边5元。权益按最近行情估值，可用资金仍按账面资金计算；未做逐日结算。成交需手动确认。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var positionsSection:some View {
        Section("模拟持仓") {
            if ledger.positions.isEmpty {Text("暂无持仓").foregroundStyle(.secondary)}
            ForEach(ledger.positions){pos in
                positionRow(pos).padding(.vertical,3)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        preferredDirection = pos.side == .long ? .sell : .buy
                        preferredOffset = .close
                        openClose(pos)
                    }
                    .accessibilityAction(named:"平仓") {
                        preferredDirection = pos.side == .long ? .sell : .buy
                        preferredOffset = .close
                        openClose(pos)
                    }
            }
        }
    }
    private func positionRow(_ pos:PaperPosition)->some View {
        let price = currentMarks[pos.contract.symbol]
        let pnl = pos.unrealized(at:price)
        return VStack(alignment:.leading,spacing:7) {
            HStack {
                Text(pos.contract.name).fontWeight(.semibold)
                Text(pos.contract.symbol).font(.caption).foregroundStyle(MarketPalette.muted)
                Spacer(minLength:4)
                Text(signedMoney(pnl)).font(.headline.monospacedDigit())
                    .foregroundStyle(MarketPalette.movement(pnl))
            }
            HStack {
                Text("\(pos.side.title) \(pos.quantity)手").foregroundStyle(pos.side == .long ? MarketPalette.up : MarketPalette.down)
                Text("成本 \(pos.averagePrice.formatted())")
                Spacer(minLength:4)
                Text("最新 \(price.map{$0.formatted()} ?? "--")")
            }.font(.caption).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
            HStack {
                Text("可平 \(ledger.closable(symbol:pos.contract.symbol,side:pos.side))手").font(.caption).foregroundStyle(MarketPalette.muted)
                Spacer()
                Text(pos.side == .long ? "平多" : "平空").font(.caption.weight(.semibold)).foregroundStyle(MarketPalette.accent)
                Image(systemName:"chevron.right").font(.caption2).foregroundStyle(MarketPalette.muted)
            }
        }
    }
    private func openClose(_ pos:PaperPosition) {
        guard !storageFailed else {return}
        // Never reuse an old entry quote as a current closing quote.
        let c = pos.contract
        ticket = PaperContract(symbol:c.symbol,name:c.name,tick:c.tick,multiplier:c.multiplier,last:nil,bid:nil,ask:nil)
    }
    private var displayedOrders:[PaperOrder] {
        let all = pendingOnly ? ledger.orders.filter{$0.status == .pending} : ledger.orders
        return Array(all.reversed())
    }
    private var ordersSection:some View {
        Section("模拟委托") {
            Picker("委托筛选",selection:$pendingOnly) {
                Text("未完成").tag(true)
                Text("全部").tag(false)
            }.pickerStyle(.segmented)
            if displayedOrders.isEmpty {Text(pendingOnly ? "暂无未完成委托" : "暂无委托").foregroundStyle(.secondary)}
            ForEach(displayedOrders){order in
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
                    .swipeActions(edge:.trailing,allowsFullSwipe:false) {
                        if order.status == .pending {
                            Button("撤单",role:.destructive){cancelConfirmation = order}
                        }
                    }
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
    @State private var refreshedQuote:PaperContract?
    @State private var refreshing = false
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
    private var closeOnly:Bool {preferredOffset == .close}
    private var closeAvailable:Int {preferredDirection == .sell ? longAvailable : shortAvailable}
    private var displayQuote:PaperContract {refreshedQuote ?? contract}
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
        .task {
            if closeOnly { await refreshCloseQuote() }
        }
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
                Text(closeOnly ? (preferredDirection == .sell ? "平多" : "平空") : contract.name).font(.headline)
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
            quoteButton("买一",displayQuote.bid,MarketPalette.up)
            quoteButton("最新",displayQuote.last,MarketPalette.ink)
            quoteButton("卖一",displayQuote.ask,MarketPalette.down)
        }
        .overlay(alignment:.bottomTrailing) {
            Text(refreshing ? "更新中" : "快照").font(.system(size:9)).foregroundStyle(MarketPalette.muted).padding(3)
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
            if closeOnly {
                Button("全平") {quantity = String(min(999,closeAvailable));hideKeyboard()}
                    .font(.caption.weight(.semibold)).disabled(closeAvailable == 0)
            }
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
            if closeOnly {
                actionButton(preferredDirection,.close,preferredDirection == .sell ? "平多" : "平空",MarketPalette.accent)
            } else {
                actionButton(.buy,.open,"开多",MarketPalette.up)
                actionButton(.sell,.open,"开空",MarketPalette.down)
                actionButton(.sell,.close,"平多",MarketPalette.down)
                actionButton(.buy,.close,"平空",MarketPalette.up)
            }
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
    @MainActor private func refreshCloseQuote() async {
        let product = contract.symbol.dropLast(contract.symbol.reversed().prefix{$0.isNumber}.count)
        guard !product.isEmpty else {return}
        refreshing = true
        defer {refreshing = false}
        do {
            let quotes = try await MarketDataService.listedContracts(for:String(product))
            try Task.checkCancellation()
            guard let q = quotes.first(where:{$0.code == contract.symbol}) else {throw PaperFailure("当前合约报价未获取")}
            refreshedQuote = PaperContract(symbol:q.code,name:contract.name,tick:q.priceTick,multiplier:q.volumeMultiple,last:q.last,bid:q.bid,ask:q.ask)
            if price.isEmpty,let p = (preferredDirection == .sell ? q.bid : q.ask) ?? q.last,p.isFinite,p>0 {price = String(p)}
        } catch is CancellationError {} catch {
            self.error = "未获取当前报价，请手动输入限价"
        }
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
    let favoriteIDs:[String]
    let mainCodes:[String:String]
    let onPick:(PaperContract)->Void
    @State private var search = ""
    private var matching:[FuturesInstrument] {
        let filtered = instruments.filter{search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search)}
        return filtered.sorted{ a,b in
            let ai = favoriteIDs.firstIndex(of:a.id) ?? Int.max
            let bi = favoriteIDs.firstIndex(of:b.id) ?? Int.max
            return ai == bi ? a.name.localizedCompare(b.name) == .orderedAscending : ai < bi
        }
    }
    var body:some View{
        NavigationStack{
            List{
                ForEach(matching){item in
                    NavigationLink {
                        PaperContractList(instrument:item,mainCode:mainCodes[item.id],onPick:onPick)
                    } label:{
                        HStack {
                            Text(item.name)
                            Spacer()
                            if let main = mainCodes[item.id] {Text(main).font(.caption).foregroundStyle(MarketPalette.muted)}
                        }
                    }
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
    let mainCode:String?
    let onPick:(PaperContract)->Void
    @State private var quotes:[MarketDataService.ContractQuote] = []
    @State private var loading = true
    @State private var error:String?
    var body:some View{
        List{
            if loading{ProgressView("读取挂牌合约")}
            if let error{Text(error).font(.caption);Button("重试"){Task{await load()}}}
            ForEach(quotes.sorted { a,b in
                if a.code == mainCode {return b.code != mainCode}
                if b.code == mainCode {return false}
                return a.code < b.code
            }){q in
                let contract = PaperContract(symbol:q.code,name:instrument.name,tick:q.priceTick,multiplier:q.volumeMultiple,last:q.last,bid:q.bid,ask:q.ask)
                Button{onPick(contract)}label:{
                    HStack{
                        Text(q.code)
                        if q.code == mainCode {Text("主力").font(.caption).foregroundStyle(MarketPalette.accent)}
                        Spacer()
                        Text(q.last.map{$0.formatted()} ?? "--").foregroundStyle(.secondary)
                    }
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

// Entry and read-only layout only. No bank credentials, API calls, fake
// transfers, or changes to the paper ledger.
private enum BankTransferDirection:String,CaseIterable,Identifiable {
    case deposit = "入金"
    case withdraw = "出金"
    var id:String {rawValue}
    var route:String {self == .deposit ? "银行 → 期货" : "期货 → 银行"}
}
private struct BankTransferView:View {
    @Environment(\.dismiss) private var dismiss
    @State private var direction:BankTransferDirection
    init(initialDirection:BankTransferDirection) {
        _direction = State(initialValue:initialDirection)
    }
    var body:some View {
        NavigationStack {
            Form {
                Section {
                    Picker("转账方向",selection:$direction) {
                        ForEach(BankTransferDirection.allCases){item in
                            Text(item.rawValue).tag(item)
                        }
                    }.pickerStyle(.segmented)
                    LabeledContent("转账方向",value:direction.route)
                    LabeledContent("签约银行",value:"未连接")
                    LabeledContent("银行余额",value:"--")
                    LabeledContent("可取资金",value:"--")
                    LabeledContent("金额（元）",value:"--")
                    Button(direction == .deposit ? "确认入金" : "确认出金") {}
                        .disabled(true)
                    Text("银期转账尚未获得授权。连接实盘账户后才可查询银行信息或发起转账。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("转账记录") {
                    Text("未连接，无法查询").foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(MarketPalette.background)
            .navigationTitle("银期转账")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {ToolbarItem(placement:.cancellationAction){Button("关闭"){dismiss()}}}
        }.tint(MarketPalette.accent)
    }
}
