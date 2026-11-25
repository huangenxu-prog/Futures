
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
    @State private var ticket = false
    @State private var showOrders = false
    @State private var showFills = false
    @State private var unlock = false
    @State private var cancelID: String?
    @State private var openedInitial = false
    var favoriteIDs: [String] = []
    var mainCodes: [String:String] = [:]
    var initialContract: PaperContract? = nil

    var body: some View {
        NavigationStack {
            List {
                if session.signedIn {
                    Section {
                        HStack {
                            Text("快期云端模拟").fontWeight(.semibold)
                            Spacer()
                            Text(session.snapshot == nil ? "未取得数据" : "账户已连接")
                                .font(.caption).foregroundStyle(session.snapshot == nil ? Color.orange : Color.green)
                        }
                        if let a = session.snapshot?.account {
                            LabeledContent("账户权益", value: money(a.balance))
                            LabeledContent("可用资金", value: money(a.available))
                            LabeledContent("占用保证金", value: money(a.margin))
                            LabeledContent("浮动盈亏", value: money(a.float_profit))
                            LabeledContent("平仓盈亏", value: money(a.close_profit))
                        } else { Text("暂不显示旧账户数据").foregroundStyle(.secondary) }
                    }
                    Section("当前持仓") {
                        if let positions = session.snapshot?.positions {
                            if positions.isEmpty { Text("暂无持仓").foregroundStyle(.secondary) }
                            ForEach(positions) { p in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(p.symbol).fontWeight(.medium)
                                    HStack {
                                        Text("多 \(p.long) 手 · 空 \(p.short) 手")
                                        Spacer()
                                        Text(money(p.float_profit))
                                    }.font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        } else { Text("持仓未取得").foregroundStyle(.secondary) }
                    }
                    Section("交易功能") {
                        Button("下单") { ticket = true }.disabled(!session.canTrade)
                        Button("委托 / 撤单") { showOrders = true }.disabled(session.snapshot?.simulation_orders != true)
                        Button("成交记录") { showFills = true }.disabled(session.snapshot?.simulation_orders != true)
                        if let message = session.actionMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                        if session.pendingOrder != nil {
                            Button("已核对官方委托，解除锁定") { unlock = true }.disabled(session.busy)
                        }
                        if session.snapshot?.simulation_orders != true {
                            Text("请升级交易网关以启用模拟下单").font(.caption).foregroundStyle(.secondary)
                        }
                        Button("银期转账（未开放）") {}.disabled(true)
                        Button("退出账户", role: .destructive) { Task { await session.logout() } }
                            .disabled(session.busy)
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
            .sheet(isPresented: $ticket) {
                CloudOrderTicket(session: session, contract: initialContract)
            }
            .sheet(isPresented: $showOrders) {
                NavigationStack {
                    List {
                        ForEach(session.snapshot?.orders ?? []) { o in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(o.symbol).fontWeight(.semibold)
                                Text(o.direction + " " + o.offset + " · " + (o.price.map { String($0) } ?? "--"))
                                Text("状态 " + o.status + " · 已成交 " + String(o.quantity - o.remaining) + "/" + String(o.quantity))
                                Text(o.message).font(.caption).foregroundStyle(.secondary)
                                Text(o.id).font(.caption2).foregroundStyle(.secondary)
                                if o.status == "ALIVE" {
                                    Button("撤单", role: .destructive) { cancelID = o.id }.disabled(session.busy)
                                }
                            }
                        }
                        if session.snapshot?.orders?.isEmpty != false { Text("暂无委托或未取得数据") }
                    }
                    .navigationTitle("云端模拟委托")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showOrders = false } } }
                    .confirmationDialog("确认撤销该模拟委托？", isPresented: Binding(get: { cancelID != nil }, set: { if !$0 { cancelID = nil } })) {
                        Button("确认撤单", role: .destructive) {
                            if let id = cancelID { Task { await session.cancel(id) } }
                            cancelID = nil
                        }
                    }
                }
            }
            .sheet(isPresented: $showFills) {
                NavigationStack {
                    List {
                        ForEach(session.snapshot?.fills ?? []) { f in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(f.symbol).fontWeight(.semibold)
                                Text(f.direction + " " + f.offset + " · " + (f.price.map { String($0) } ?? "--") + " × " + String(f.quantity))
                                Text(Date(timeIntervalSince1970: Double(f.time_ns) / 1e9).formatted()).font(.caption)
                            }
                        }
                        if session.snapshot?.fills?.isEmpty != false { Text("暂无成交或未取得数据") }
                    }
                    .navigationTitle("云端模拟成交")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showFills = false } } }
                }
            }
            .confirmationDialog("确认已在快期核对委托结果？", isPresented: $unlock) {
                Button("解除锁定") { session.acknowledgeUncertainOrder() }
            } message: { Text("未知结果可能已经下单，切勿重复提交。") }
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
        openedInitial = true; ticket = true
    }
    private func money(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "--" }
        return value.formatted(.number.precision(.fractionLength(2))) + " 元"
    }
}

