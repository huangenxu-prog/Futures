
import SwiftUI
import Foundation

private struct CloudSnapshot: Decodable {
    struct Account: Decodable {
        let balance: Double?
        let available: Double?
        let margin: Double?
        let float_profit: Double?
        let close_profit: Double?
    }
    struct Position: Decodable, Identifiable {
        let symbol: String
        let long: Int
        let short: Int
        let float_profit: Double?
        let open_price_long, open_price_short, float_profit_long, float_profit_short: Double?
        let frozen_long, frozen_short: Int?
        var id: String { symbol }
    }
    let account: Account
    struct Order: Decodable, Identifiable {
        let id: String
        let symbol: String
        let direction: String
        let offset: String
        let price: Double?
        let quantity: Int
        let remaining: Int
        let status: String
        let message: String
    }
    struct Fill: Decodable, Identifiable {
        let id: String
        let symbol: String
        let direction: String
        let offset: String
        let price: Double?
        let quantity: Int
        let time_ns: Int64
    }
    let positions: [Position]
    let orders: [Order]?
    let fills: [Fill]?
    let simulation_orders: Bool?
}
private struct CloudReply: Decodable {
    let token: String?
    let snapshot: CloudSnapshot?
}
private enum CloudTradeError: LocalizedError {
    case invalidURL, rejected, unavailable, expired
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "请输入有效的 HTTPS 交易网关地址"
        case .rejected: return "登录或授权失败，请检查快期账户及网关访问密钥"
        case .unavailable: return "交易网关或快期服务暂不可用"
        case .expired: return "会话已失效，请退出后重新登录"
        }
    }
}

@MainActor
private final class CloudTradeSession: ObservableObject {
    static let shared = CloudTradeSession()
    @Published private(set) var snapshot: CloudSnapshot?
    @Published private(set) var signedIn = false
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    private var token: String?
    private var accessKey = ""
    private var endpoint: URL?
    private var generation = UUID()
    @Published private(set) var pendingOrder: String?
    @Published private(set) var actionMessage: String?
    private var mutating = false
    var canTrade: Bool { signedIn && snapshot?.simulation_orders == true && !busy && !mutating && pendingOrder == nil }
    func submit(symbol: String, direction: String, offset: String, price: String, quantity: String) async {
        guard canTrade, let url = endpoint, let token else { return }
        mutating = true; busy = true
        defer { mutating = false; busy = false }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        pendingOrder = id
        actionMessage = "正在提交模拟委托"
        do {
            _ = try await request(base: url, action: "order", key: accessKey, token: token,
                                  body: ["id": id, "symbol": symbol, "direction": direction, "offset": offset, "price": price, "quantity": quantity])
            actionMessage = "指令已交给SDK，等待委托回报"
        } catch {
            actionMessage = "提交结果未确认，请查看委托列表，勿重复下单。编号：" + id
        }
        await refresh()
    }
    func cancel(_ id: String) async {
        guard signedIn, snapshot?.simulation_orders == true, !busy, !mutating, let url = endpoint, let token else { return }
        mutating = true; busy = true
        defer { mutating = false; busy = false }
        do {
            _ = try await request(base: url, action: "cancel", key: accessKey, token: token, body: ["id": id])
            actionMessage = "撤单指令已交给SDK，等待回报"
        } catch {
            actionMessage = "撤单结果未确认，请核对委托状态"
        }
        await refresh()
    }
    func acknowledgeUncertainOrder() {
        pendingOrder = nil
        actionMessage = "已手动解除提交锁定，请先核对快期委托记录"
    }
    private let http: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 80
        config.timeoutIntervalForResource = 85
        return URLSession(configuration: config, delegate: TradeRedirectGuard(), delegateQueue: nil)
    }()
    func login(address: String, key: String, username: String, password: String) async {
        guard !busy, !signedIn else { return }
        guard let parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "https", parts.host != nil, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, let url = parts.url else {
            error = CloudTradeError.invalidURL.localizedDescription; return
        }
        busy = true; error = nil
        defer { busy = false }
        do {
            let reply = try await request(base: url, action: "login", key: key, token: nil,
                                          body: ["username": username, "password": password])
            guard let session = reply.token, !session.isEmpty, let data = reply.snapshot else { throw CloudTradeError.unavailable }
            token = session; accessKey = key; endpoint = url
            generation = UUID()
            pendingOrder = nil; actionMessage = nil
            snapshot = data; signedIn = true
        } catch {
            self.error = error.localizedDescription
        }
    }
    func refresh() async {
        guard let url = endpoint, let token, signedIn else { return }
        let current = generation
        do {
            let reply = try await request(base: url, action: "snapshot", key: accessKey, token: token, body: nil)
            guard current == generation, !Task.isCancelled else { return }
            guard let data = reply.snapshot else { throw CloudTradeError.unavailable }
            snapshot = data; error = nil
            if let pendingOrder, data.orders?.contains(where: { $0.id == pendingOrder }) == true {
                self.pendingOrder = nil
                actionMessage = "已收到委托记录"
            }
        } catch {
            guard current == generation, !Task.isCancelled else { return }
            snapshot = nil
            self.error = error.localizedDescription
        }
    }
    func logout() async {
        guard !busy else { return }
        busy = true
        let url = endpoint, session = token, key = accessKey
        generation = UUID(); snapshot = nil; signedIn = false
        token = nil; endpoint = nil; accessKey = ""; error = nil
        defer { busy = false }
        if let url, let session {
            _ = try? await request(base: url, action: "logout", key: key, token: session, body: [:])
        }
    }
    private func request(base: URL, action: String, key: String, token: String?, body: [String:String]?) async throws -> CloudReply {
        var req = URLRequest(url: base.appendingPathComponent("v1/trade").appendingPathComponent(action))
        req.httpMethod = body == nil ? "GET" : "POST"
        req.setValue(key, forHTTPHeaderField: "X-Qihui-Access")
        if let token { req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await http.data(for: req)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw CloudTradeError.unavailable }
        switch status {
        case 200: return try JSONDecoder().decode(CloudReply.self, from: data)
        case 401,403: throw token == nil ? CloudTradeError.rejected : CloudTradeError.expired
        default: throw CloudTradeError.unavailable
        }
    }
}
private final class TradeRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct TradingCenterView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session = CloudTradeSession.shared
    @AppStorage("qihui.trade.endpoint.v1") private var address = "https://8.153.96.190"
    @State private var key = ""
    @State private var username = ""
    @State private var password = ""
    @State private var real = false
    @State private var local = false
    @State private var unlock = false
    @State private var cancelID: String?
    @Environment(\.futuresCatalog) private var catalog
    @State private var selected: PaperContract?
    @State private var selecting = false
    @State private var selectionRequest = UUID()
    @State private var selectedPrice = ""
    @State private var selectedQuantity = 1
    @State private var pendingAction: String?
    @State private var closeToday = false
    @State private var tab = "持仓"
    @State private var quoteStamp: Date?
    @State private var quoteError = false
    @State private var showAccount = false
    @State private var openedInitial = false
    var favoriteIDs: [String] = []
    var mainCodes: [String:String] = [:]
    var initialContract: PaperContract? = nil

    var body: some View {
        NavigationStack {
            List {
                if session.signedIn {
                    accountHeader
                    orderPanel
                    recordsPanel
                    if let message = session.actionMessage { Section { Text(message).font(.caption) } }
                    if session.pendingOrder != nil {
                        Section { Button("已核对官方委托，解除锁定") { unlock = true }.disabled(session.busy) }
                    }
                    if session.snapshot?.simulation_orders != true {
                        Section { Text("暂不可提交委托，请确认交易网关连接").font(.caption).foregroundStyle(.secondary) }
                    }
                } else {
                    Section {
                        Picker("账户类型", selection: $real) {
                            Text("模拟交易").tag(false)
                            Text("实盘交易").tag(true)
                        }.pickerStyle(.segmented)
                    }
                    if real {
                        Section("期货账户") {
                            LabeledContent("期货公司", value: "银河期货")
                            Text("实盘登录暂未开放。先完成快期云端模拟及交易安全验收。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Section("快期账户") {
                            TextField("手机号 / 用户名", text: $username)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            SecureField("快期账户密码", text: $password)
                        }
                        Section("交易网关") {
                            TextField("HTTPS 网关地址", text: $address)
                                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            SecureField("网关访问密钥", text: $key)
                            Text("首次部署需配置独立交易服务与可信 HTTPS。密码和访问密钥不写入本地存储。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Section {
                            Button {
                                let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
                                let secret = password
                                password = ""
                                let access = key
                                key = ""
                                Task { await session.login(address: address, key: access, username: user, password: secret) }
                            } label: {
                                HStack {
                                    Spacer()
                                    if session.busy { ProgressView() }
                                    Text("登录模拟账户").fontWeight(.semibold)
                                    Spacer()
                                }
                            }.disabled(session.busy || username.isEmpty || password.isEmpty || key.isEmpty)
                        }
                    }
                    Section("独立本地模拟") {
                        Button("进入本地演练账户") { local = true }.disabled(session.busy)
                        Text("本地演练不与快期同步，保留原有模拟账本。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let message = session.error {
                    Section { Text(message).font(.caption).foregroundStyle(.red) }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(MarketPalette.background)
            .navigationTitle("交易")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .sheet(isPresented: $selecting) {
                PaperContractPicker(instruments: catalog, favoriteIDs: favoriteIDs, mainCodes: mainCodes) { c in
                    choose(c); selecting = false
                }
            }
            .sheet(isPresented: $showAccount) {
                NavigationStack {
                    Form {
                        if let a = session.snapshot?.account {
                            LabeledContent("账户权益", value: money(a.balance))
                            LabeledContent("可用资金", value: money(a.available))
                            LabeledContent("占用保证金", value: money(a.margin))
                            LabeledContent("浮动盈亏", value: money(a.float_profit))
                            LabeledContent("平仓盈亏", value: money(a.close_profit))
                        }
                        Button("银期转账（未开放）") {}.disabled(true)
                        Button("退出账户", role: .destructive) {
                            Task { await session.logout(); showAccount = false }
                        }.disabled(session.busy)
                    }
                    .navigationTitle("模拟账户")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showAccount = false } } }
                }
            }
            .confirmationDialog("确认已在快期核对委托结果？", isPresented: $unlock) {
                Button("解除锁定") { session.acknowledgeUncertainOrder() }
            } message: { Text("未知结果可能已经下单，切勿重复提交。") }
            .confirmationDialog("确认模拟委托", isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }), titleVisibility: .visible, presenting: pendingAction) { action in
                Button("提交 " + action) {
                    guard let c = selected, validOrder(action) else { pendingAction = nil; return }
                    let direction = action == "开多" || action == "平空" ? "BUY" : "SELL"
                    let offset = action.hasPrefix("开") ? "OPEN" : (requiresSplit && closeToday ? "CLOSETODAY" : "CLOSE")
                    let price = selectedPrice, qty = String(selectedQuantity)
                    pendingAction = nil; tab = "委托"
                    Task { await session.submit(symbol: c.symbol, direction: direction, offset: offset, price: price, quantity: qty) }
                }
            } message: { action in
                Text((selected?.displayName ?? "") + " " + action + (action.hasPrefix("平") && requiresSplit ? (closeToday ? "今" : "昨") : "") + " " + String(selectedQuantity) + " 手 @ " + selectedPrice)
            }
            .confirmationDialog("确认撤销该模拟委托？", isPresented: Binding(get: { cancelID != nil }, set: { if !$0 { cancelID = nil } }), titleVisibility: .visible, presenting: cancelID) { id in
                Button("确认撤单", role: .destructive) { cancelID = nil; Task { await session.cancel(id) } }
            }
            .task(id: selectionRequest) {
                guard let c = selected else { return }
                while !Task.isCancelled {
                    await refreshQuote(c)
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                }
            }
            .onAppear { openInitialIfReady() }
            .onChange(of: session.canTrade) { _, _ in openInitialIfReady() }
            .sheet(isPresented: $local) {
                LocalPaperTradingCenterView(favoriteIDs: favoriteIDs, mainCodes: mainCodes, initialContract: initialContract)
            }
            .task(id: "\(session.signedIn)-\(scenePhase)") {
                guard session.signedIn, scenePhase == .active else { return }
                while !Task.isCancelled {
                    await session.refresh()
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                }
            }
        }.tint(MarketPalette.accent)
    }
    private func openInitialIfReady() {
        guard !openedInitial, initialContract != nil, session.canTrade else { return }
        openedInitial = true
        if let initialContract { choose(initialContract) }
    }

    private var accountHeader: some View {
        Section {
            HStack {
                Text("快期云端模拟").font(.caption.weight(.semibold))
                Spacer()
                Text(session.snapshot == nil ? "连接待确认" : "账户已连接")
                    .font(.caption).foregroundStyle(session.snapshot == nil ? Color.orange : Color.green)
                Button { showAccount = true } label: { Image(systemName: "person.crop.circle").font(.title3) }.buttonStyle(.plain)
            }
            HStack(spacing: 8) {
                metric("权益", money(session.snapshot?.account.balance, suffix: false))
                metric("可用", money(session.snapshot?.account.available, suffix: false))
                metric("使用率", usage)
            }
            HStack {
                Text("保证金 " + money(session.snapshot?.account.margin, suffix: false))
                Spacer()
                Text("浮盈 " + money(session.snapshot?.account.float_profit, suffix: false))
                    .foregroundStyle(MarketPalette.movement(session.snapshot?.account.float_profit))
            }.font(.caption).monospacedDigit()
        }
    }
    private var usage: String {
        guard let a = session.snapshot?.account, let b = a.balance, let m = a.margin, b > 0 else { return "--" }
        return String(format: "%.2f%%", m / b * 100)
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(size: 14, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var requiresSplit: Bool {
        selected?.symbol.hasPrefix("SHFE.") == true || selected?.symbol.hasPrefix("INE.") == true
    }
    private func validOrder(_ action: String) -> Bool {
        guard session.canTrade, let c = selected, let p = Double(selectedPrice), p.isFinite, p > 0, (1...10).contains(selectedQuantity) else { return false }
        if let tick = c.tick, tick > 0 {
            let steps = p / tick
            if abs(steps - steps.rounded()) > 0.00001 { return false }
        }
        if action.hasPrefix("平") {
            guard let pos = session.snapshot?.positions.first(where: { $0.symbol == c.symbol }) else { return false }
            let total = action == "平多" ? pos.long : pos.short
            let frozen = action == "平多" ? pos.frozen_long : pos.frozen_short
            return selectedQuantity <= max(0, total - (frozen ?? 0))
        }
        return true
    }
    private var orderPanel: some View {
        Section {
            Button { selecting = true } label: {
                HStack {
                    Image(systemName: "magnifyingglass")
                    Text(selected.map { contractName($0.symbol) } ?? "选择交易合约")
                    Spacer()
                    Text(selected?.symbol ?? "").font(.caption2).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption2)
                }.foregroundStyle(MarketPalette.ink)
            }
            HStack(spacing: 6) {
                priceButton("买一", selected?.bid)
                priceButton("最新", selected?.last)
                priceButton("卖一", selected?.ask)
            }
            Text(quoteError ? "报价获取失败，请核对价格" : (quoteStamp == nil ? "等待报价" : "参考报价 · " + (quoteStamp?.formatted(date: .omitted, time: .standard) ?? "")))
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Text("价格").font(.caption)
                Button { stepPrice(-1) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).disabled(selected?.tick == nil)
                TextField("限价", text: $selectedPrice).keyboardType(.decimalPad).multilineTextAlignment(.center).monospacedDigit()
                Button { stepPrice(1) } label: { Image(systemName: "plus.circle") }.buttonStyle(.borderless).disabled(selected?.tick == nil)
            }
            HStack {
                Text("手数").font(.caption)
                Button { selectedQuantity = max(1, selectedQuantity - 1) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                TextField("手数", value: $selectedQuantity, format: .number.grouping(.never)).keyboardType(.numberPad).multilineTextAlignment(.center).monospacedDigit()
                Button { selectedQuantity = min(10, selectedQuantity + 1) } label: { Image(systemName: "plus.circle") }.buttonStyle(.borderless)
            }
            if requiresSplit {
                Picker("平仓类型", selection: $closeToday) {
                    Text("平昨").tag(false)
                    Text("平今").tag(true)
                }.pickerStyle(.segmented)
            }
            HStack(spacing: 7) {
                tradeButton("开多", color: MarketPalette.up)
                tradeButton("开空", color: MarketPalette.down)
                tradeButton("平多", color: MarketPalette.down)
                tradeButton("平空", color: MarketPalette.up)
            }
            Text("仅限价模拟委托 · 单笔1–10手 · 提交前确认").font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func priceButton(_ title: String, _ value: Double?) -> some View {
        Button {
            if let value, value.isFinite, value > 0 { selectedPrice = String(value) }
        } label: {
            VStack(spacing: 4) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(value.map { $0.formatted() } ?? "--").font(.subheadline.weight(.medium)).monospacedDigit()
            }.frame(maxWidth: .infinity).padding(.vertical, 7)
        }.buttonStyle(.borderless).disabled(value == nil)
    }
    private func tradeButton(_ action: String, color: Color) -> some View {
        Button { pendingAction = action } label: {
            Text(action).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white).frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(color.opacity(validOrder(action) ? 0.85 : 0.25), in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.borderless).disabled(!validOrder(action))
    }
    private func stepPrice(_ delta: Int) {
        guard let c = selected, let t = c.tick, t.isFinite, t > 0, let p = Double(selectedPrice), p.isFinite else { return }
        let next = ((p / t).rounded() + Double(delta)) * t
        if next > 0 { selectedPrice = next.formatted(.number.grouping(.never).precision(.fractionLength(0...8))) }
    }
    private func choose(_ c: PaperContract) {
        selected = c; selectedPrice = c.last.flatMap { $0.isFinite && $0 > 0 ? String($0) : nil } ?? ""
        selectedQuantity = 1; closeToday = false; quoteStamp = nil; quoteError = false; selectionRequest = UUID()
    }
    private func product(_ symbol: String) -> FuturesInstrument? {
        catalog.filter { symbol.hasPrefix($0.id) }.max { $0.id.count < $1.id.count }
    }
    private func contractName(_ symbol: String) -> String {
        guard let p = product(symbol) else { return symbol }
        return p.name + String(symbol.dropFirst(p.id.count))
    }
    private func selectHolding(_ symbol: String) {
        if selected?.symbol == symbol { return }
        choose(PaperContract(symbol: symbol, name: contractName(symbol), tick: nil, multiplier: nil, last: nil, bid: nil, ask: nil))
    }
    @MainActor private func refreshQuote(_ c: PaperContract) async {
        do {
            let next: PaperContract
            if let option = c.option {
                guard let q = try await MarketDataService.options(for: option.underlying).first(where: { $0.code == c.symbol }) else { throw MarketDataError.noData }
                next = q.paperContract(underlying: option.underlying, name: c.name)
            } else {
                guard let p = product(c.symbol), let q = try await MarketDataService.listedContracts(for: p.id).first(where: { $0.code == c.symbol }) else { throw MarketDataError.noData }
                next = PaperContract(symbol: q.code, name: p.name, tick: q.priceTick, multiplier: q.volumeMultiple, last: q.last, bid: q.bid, ask: q.ask)
            }
            guard !Task.isCancelled, selected?.symbol == c.symbol else { return }
            selected = next; quoteStamp = Date(); quoteError = false
            if selectedPrice.isEmpty, let last = next.last, last > 0 { selectedPrice = String(last) }
        } catch {
            guard !Task.isCancelled, selected?.symbol == c.symbol else { return }
            quoteError = true
            selected = PaperContract(symbol: c.symbol, name: c.name, tick: c.tick, multiplier: c.multiplier, last: nil, bid: nil, ask: nil, option: c.option)
        }
    }
    private var recordsPanel: some View {
        Section {
            Picker("交易记录", selection: $tab) {
                ForEach(["持仓","挂单","委托","成交"], id: \.self) { Text($0) }
            }.pickerStyle(.segmented)
            if session.snapshot == nil {
                Text("账户数据暂不可用").font(.caption).foregroundStyle(.secondary)
            } else if tab == "持仓" {
                HStack {
                    Text("合约 / 多空").frame(maxWidth: .infinity, alignment: .leading)
                    Text("手数 / 可平").frame(width: 65)
                    Text("开仓均价").frame(width: 67, alignment: .trailing)
                    Text("浮盈").frame(width: 65, alignment: .trailing)
                }.font(.caption2).foregroundStyle(.secondary)
                ForEach(session.snapshot?.positions ?? []) { p in
                    if p.long > 0 { positionRow(p, long: true) }
                    if p.short > 0 { positionRow(p, long: false) }
                }
                if session.snapshot?.positions.isEmpty == true { Text("暂无持仓").font(.caption).foregroundStyle(.secondary) }
            } else if tab == "成交" {
                ForEach((session.snapshot?.fills ?? []).sorted { $0.time_ns > $1.time_ns }) { f in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(contractName(f.symbol)).fontWeight(.medium); Spacer(); Text(actionName(f.direction, f.offset)) }
                        HStack { Text((f.price.map { $0.formatted() } ?? "--") + " × " + String(f.quantity)); Spacer(); Text(Date(timeIntervalSince1970: Double(f.time_ns)/1e9).formatted(date: .omitted, time: .standard)) }.font(.caption).foregroundStyle(.secondary)
                    }
                }
                if session.snapshot?.fills?.isEmpty != false { Text("暂无成交或未取得数据").font(.caption).foregroundStyle(.secondary) }
            } else {
                let orders = (session.snapshot?.orders ?? []).filter { tab != "挂单" || $0.status == "ALIVE" }
                ForEach(orders) { o in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(contractName(o.symbol)).fontWeight(.medium); Spacer(); Text(actionName(o.direction,o.offset)) }
                        HStack {
                            Text((o.price.map { $0.formatted() } ?? "--") + " · " + String(o.quantity-o.remaining) + "/" + String(o.quantity) + "手")
                            Spacer()
                            Text(o.status == "ALIVE" ? (o.remaining < o.quantity ? "部分成交" : "挂单") : (o.remaining == 0 ? "全部成交" : "已结束"))
                            if o.status == "ALIVE" { Button("撤单", role: .destructive) { cancelID = o.id }.buttonStyle(.borderless).disabled(session.busy) }
                        }.font(.caption)
                        if !o.message.isEmpty { Text(o.message).font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                if orders.isEmpty { Text(tab == "挂单" ? "暂无挂单" : "暂无委托或未取得数据").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
    private func positionRow(_ p: CloudSnapshot.Position, long: Bool) -> some View {
        let qty = long ? p.long : p.short
        let frozen = long ? p.frozen_long : p.frozen_short
        let average = long ? p.open_price_long : p.open_price_short
        let profit = (long ? p.float_profit_long : p.float_profit_short) ?? ((p.long == 0 || p.short == 0) ? p.float_profit : nil)
        return Button { selectHolding(p.symbol) } label: {
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(contractName(p.symbol)).font(.caption.weight(.medium)).lineLimit(1)
                    Text(long ? "多" : "空").font(.caption2).foregroundStyle(long ? MarketPalette.up : MarketPalette.down)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text(String(qty) + "/" + (frozen.map { String(max(0, qty-$0)) } ?? "--")).frame(width: 65)
                Text(average.map { $0.formatted() } ?? "--").frame(width: 67, alignment: .trailing)
                Text(money(profit, suffix: false)).foregroundStyle(MarketPalette.movement(profit)).frame(width: 65, alignment: .trailing)
            }.font(.caption).monospacedDigit().foregroundStyle(MarketPalette.ink)
        }.buttonStyle(.borderless)
    }
    private func actionName(_ direction: String, _ offset: String) -> String {
        if offset == "OPEN" { return direction == "BUY" ? "开多" : "开空" }
        return (direction == "BUY" ? "平空" : "平多") + (offset == "CLOSETODAY" ? "今" : "")
    }
    private func money(_ value: Double?, suffix: Bool = true) -> String {
        guard let value, value.isFinite else { return "--" }
        return value.formatted(.number.precision(.fractionLength(2))) + (suffix ? " 元" : "")
    }
}