private struct CloudOrderTicket: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: CloudTradeSession
    let contract: PaperContract?
    @State private var symbol: String
    @State private var price: String
    @State private var quantity = "1"
    @State private var action = "开多"
    @State private var closeToday = false
    @State private var confirm = false
    init(session: CloudTradeSession, contract: PaperContract?) {
        self.session = session; self.contract = contract
        _symbol = State(initialValue: contract?.symbol ?? "")
        _price = State(initialValue: contract?.last.map { String($0) } ?? "")
    }
    private var exchangeSplit: Bool { symbol.hasPrefix("SHFE.") || symbol.hasPrefix("INE.") }
    private var isClose: Bool { action.hasPrefix("平") }
    private var direction: String { action == "开多" || action == "平空" ? "BUY" : "SELL" }
    private var offset: String { isClose ? (exchangeSplit && closeToday ? "CLOSETODAY" : "CLOSE") : "OPEN" }
    private var valid: Bool {
        guard let p = Double(price), p.isFinite, p > 0, let q = Int(quantity), (1...10).contains(q) else { return false }
        return !symbol.isEmpty && session.canTrade
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("快期云端模拟 · 非实盘") {
                    if let contract {
                        LabeledContent(contract.displayName, value: symbol)
                    } else {
                        TextField("合约，例如 CZCE.SR701", text: $symbol).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Picker("方向", selection: $action) {
                        ForEach(["开多","开空","平多","平空"], id: \.self) { Text($0) }
                    }.pickerStyle(.segmented)
                    if exchangeSplit && isClose {
                        Picker("平仓类型", selection: $closeToday) {
                            Text("平昨").tag(false)
                            Text("平今").tag(true)
                        }.pickerStyle(.segmented)
                    }
                    TextField("限价", text: $price).keyboardType(.decimalPad)
                    if let contract {
                        HStack {
                            if let bid = contract.bid, bid.isFinite, bid > 0 { Button("买一 " + String(bid)) { price = String(bid) }.buttonStyle(.borderless) }
                            if let ask = contract.ask, ask.isFinite, ask > 0 { Button("卖一 " + String(ask)) { price = String(ask) }.buttonStyle(.borderless) }
                            if let last = contract.last, last.isFinite, last > 0 { Button("最新 " + String(last)) { price = String(last) }.buttonStyle(.borderless) }
                        }.font(.caption)
                    }
                    TextField("手数（1–10）", text: $quantity).keyboardType(.numberPad)
                    Text("仅限价模拟委托，报价为打开面板时的参考价。").font(.caption).foregroundStyle(.secondary)
                    Button("确认模拟下单") { confirm = true }.disabled(!valid)
                }
                if let message = session.actionMessage { Section { Text(message).font(.caption) } }
            }
            .navigationTitle("模拟下单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .confirmationDialog("确认模拟委托", isPresented: $confirm, titleVisibility: .visible) {
                Button("提交模拟委托") {
                    let sym = symbol, d = direction, o = offset, p = price, q = quantity
                    Task { await session.submit(symbol: sym, direction: d, offset: o, price: p, quantity: q); dismiss() }
                }
            } message: { Text(symbol + " " + action + " " + quantity + " 手 @ " + price) }
        }.tint(MarketPalette.accent)
    }
}
