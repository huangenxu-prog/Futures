
import SwiftUI
import Foundation
import Security

private enum TradeKeychain {
    private static func query(_ address: String, kind: String = "gateway") -> [String: Any]? {
        guard let parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https", let host = parts.host?.lowercased(),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else { return nil }
        let scope = "https://" + host + ":" + String(parts.port ?? 443) + parts.path
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.huangenxu.futures.trade." + kind,
                kSecAttrAccount as String: scope,
                kSecAttrSynchronizable as String: false]
    }
    static func load(_ address: String, kind: String = "gateway") -> String {
        guard var q = query(address, kind: kind) else { return "" }
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ key: String, address: String, kind: String = "gateway") -> Bool {
        guard let q = query(address, kind: kind), !key.isEmpty else { return false }
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        let status = SecItemUpdate(q as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var item = q
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
    static func remove(_ address: String, kind: String = "gateway") -> Bool {
        guard let q = query(address, kind: kind) else { return false }
        let status = SecItemDelete(q as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}


private struct CloudSnapshot: Decodable {
    struct Account: Decodable {
        let balance: Double?
        let available: Double?
        let margin: Double?
        let float_profit: Double?
        let close_profit: Double?
        let commission, market_value, risk_ratio, frozen_margin, frozen_commission, premium: Double?
    }
    struct Position: Decodable, Identifiable {
        let symbol: String
        let long: Int
        let short: Int
        let float_profit: Double?
        let open_price_long, open_price_short, float_profit_long, float_profit_short: Double?
        let frozen_long, frozen_short: Int?
        let margin_long, margin_short, market_value_long, market_value_short: Double?
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
        let time_ns: Int64?
        let display_state: String?
        let trade_price: Double?
        var stateText: String {
            switch display_state {
            case "ALIVE": return "挂单"
            case "PARTIAL": return "部分成交"
            case "FILLED": return "已成"
            case "CANCELED": return "已撤"
            case "PARTIAL_CANCELED": return "部成部撤"
            case "REJECTED": return "废单"
            default:
                if status == "ALIVE" { return remaining < quantity ? "部分成交" : "挂单" }
                if status == "FINISHED" && remaining == 0 { return "已成" }
                return "已结束"
            }
        }
    }
    struct Fill: Decodable, Identifiable {
        let id: String
        let symbol: String
        let direction: String
        let offset: String
        let price: Double?
        let quantity: Int
        let time_ns: Int64
        let calculated_close_profit: Double?
    }
    let positions: [Position]
    let orders: [Order]?
    let fills: [Fill]?
    let simulation_orders: Bool?
    let trade_mode: String?
    let order_submission_enabled: Bool?
    let maintenance: Bool?
}
private struct CloudReply: Decodable {
    let token: String?
    let snapshot: CloudSnapshot?
}
private enum CloudTradeError: LocalizedError {
    case invalidURL, rejected, unavailable, expired, conflict
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "请输入有效的 HTTPS 交易网关地址"
        case .rejected: return "登录或授权失败，请检查快期账户及网关访问密钥"
        case .unavailable: return "交易网关或快期服务暂不可用"
        case .expired: return "会话已失效，请退出后重新登录"
        case .conflict: return "交易会话正在处理或关闭，请稍后重试"
        }
    }
}

@MainActor
private final class CloudTradeSession: ObservableObject {
    static let shared = CloudTradeSession()
    @Published private(set) var snapshot: CloudSnapshot?
    @Published private(set) var signedIn = false
    @Published private(set) var busy = false
    @Published private(set) var latencyMS: Int?
    @Published private(set) var error: String?
    private var token: String?
    private var expectedMode = "simulation"
    var isLive: Bool { expectedMode == "live_readonly" }
    private func accepts(_ data: CloudSnapshot, mode: String) -> Bool {
        if mode == "live_readonly" { return data.trade_mode == mode && data.simulation_orders == false && data.order_submission_enabled == false }
        return data.simulation_orders == true && (data.trade_mode == nil || data.trade_mode == mode)
    }
    private var accessKey = ""
    private var endpoint: URL?
    private var generation = UUID()
    private var activeAddress = ""
    private var recovering = false
    private var retryAfter = Date.distantPast
    private var manualLogout = false
    private var savedPendingAddress = ""
    private func clearPending() {
        pendingOrder = nil
        if !savedPendingAddress.isEmpty { _ = TradeKeychain.remove(savedPendingAddress, kind: "pending") }
    }
    func allowManualLogin() { manualLogout = false; retryAfter = .distantPast }
    private var awaitingCancelID: String?
    private func reconcile(_ data: CloudSnapshot) {
        if let id = awaitingCancelID, let order = data.orders?.first(where: { $0.id == id }), order.status == "FINISHED" {
            awaitingCancelID = nil
            actionMessage = "委托状态：" + order.stateText
        }
        if let pendingOrder, data.orders?.contains(where: { $0.id == pendingOrder }) == true {
            clearPending()
            actionMessage = "已收到委托记录"
        }
    }
    private func install(_ data: CloudSnapshot, token: String, url: URL, address: String, key: String) {
        self.token = token; endpoint = url; accessKey = key; activeAddress = address
        generation = UUID()
        savedPendingAddress = address
        let unresolved = isLive ? "" : TradeKeychain.load(address, kind: "pending")
        pendingOrder = unresolved.isEmpty ? nil : unresolved
        reconcile(data)
        snapshot = data; signedIn = true
        error = nil
    }
    func recover(address: String, mode: String = "simulation") async {
        guard !manualLogout, !busy, !signedIn, !recovering, Date() >= retryAfter else { return }
        let key = TradeKeychain.load(address)
        let user = TradeKeychain.load(address, kind: "username")
        let password = TradeKeychain.load(address, kind: "password")
        guard !key.isEmpty, !user.isEmpty, !password.isEmpty else { return }
        recovering = true
        retryAfter = Date().addingTimeInterval(20)
        defer { recovering = false }
        await login(address: address, key: key, username: user, password: password, mode: mode)
    }
    @Published private(set) var pendingOrder: String?
    @Published private(set) var actionMessage: String?
    private var mutating = false
    var canTrade: Bool { signedIn && !isLive && snapshot?.simulation_orders == true && snapshot?.order_submission_enabled != false && snapshot?.maintenance != true && !busy && !mutating && pendingOrder == nil }
    func submit(symbol: String, direction: String, offset: String, price: String, quantity: String) async {
        guard canTrade, let url = endpoint, let token else { return }
        mutating = true; busy = true
        defer { mutating = false; busy = false }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        guard !activeAddress.isEmpty, TradeKeychain.save(id, address: activeAddress, kind: "pending") else {
            actionMessage = "无法保存委托保护记录，未发送委托"
            return
        }
        savedPendingAddress = activeAddress
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
        guard signedIn, !isLive, snapshot?.simulation_orders == true, snapshot?.maintenance != true, !busy, !mutating, let url = endpoint, let token else { return }
        mutating = true; busy = true
        defer { mutating = false; busy = false }
        do {
            _ = try await request(base: url, action: "cancel", key: accessKey, token: token, body: ["id": id])
            awaitingCancelID = id
            actionMessage = "撤单指令已交给SDK，等待回报"
        } catch {
            actionMessage = "撤单结果未确认，请核对委托状态"
        }
        await refresh()
    }
    func acknowledgeUncertainOrder() {
        clearPending()
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
    func login(address: String, key: String, username: String, password: String, mode: String = "simulation") async {
        guard !busy, !signedIn else { return }
        guard let parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "https", parts.host != nil, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, let url = parts.url else {
            error = CloudTradeError.invalidURL.localizedDescription; return
        }
        busy = true; error = nil
        defer { busy = false }
        do {
            expectedMode = mode
            let previous = isLive ? "" : TradeKeychain.load(address, kind: "session")
            if !previous.isEmpty,
               TradeKeychain.load(address, kind: "username") == username,
               TradeKeychain.load(address, kind: "password") == password {
                do {
                    let reply = try await request(base: url, action: "snapshot", key: key, token: previous, body: nil)
                    guard let data = reply.snapshot, accepts(data, mode: mode) else { throw CloudTradeError.rejected }
                    install(data, token: previous, url: url, address: address, key: key)
                    return
                } catch let failure as CloudTradeError {
                    guard case .expired = failure else { throw failure }
                    _ = TradeKeychain.remove(address, kind: "session")
                }
            }
            let reply = try await request(base: url, action: "login", key: key, token: nil,
                                          body: ["username": username, "password": password, "mode": mode])
            guard let session = reply.token, !session.isEmpty, let data = reply.snapshot, accepts(data, mode: mode) else { throw CloudTradeError.rejected }
            install(data, token: session, url: url, address: address, key: key)
            if isLive { return } // Live credentials are configured explicitly in Settings.
            let saved = [
                TradeKeychain.save(key, address: address),
                TradeKeychain.save(username, address: address, kind: "username"),
                TradeKeychain.save(password, address: address, kind: "password"),
                TradeKeychain.save(session, address: address, kind: "session")
            ]
            if saved.contains(false) {
                self.error = "登录成功，但设备安全存储未能完整保存登录信息"
            }
        } catch {
            self.error = error.localizedDescription
            if let failure = error as? CloudTradeError, case .rejected = failure {
                retryAfter = .distantFuture
            }
        }
    }
    func refresh() async {
        guard let url = endpoint, let token, signedIn else { return }
        let current = generation
        do {
            let reply = try await request(base: url, action: "snapshot", key: accessKey, token: token, body: nil)
            guard current == generation, !Task.isCancelled else { return }
            guard let data = reply.snapshot, accepts(data, mode: expectedMode) else { throw CloudTradeError.rejected }
            snapshot = data; error = nil
            reconcile(data)
        } catch {
            guard current == generation, !Task.isCancelled else { return }
            snapshot = nil; latencyMS = nil
            if let failure = error as? CloudTradeError, case .expired = failure {
                generation = UUID()
                _ = TradeKeychain.remove(activeAddress, kind: "session")
                retryAfter = .distantPast
                self.token = nil; self.endpoint = nil; self.accessKey = ""
                signedIn = false
                self.error = "交易会话已失效，请重新登录。网关密钥已保留。"
            } else {
                self.error = error.localizedDescription
            }
        }
    }
    func logout() async {
        guard !busy else { return }
        busy = true
        let url = endpoint, session = token, key = accessKey
        manualLogout = true
        if !isLive && !activeAddress.isEmpty {
            _ = TradeKeychain.remove(activeAddress, kind: "session")
        }
        generation = UUID(); snapshot = nil; signedIn = false; latencyMS = nil
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
            if action == "order" {
                guard let quantity = body["quantity"].flatMap(Int.init), let price = body["price"].flatMap(Double.init), price.isFinite else { throw CloudTradeError.rejected }
                var payload: [String: Any] = body.mapValues { $0 as Any }
                payload["quantity"] = quantity; payload["price"] = price
                req.httpBody = try JSONSerialization.data(withJSONObject: payload)
            } else { req.httpBody = try JSONEncoder().encode(body) }
        }
        let started = ProcessInfo.processInfo.systemUptime
        let (data, response) = try await http.data(for: req)
        if action == "snapshot", (response as? HTTPURLResponse)?.statusCode == 200 {
            latencyMS = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw CloudTradeError.unavailable }
        switch status {
        case 200: return try JSONDecoder().decode(CloudReply.self, from: data)
        case 401: throw token == nil ? CloudTradeError.rejected : CloudTradeError.expired
        case 403: throw CloudTradeError.rejected
        case 409: throw CloudTradeError.conflict
        case 429: throw CloudTradeError.conflict
        default: throw NSError(domain: "QihuiTrade", code: status, userInfo: [NSLocalizedDescriptionKey: "交易服务 HTTP " + String(status) + "，请重试"])
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
    @AppStorage("qihui.trade.default-mode.v1") private var defaultMode = "simulation"
    @AppStorage("qihui.trade.live-endpoint.v1") private var liveEndpoint = ""
    @State private var showConnectionSettings = false
    @State private var unlock = false
    @State private var cancelID: String?
    @State private var orderDetail: CloudSnapshot.Order?
    @Environment(\.futuresCatalog) private var catalog
    @Environment(\.mainContracts) private var liveMainQuotes
    @State private var selected: PaperContract?
    private struct CachedTradeQuote {
        let contract: PaperContract
        let details: MarketDataService.ContractQuote?
        let optionDetails: MarketDataService.OptionQuote?
        let received: Date
    }
    @State private var recentTradeQuotes: [String: CachedTradeQuote] = [:]
    @State private var selecting = false
    @State private var expandedHolding: String?
    @State private var detailedQuote: MarketDataService.ContractQuote?
    @State private var optionQuote: MarketDataService.OptionQuote?
    @State private var chartQuote: MarketDataService.ContractQuote?
    @State private var chartProduct: FuturesInstrument?
    @State private var showHoldingChart = false
    @AppStorage("qihui.change.basis.v1") private var changeBasis = "settlement"
    @State private var selectionRequest = UUID()
    private enum PriceMode: String, CaseIterable {
        case opponent = "对手价", queued = "排队价", latest = "最新价", limit = "限价"
    }
    private struct OpeningDraft {
        let symbol: String
        let action: String
        let title: String
        let price: String
        let quantity: Int
    }
    @State private var priceMode: PriceMode = .opponent
    @State private var openingDraft: OpeningDraft?
    @State private var selectedPrice = ""
    @State private var selectedQuantity = 1
    @State private var pendingAction: String?
    @State private var showQuickConfirmation = false
    @State private var quickConfirmationError: String?
    @State private var chooseCloseSide = false
    @State private var closeToday = false
    @State private var closingSide: Bool? = nil
    @State private var closePrice = ""
    @State private var closeQuantity = 1
    @State private var closeConfirm = false
    @State private var tab = "持仓"
    @State private var quoteStamp: Date?
    @State private var quoteError = false
    @State private var showAccount = false
    @State private var openedInitial = false
    var favoriteIDs: [String] = []
    var mainCodes: [String:String] = [:]
    var initialContract: PaperContract? = nil
    var quickOnly = false

    var body: some View {
        NavigationStack {
            Group {
                if session.signedIn {
                    if quickOnly {
                        ScrollView {
                            signedInPanel
                        }
                        .scrollDismissesKeyboard(.interactively)
                    } else {
                        signedInPanel
                    }
                } else {
                    loginPanel
                }
            }
            .scrollContentBackground(.hidden)
            .disabled(pendingAction != nil || cancelID != nil || closingSide != nil)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let side = closingSide { closingBar(side) }
                else if let id = cancelID { cancelConfirmationBar(id) }
                else if !quickOnly, let action = pendingAction { orderConfirmationBar(action) }
            }
            .background(MarketPalette.background)
            .safeAreaInset(edge: .top, spacing: 0) {
                if quickOnly { quickHeader }
            }
            .toolbar(quickOnly ? .hidden : .visible, for: .navigationBar)
            .navigationTitle(quickOnly ? "快捷开仓" : (session.signedIn ? (session.isLive ? "实盘交易" : "模拟交易") : (defaultMode == "live_readonly" ? "实盘交易" : "模拟交易")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                if !quickOnly && session.signedIn {
                    ToolbarItem(placement: .topBarTrailing) { connectionIndicator }
                }
            }
            .sheet(isPresented: $selecting) {
                PaperContractPicker(instruments: catalog, favoriteIDs: favoriteIDs, mainCodes: mainCodes) { c in
                    choose(c); selecting = false
                }
            }
            .fullScreenCover(isPresented: $showHoldingChart) {
                if let chartProduct, let chartQuote {
                    InstrumentDetailView(instrument: chartProduct, selectedContract: chartQuote)
                }
            }
            .sheet(item: $orderDetail) { initial in
                orderDetailSheet(initial)
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
                            if let fee = a.commission { LabeledContent("累计手续费", value: money(fee)) }
                            if let value = a.market_value { LabeledContent("期权市值", value: money(value)) }
                        }
                        Button("银期转账（未开放）") {}.disabled(true)
                        Button("退出账户", role: .destructive) {
                            Task { await session.logout(); showAccount = false }
                        }.disabled(session.busy)
                    }
                    .navigationTitle(session.isLive ? "实盘只读账户" : "模拟账户")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showAccount = false } } }
                }
            }
            .alert("确认模拟委托", isPresented: $showQuickConfirmation, presenting: openingDraft) { draft in
                Button("确认" + draft.title) {
                    if validDraft(draft.action) && pendingAction == draft.action {
                        submitConfirmed(draft.action)
                    } else {
                        pendingAction = nil; openingDraft = nil
                        quickConfirmationError = "委托条件已变化，请重新核对报价后下单"
                    }
                }
                Button("取消", role: .cancel) { pendingAction = nil; openingDraft = nil }
            } message: { draft in
                Text("\(contractName(draft.symbol)) \(draft.title) \(draft.quantity) 手 @ \(draft.price)")
            }
            .confirmationDialog("确认已在快期核对委托结果？", isPresented: $unlock) {
                Button("解除锁定") { session.acknowledgeUncertainOrder() }
            } message: { Text("未知结果可能已经下单，切勿重复提交。") }
            .task(id: heldSymbols) {
                let symbols = heldSymbols
                guard !symbols.isEmpty else { return }
                while !Task.isCancelled && session.signedIn {
                    if scenePhase == .active { await warmHoldingQuotes(symbols) }
                    do { try await Task.sleep(for: .seconds(8)) } catch { return }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .qihuiLiveQuotes)) { notification in
                guard scenePhase == .active, let updates = notification.object as? [String: MarketDataService.MainContract], let c = selected, c.option == nil, let p = product(c.symbol), let q = updates[p.id], q.code == c.symbol, let last = q.last, last.isFinite, last > 0 else { return }
                if let previous = detailedQuote?.time, let incoming = q.time, incoming < previous { return }
                selected = PaperContract(symbol: c.symbol, name: c.name, tick: c.tick, multiplier: c.multiplier, last: last, bid: q.bid, ask: q.ask, option: nil)
                detailedQuote = MarketDataService.ContractQuote(code: q.code, month: q.month, last: q.last, settlement: q.settlement, bid: q.bid, ask: q.ask, volume: q.volume, interest: q.interest, priceTick: c.tick, volumeMultiple: c.multiplier, bidVolume: q.bidVolume, askVolume: q.askVolume, opening: q.opening, highest: q.highest, lowest: q.lowest, upperLimit: detailedQuote?.upperLimit, lowerLimit: detailedQuote?.lowerLimit, referenceMargin: detailedQuote?.referenceMargin, referenceCommission: detailedQuote?.referenceCommission, openMinLimitVolume: detailedQuote?.openMinLimitVolume, openMaxLimitVolume: detailedQuote?.openMaxLimitVolume, minLimitVolume: detailedQuote?.minLimitVolume, maxLimitVolume: detailedQuote?.maxLimitVolume, dailyOpenLimit: detailedQuote?.dailyOpenLimit, time: q.time)
            }
            .task(id: "\(selectionRequest)-\(scenePhase)-\(session.signedIn)") {
                guard scenePhase == .active, session.signedIn, let c = selected else { return }
                let request = selectionRequest
                while !Task.isCancelled {
                    await refreshQuote(c, request: request)
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                }
            }
            .onAppear {
                openInitialIfReady()
            }
            .onChange(of: session.signedIn) { _, signedIn in
                if signedIn {
                    openInitialIfReady()
                } else {
                    pendingAction = nil; openingDraft = nil; showQuickConfirmation = false; orderDetail = nil; cancelID = nil; closingSide = nil; closeConfirm = false
                    recentTradeQuotes.removeAll(); expandedHolding = nil
                }
            }
            .sheet(isPresented: $showConnectionSettings) { TradeConnectionSettingsView() }
            .task(id: "\(address)-\(scenePhase)") {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    if session.signedIn { await session.refresh() }
                    else if !showConnectionSettings { await connectDefault() }
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                }
            }
        }.tint(MarketPalette.accent)
    }
    private func connectDefault() async {
        let target = defaultMode == "live_readonly" ? liveEndpoint : address
        guard !target.isEmpty, defaultMode != "live_readonly" || target != address else { return }
        await session.recover(address: target, mode: defaultMode)
    }
    private var loginPanel: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle").font(.system(size: 42))
                .foregroundStyle(MarketPalette.muted)
            Text(session.busy ? "正在连接账户" : "交易账户未连接").font(.headline)
            if session.busy {
                ProgressView()
            } else {
                Button("重新连接") {
                    session.allowManualLogin()
                    Task { await connectDefault() }
                }
                .buttonStyle(.borderedProminent)
            }
            if let message = session.error {
                Text(message).font(.caption).foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Button("交易设置") { showConnectionSettings = true }
                .buttonStyle(.bordered).disabled(session.busy)
            Text("首次配置或更换账户，请进入交易设置。")
                .font(.caption).foregroundStyle(MarketPalette.muted)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MarketPalette.background)
    }

    private var signedInPanel: some View {
        VStack(spacing: 0) {
                        if !quickOnly { accountHeader; Divider() }
                        else { Text(session.isLive ? "实盘只读" : "快期云端模拟").font(.caption).foregroundStyle(MarketPalette.muted).padding(.bottom, 8) }
                        if session.isLive {
                            Text("实盘只读 · 禁止下单及撤单").font(.caption).foregroundStyle(.secondary)
                            if quickOnly { Button("退出账户") { Task { await session.logout() } } }
                        } else if quickOnly { quickOrderPanel } else { orderPanel }
                        if !quickOnly { Divider(); recordsPanel }

                    if let message = session.actionMessage { Text(message).font(.caption).lineLimit(2) }
                    if session.pendingOrder != nil {
                        Button("已核对官方委托，解除锁定") { unlock = true }.disabled(session.busy).font(.caption)
                    }
                    if session.snapshot?.simulation_orders != true {
                        Text("暂不可提交委托，请确认交易网关连接").font(.caption).foregroundStyle(.secondary)
                    }
                    if let message = session.error { Text(message).font(.caption).foregroundStyle(.red) }
                    }
                    .padding(.horizontal, 12)
    }
    private var quickHeader: some View {
        HStack {
            Button("关闭") { dismiss() }
                .font(.subheadline.weight(.medium))
                .frame(minWidth: 64, minHeight: 44, alignment: .leading)
            Spacer()
            Text("快捷开仓").font(.headline)
            Spacer()
            Color.clear.frame(width: 64, height: 44)
        }
        .padding(.horizontal, 16)
        .background(MarketPalette.background)
    }
    private func openInitialIfReady() {
        guard !openedInitial, initialContract != nil, session.signedIn else { return }
        openedInitial = true
        if let initialContract { choose(initialContract); seedHoldingQuote(initialContract) }
    }

    private var connectionIndicator: some View {
        HStack(spacing: 4) {
            Circle().fill(session.snapshot == nil ? Color.orange : Color.green).frame(width: 5, height: 5)
            VStack(alignment: .trailing, spacing: 2) {
                Text(session.snapshot == nil ? "连接待确认" : "账户已连接")
                    .font(.system(size: 9)).foregroundStyle(MarketPalette.muted)
                if let ms = session.latencyMS, session.snapshot != nil {
                    Text("\(ms)ms").font(.system(size: 10)).monospacedDigit()
                        .foregroundStyle(ms < 150 ? Color.green : Color.orange)
                        .accessibilityLabel("账户快照请求耗时 \(ms) 毫秒")
                }
            }
            Button { showAccount = true } label: {
                Image(systemName: "person.crop.circle").font(.title3)
            }.buttonStyle(.plain).accessibilityLabel("账户明细与设置")
        }
    }
    private var accountHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                accountMetric("账户权益", money(session.snapshot?.account.balance, suffix: false), large: true)
                accountMetric("持仓盈亏", money(session.snapshot?.account.float_profit, suffix: false),
                              tint: MarketPalette.movement(session.snapshot?.account.float_profit), large: true)
            }
            HStack(alignment: .top, spacing: 12) {
                accountMetric("可用资金", money(session.snapshot?.account.available, suffix: false))
                accountMetric("保证金占比", usage)
            }
        }
        .padding(10)
        .background(MarketPalette.surface, in: RoundedRectangle(cornerRadius: 10))
        .padding(.vertical, 6)
    }
    private func accountMetric(_ label: String, _ value: String, tint: Color = MarketPalette.ink, large: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(MarketPalette.muted)
            Text(value).font(.system(size: large ? 25 : 17, weight: .semibold))
                .monospacedDigit().foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.55)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var usage: String {
        guard let a = session.snapshot?.account, let b = a.balance, let m = a.margin,
              b.isFinite, m.isFinite, b > 0 else { return "--" }
        return String(format: "%.2f%%", m / b * 100)
    }
    private func metric(_ title: String, _ value: String, tint: Color = MarketPalette.ink) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10)).foregroundStyle(MarketPalette.muted)
                .lineLimit(1).minimumScaleFactor(0.8)
            Text(value).font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit().foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.6)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var requiresSplit: Bool {
        selected?.symbol.hasPrefix("SHFE.") == true || selected?.symbol.hasPrefix("INE.") == true
    }
    private func effectivePrice(buy: Bool) -> Double? {
        let value: Double?
        switch priceMode {
        case .opponent: value = buy ? selected?.ask : selected?.bid
        case .queued: value = buy ? selected?.bid : selected?.ask
        case .latest: value = selected?.last
        case .limit: value = Double(selectedPrice)
        }
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }
    private func priceText(_ price: Double?) -> String {
        guard let price, price.isFinite, price > 0 else { return "--" }
        return String(format: "%.8f", price).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }
    private func validPrice(_ price: Double?) -> Bool {
        guard let price, price.isFinite, price > 0,
              let tick = selected?.tick, tick.isFinite, tick > 0 else { return false }
        let steps = price / tick
        return steps.isFinite && abs(steps - steps.rounded()) < 0.00001
    }
    private var openingMinimum: Int? {
        guard let c = selected else { return nil }
        return c.isOption ? optionQuote?.openMinLimitVolume : detailedQuote?.openMinLimitVolume
    }
    private var openingMaximum: Int? {
        guard let c = selected else { return nil }
        return c.isOption ? optionQuote?.openMaxLimitVolume : detailedQuote?.openMaxLimitVolume
    }
    private var dailyOpeningLimit: Int? {
        guard let c = selected else { return nil }
        return c.isOption ? optionQuote?.dailyOpenLimit : detailedQuote?.dailyOpenLimit
    }
    private func openingQuantityAllowed(_ quantity: Int) -> Bool {
        guard quantity > 0 else { return false }
        if let minimum = openingMinimum, minimum > 0, quantity < minimum { return false }
        if let maximum = openingMaximum, maximum > 0, quantity > maximum { return false }
        return true
    }
    private func closingQuantityAllowed(_ quantity: Int) -> Bool {
        guard let c = selected, quantity > 0 else { return false }
        let minimum = c.isOption ? optionQuote?.minLimitVolume : detailedQuote?.minLimitVolume
        let maximum = c.isOption ? optionQuote?.maxLimitVolume : detailedQuote?.maxLimitVolume
        if let minimum, minimum > 0, quantity < minimum { return false }
        if let maximum, maximum > 0, quantity > maximum { return false }
        return true
    }
    @ViewBuilder private var openingLimitNotice: some View {
        if let minimum = openingMinimum, minimum > 1 {
            Text("最小开仓 \(minimum)手")
                .font(.caption).foregroundStyle(selectedQuantity < minimum ? Color.yellow : MarketPalette.muted)
        }
        if let maximum = openingMaximum, maximum > 0, selectedQuantity > maximum {
            Text("单笔最多开仓 \(maximum)手").font(.caption).foregroundStyle(Color.yellow)
        }
        if let limit = dailyOpeningLimit, limit > 0 {
            Text("日内开仓限额 \(limit)手（非剩余额度）").font(.caption2).foregroundStyle(MarketPalette.muted)
        }
    }
    private func validOrder(_ action: String) -> Bool {
        guard action == "开多" || action == "开空", session.canTrade,
              let c = selected, c.hasMetadata, openingQuantityAllowed(selectedQuantity),
              !quoteError, let stamp = quoteStamp, Date().timeIntervalSince(stamp) < 60 else { return false }
        return validPrice(effectivePrice(buy: action == "开多"))
    }
    private func validDraft(_ action: String) -> Bool {
        guard let draft = openingDraft, draft.action == action, draft.symbol == selected?.symbol,
              session.canTrade, !quoteError, let stamp = quoteStamp, Date().timeIntervalSince(stamp) < 60, openingQuantityAllowed(draft.quantity), selected?.hasMetadata == true else { return false }
        return validPrice(Double(draft.price))
    }
    private var priceModePicker: some View {
        HStack(spacing: 4) {
            ForEach(PriceMode.allCases, id: \.self) { mode in
                Button {
                    IndicatorKeyboard.dismiss()
                    if mode == .limit && priceMode != .limit {
                        selectedPrice = selected?.last.map { priceText($0) } ?? ""
                    }
                    priceMode = mode
                } label: {
                    Text(mode.rawValue).font(quickOnly ? .subheadline.weight(.medium) : .caption2.weight(.medium))
                        .frame(maxWidth: .infinity).padding(.vertical, quickOnly ? 11 : 6)
                        .foregroundStyle(priceMode == mode ? (quickOnly ? Color.white : MarketPalette.accent) : (quickOnly ? MarketPalette.ink : MarketPalette.muted))
                        .background(priceMode == mode ? MarketPalette.accent.opacity(quickOnly ? 1 : 0.12) : MarketPalette.raised, in: RoundedRectangle(cornerRadius: quickOnly ? 7 : 4))
                }.buttonStyle(.plain)
            }
        }
    }
    private var priceInput: some View {
        HStack(spacing: 4) {
            Button { stepPrice(-1) } label: { Image(systemName: "minus").frame(width: quickOnly ? 44 : 30, height: quickOnly ? 44 : 30) }
                .buttonStyle(.plain).disabled(selected?.tick == nil)
            if priceMode == .limit {
                TextField("限价", text: $selectedPrice).keyboardType(.decimalPad).multilineTextAlignment(.center).monospacedDigit()
            } else {
                Text(priceMode.rawValue).font(.subheadline.weight(.medium)).frame(maxWidth: .infinity)
            }
            Button { stepPrice(1) } label: { Image(systemName: "plus").frame(width: quickOnly ? 44 : 30, height: quickOnly ? 44 : 30) }
                .buttonStyle(.plain).disabled(selected?.tick == nil)
        }.padding(3).overlay(RoundedRectangle(cornerRadius: quickOnly ? 8 : 5).stroke(MarketPalette.divider))
    }
    private var quickOrderPanel: some View {
        VStack(spacing: 14) {
            HStack {
                Text(selected.map { contractName($0.symbol) } ?? initialContract.map { contractName($0.symbol) } ?? "--")
                    .font(.headline)
                Spacer()
                Text(selected?.symbol ?? initialContract?.symbol ?? "").font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                priceButton("买一", selected?.bid)
                Rectangle().fill(MarketPalette.divider).frame(width: 1, height: 22)
                priceButton("最新", selected?.last)
                Rectangle().fill(MarketPalette.divider).frame(width: 1, height: 22)
                priceButton("卖一", selected?.ask)
            }
            priceModePicker
            priceInput
            HStack(spacing: 16) {
                Text("手数").font(.subheadline.weight(.medium)).frame(width: 64, alignment: .leading)
                HStack(spacing: 4) {
                    Button { if selectedQuantity > 1 { selectedQuantity -= 1 } else { selectedQuantity = 1 } } label: {
                        Image(systemName: "minus").font(.title3.weight(.medium)).frame(width: 48, height: 44)
                    }.foregroundStyle(MarketPalette.accent).accessibilityLabel("减少手数")
                    TextField("手数", value: $selectedQuantity, format: .number.grouping(.never))
                        .keyboardType(.numberPad).multilineTextAlignment(.center).monospacedDigit().font(.title3.weight(.medium))
                        .frame(maxWidth: .infinity)
                    Button { if selectedQuantity < Int.max { selectedQuantity += 1 } } label: {
                        Image(systemName: "plus").font(.title3.weight(.medium)).frame(width: 48, height: 44)
                    }.foregroundStyle(MarketPalette.accent).accessibilityLabel("增加手数")
                }
                .padding(3)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(MarketPalette.divider))
            }.buttonStyle(.borderless)
            HStack(spacing: 8) {
                tradeButton("开多", color: MarketPalette.up)
                if selected?.option != nil { unifiedCloseButton } else { tradeButton("开空", color: MarketPalette.down) }
            }
            if let amount = orderReferenceAmount { Text(amount).font(.caption).foregroundStyle(MarketPalette.muted) }
            orderFundingDetails
            openingLimitNotice
            if let quickConfirmationError { Text(quickConfirmationError).font(.caption).foregroundStyle(.red) }
            Text(quoteError ? "报价获取失败，请核对价格" : (quoteStamp == nil ? "等待报价" : "参考报价 · " + (quoteStamp?.formatted(date: .omitted, time: .standard) ?? "")))
                .font(.caption).foregroundStyle(MarketPalette.muted)
        }.padding(.vertical, 8)
    }
    private func quoteColor(_ value: Double?) -> Color {
        guard let value, value.isFinite else { return MarketPalette.muted }
        guard let reference = quoteReference,
              reference.isFinite, reference > 0 else { return MarketPalette.ink }
        if abs(value - reference) < 0.0000001 { return MarketPalette.ink }
        return MarketPalette.movement(value - reference)
    }
    private var quoteReference: Double? {
        changeBasis == "open" ? (optionQuote?.opening ?? detailedQuote?.opening) : (optionQuote?.settlement ?? detailedQuote?.settlement)
    }
    private var quoteChange: Double? {
        guard let last = selected?.last, let reference = quoteReference, last.isFinite, reference.isFinite, reference > 0 else { return nil }
        return last - reference
    }
    private var quoteChangeText: String {
        guard let change = quoteChange, let reference = quoteReference else { return "--" }
        return String(format: "%+.2f%%", change / reference * 100)
    }
    private var orderPanel: some View {
        VStack(spacing: 7) {
            HStack(alignment: .center, spacing: 8) {
                Button { selecting = true } label: {
                    HStack(spacing: 5) {
                        Text(selected.map { contractName($0.symbol) } ?? "选择交易合约")
                            .font(.system(size: 17, weight: .semibold))
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Image(systemName: "chevron.down").font(.caption2)
                    }.foregroundStyle(MarketPalette.ink)
                        .frame(minHeight: 36, alignment: .leading)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("选择交易合约")
                Spacer(minLength: 4)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(priceText(selected?.last))
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(quoteColor(selected?.last))
                    Text(quoteChangeText).font(.caption2)
                        .foregroundStyle(MarketPalette.movement(quoteChange))
                }.monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
            }
            HStack(spacing: 12) {
                quoteLine("买一", selected?.bid, volume: optionQuote?.bidVolume ?? detailedQuote?.bidVolume)
                quoteLine("卖一", selected?.ask, volume: optionQuote?.askVolume ?? detailedQuote?.askVolume)
            }
            priceModePicker
            HStack(spacing: 6) {
                Text("手数").font(.caption).foregroundStyle(MarketPalette.muted).frame(width: 27, alignment: .leading)
                HStack(spacing: 0) {
                    Button { selectedQuantity = max(1, selectedQuantity - 1) } label: {
                        Image(systemName: "minus").frame(width: 30, height: 34)
                    }.buttonStyle(.plain)
                    TextField("手数", value: $selectedQuantity, format: .number.grouping(.never))
                        .keyboardType(.numberPad).multilineTextAlignment(.center).monospacedDigit()
                    Button { if selectedQuantity < Int.max { selectedQuantity += 1 } } label: {
                        Image(systemName: "plus").frame(width: 30, height: 34)
                    }.buttonStyle(.plain)
                }.frame(maxWidth: .infinity)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(MarketPalette.divider))
                Text("价格").font(.caption).foregroundStyle(MarketPalette.muted)
                priceInput.frame(maxWidth: .infinity)
            }
            HStack {
                Text(quoteError ? "报价失败" : (quoteStamp == nil ? (selected?.last == nil ? "等待报价" : "参考行情 · 确认中") : "参考报价"))
                Spacer()
                if let amount = orderReferenceAmount { Text(amount) }
            }.font(.caption2).foregroundStyle(MarketPalette.muted)
            orderFundingDetails
            openingLimitNotice
            HStack(spacing: 8) {
                tradeButton("开多", color: MarketPalette.up, title: selected?.isOption == true ? "买开" : "买多")
                tradeButton("开空", color: MarketPalette.down, title: selected?.isOption == true ? "卖开" : "卖空")
                unifiedCloseButton
            }
        }.padding(.vertical, 6)
    }

    private var referenceFundingLines: [String] {
        guard let c = selected, !quoteError, let stamp = quoteStamp,
              Date().timeIntervalSince(stamp) < 60, selectedQuantity > 0 else { return [] }
        let quantity = Double(selectedQuantity)
        let available = session.snapshot?.account.available
        func capacity(_ cost: Double) -> String? {
            guard let available, available.isFinite, cost.isFinite, cost > 0 else { return nil }
            let count = floor(max(0, available) / cost)
            guard count.isFinite else { return nil }
            return count.formatted(.number.precision(.fractionLength(0)))
        }
        if c.isOption {
            guard let price = effectivePrice(buy: true), price.isFinite, price > 0,
                  let multiplier = c.multiplier, multiplier.isFinite, multiplier > 0 else { return [] }
            let premium = price * multiplier
            guard premium.isFinite, (premium * quantity).isFinite else { return [] }
            var lines = ["买开保证金 0 · 权利金 " + money(premium * quantity)]
            if let count = capacity(premium) { lines.append("买开可开上限 " + count + "手（未计手续费）") }
            return lines
        }
        guard let q = detailedQuote, q.code == c.symbol else { return [] }
        var lines: [String] = []
        let margin = q.referenceMargin.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let fee = q.referenceCommission.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        if let margin, (margin * quantity).isFinite {
            lines.append("参考保证金/手 " + money(margin, suffix: false) + " · 合计 " + money(margin * quantity))
            if let count = capacity(margin) {
                lines.append("参考最大可开 " + count + "手（未计手续费）")
            }
        }
        if let fee, (fee * quantity).isFinite {
            lines.append("参考手续费/手 " + money(fee, suffix: false) + " · 合计 " + money(fee * quantity))
        }
        return lines
    }
    @ViewBuilder private var orderFundingDetails: some View {
        let lines = referenceFundingLines
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(lines, id: \.self) { line in
                    Text(line).font(.caption2).foregroundStyle(MarketPalette.muted)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var orderReferenceAmount: String? {
        guard let c = selected, let multiplier = c.multiplier, multiplier.isFinite, multiplier > 0,
              selectedQuantity > 0, let buy = effectivePrice(buy: true), let sell = effectivePrice(buy: false),
              buy.isFinite, sell.isFinite, buy > 0, sell > 0 else { return nil }
        let b = buy * multiplier * Double(selectedQuantity)
        let s = sell * multiplier * Double(selectedQuantity)
        guard b.isFinite, s.isFinite else { return nil }
        let label = c.isOption ? "权利金" : "名义金额"
        if b == s { return label + " " + money(b) }
        return label + " 买 " + money(b, suffix: false) + " / 卖 " + money(s)
    }

    private var closeCandidates: [Bool] {
        [true, false].filter { (availableToClose($0) ?? 0) > 0 }
    }

    private var preferredCloseSide: Bool? {
        if let symbol = selected?.symbol {
            if expandedHolding == symbol + "/long", closeCandidates.contains(true) { return true }
            if expandedHolding == symbol + "/short", closeCandidates.contains(false) { return false }
        }
        return closeCandidates.count == 1 ? closeCandidates.first : nil
    }

    private var unifiedCloseButton: some View {
        let side = preferredCloseSide
        let enabled = session.canTrade && selected?.hasMetadata == true && !closeCandidates.isEmpty
        return Button {
            guard enabled, let p = session.snapshot?.positions.first(where: { $0.symbol == selected?.symbol }) else { return }
            if let side { beginClose(p, long: side) }
            else { chooseCloseSide = true }
        } label: {
            VStack(spacing: 5) {
                Text(priceText(side.flatMap { effectivePrice(buy: !$0) })).font(.system(size: 22, weight: .semibold).monospacedDigit())
                Text("平仓").font(.system(size: 16, weight: .medium))
            }.foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 64)
                .background(MarketPalette.accent.opacity(enabled ? 0.85 : 0.25), in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).disabled(!enabled)
            .confirmationDialog("选择平仓方向", isPresented: $chooseCloseSide) {
                if let p = session.snapshot?.positions.first(where: { $0.symbol == selected?.symbol }) {
                    Button("平多") { beginClose(p, long: true) }.disabled((availableToClose(true) ?? 0) <= 0)
                    Button("平空") { beginClose(p, long: false) }.disabled((availableToClose(false) ?? 0) <= 0)
                }
                Button("取消", role: .cancel) {}
            }
    }
    private func closeActionButton(long: Bool) -> some View {
        let tint = long ? MarketPalette.down : MarketPalette.up
        let position = session.snapshot?.positions.first { $0.symbol == selected?.symbol }
        let available = availableToClose(long)
        let enabled = session.canTrade && (available ?? 0) > 0 && selected?.hasMetadata == true
        let title = selected?.isOption == true ? (long ? "卖平" : "买平") : (long ? "平多" : "平空")
        return Button {
            guard enabled, let position else { return }
            beginClose(position, long: long)
        } label: {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(available.map { "可平 \($0)" } ?? "可平 --").font(.caption2)
            }
            .foregroundStyle(tint.opacity(enabled ? 1 : 0.45))
            .frame(maxWidth: .infinity).frame(height: 35)
            .background(MarketPalette.surface, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(tint.opacity(enabled ? 0.8 : 0.2)))
        }.buttonStyle(.plain).disabled(!enabled)
    }
    private func quoteLine(_ title: String, _ value: Double?, volume: Double? = nil) -> some View {
        Button {
            if let value, value.isFinite, value > 0 { priceMode = .limit; selectedPrice = priceText(value) }
        } label: {
            HStack(spacing: 3) {
                Text(title).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(value.map { $0.formatted() } ?? "--").foregroundStyle(quoteColor(value))
                if let volume { Text(volume.formatted()).foregroundStyle(.secondary) }
            }.font(.system(size: 12)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }.buttonStyle(.plain).disabled(value == nil)
    }
    private func priceButton(_ title: String, _ value: Double?) -> some View {
        Button {
            if let value, value.isFinite, value > 0 { priceMode = .limit; selectedPrice = priceText(value) }
        } label: {
            VStack(spacing: 4) {
                Text(title).font(quickOnly ? .caption : .caption2).foregroundStyle(quickOnly ? MarketPalette.muted : Color.secondary)
                Text(value.map { $0.formatted() } ?? "--").font(quickOnly ? .title3.weight(.semibold) : .subheadline.weight(.medium)).monospacedDigit().foregroundStyle(quoteColor(value))
            }.frame(maxWidth: .infinity).padding(.vertical, 7)
        }.buttonStyle(.borderless).disabled(value == nil)
    }
    private func tradeButton(_ action: String, color: Color, title: String? = nil) -> some View {
        Button {
            guard validOrder(action), let c = selected, let price = effectivePrice(buy: action == "开多") else { return }
            IndicatorKeyboard.dismiss()
            openingDraft = OpeningDraft(symbol: c.symbol, action: action, title: title ?? openingTitle(action), price: priceText(price), quantity: selectedQuantity)
            quickConfirmationError = nil
            pendingAction = action
            if quickOnly { showQuickConfirmation = true }
        } label: {
            VStack(spacing: 3) {
                Text(priceText(effectivePrice(buy: action == "开多"))).font(.system(size: quickOnly ? 26 : 22, weight: .semibold).monospacedDigit())
                Text(title ?? (selected?.option != nil ? (action == "开多" ? "买开" : "卖开") : action))
            }.font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: quickOnly ? 76 : 64)
                .background(color.opacity(validOrder(action) ? 0.85 : 0.25), in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.borderless).disabled(!validOrder(action))
    }
    private func stepPrice(_ delta: Int) {
        guard let c = selected, let t = c.tick, t.isFinite, t > 0, let p = (priceMode == .limit ? Double(selectedPrice) : c.last), p.isFinite else { return }
        let next = ((p / t).rounded() + Double(delta)) * t
        if next > 0 { priceMode = .limit; selectedPrice = priceText(next) }
    }
    private func choose(_ c: PaperContract) {
        detailedQuote = nil; optionQuote = nil; expandedHolding = nil
        selected = c; selectedPrice = c.last.flatMap { $0.isFinite && $0 > 0 ? String($0) : nil } ?? ""
        priceMode = .opponent; selectedQuantity = 1; closeToday = false; quoteStamp = nil; quoteError = false; selectionRequest = UUID()
    }
    // A display-only seed must never authorize a new order or reuse another
    // month's prices. The existing network refresh supplies tradable metadata.
    private func seedHoldingQuote(_ c: PaperContract) {
        let cached = recentTradeQuotes[c.symbol].flatMap {
            Date().timeIntervalSince($0.received) <= 30 ? $0 : nil
        }
        if let cached {
            detailedQuote = cached.details
            optionQuote = cached.optionDetails
            let q = cached.contract
            selected = PaperContract(symbol: c.symbol, name: c.name, tick: nil, multiplier: nil,
                                     last: q.last, bid: q.bid, ask: q.ask, option: c.option)
        }
        if c.option == nil, let p = product(c.symbol), let q = liveMainQuotes[p.id],
           q.code == c.symbol, let last = q.last, last.isFinite, last > 0 {
            selected = PaperContract(symbol: c.symbol, name: c.name, tick: nil, multiplier: nil,
                                     last: last, bid: q.bid, ask: q.ask, option: nil)
            detailedQuote = MarketDataService.ContractQuote(
                code: q.code, month: q.month, last: q.last, settlement: q.settlement,
                bid: q.bid, ask: q.ask, volume: q.volume, interest: q.interest,
                priceTick: nil, volumeMultiple: nil, bidVolume: q.bidVolume, askVolume: q.askVolume,
                opening: q.opening, highest: q.highest, lowest: q.lowest,
                upperLimit: cached?.details?.upperLimit, lowerLimit: cached?.details?.lowerLimit, time: q.time)
        }
    }
    private func product(_ symbol: String) -> FuturesInstrument? {
        catalog.filter { symbol.hasPrefix($0.id) }.max { $0.id.count < $1.id.count }
    }
    private func contractName(_ symbol: String) -> String {
        guard let p = product(symbol) else { return symbol }
        let suffix = String(symbol.dropFirst(p.id.count))
        if symbol.hasPrefix("CZCE."), suffix.count >= 3 {
            let digits = suffix.prefix(while: { $0.isNumber })
            if digits.count == 3, let yearDigit = digits.first?.wholeNumberValue {
                let calendar = Calendar(identifier: .gregorian)
                let year = calendar.component(.year, from: Date())
                let decade = year / 10 * 10
                let candidates = [decade - 10 + yearDigit, decade + yearDigit, decade + 10 + yearDigit]
                let contractYear = candidates.min { abs($0-year) < abs($1-year) } ?? year
                return p.name + String(format: "%02d", contractYear % 100) + String(suffix.dropFirst())
            }
        }
        return p.name + suffix
    }
    private func holdingContract(_ symbol: String) -> PaperContract {
        // Exchange option symbols use C/P with an optional hyphen before/after it.
        let pattern = #"^([A-Za-z]+\.[A-Za-z]+[0-9]{3,4})-?([CPcp])-?([0-9]+(?:\.[0-9]+)?)$"#
        var option: PaperOptionDetails?
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: symbol, range: NSRange(symbol.startIndex..., in: symbol)),
           let u = Range(match.range(at: 1), in: symbol),
           let side = Range(match.range(at: 2), in: symbol),
           let strikeRange = Range(match.range(at: 3), in: symbol),
           let strike = Double(symbol[strikeRange]), strike > 0 {
            option = PaperOptionDetails(underlying: String(symbol[u]), side: symbol[side].uppercased() == "C" ? "CALL" : "PUT", strike: strike)
        }
        return PaperContract(symbol: symbol, name: product(symbol)?.name ?? contractName(symbol), tick: nil, multiplier: nil, last: nil, bid: nil, ask: nil, option: option)
    }

    private func selectHolding(_ symbol: String) {
        if selected?.symbol == symbol { priceMode = .opponent; selectionRequest = UUID(); return }
        let contract = holdingContract(symbol)
        choose(contract)
        seedHoldingQuote(contract)
    }

    private var heldSymbols: [String] {
        Array(Set((session.snapshot?.positions ?? []).filter { $0.long > 0 || $0.short > 0 }.map { $0.symbol })).sorted()
    }

    @MainActor private func warmHoldingQuotes(_ symbols: [String]) async {
        // Futures use exact symbols; options retain grouped underlying queries.
        let contracts = symbols.filter { $0 != selected?.symbol }.map { holdingContract($0) }
        let futures = contracts.filter { $0.option == nil }
        let options = Dictionary(grouping: contracts.filter { $0.option != nil }) { $0.option?.underlying ?? "" }
        for item in futures {
            guard !Task.isCancelled, session.signedIn else { return }
            do {
                let q = try await MarketDataService.contractQuote(symbol: item.symbol)
                guard !Task.isCancelled, session.signedIn else { return }
                let contract = PaperContract(symbol: q.code, name: item.name, tick: q.priceTick, multiplier: q.volumeMultiple, last: q.last, bid: q.bid, ask: q.ask)
                recentTradeQuotes[item.symbol] = CachedTradeQuote(contract: contract, details: q, optionDetails: nil, received: Date())
            } catch { /* Selected-contract refresh remains independent. */ }
        }
        for (underlying, items) in options.sorted(by: { $0.key < $1.key }) {
            guard !Task.isCancelled, session.signedIn else { return }
            guard !underlying.isEmpty else { continue }
            do {
                let quotes = try await MarketDataService.options(for: underlying)
                guard !Task.isCancelled, session.signedIn else { return }
                let received = Date()
                for item in items {
                    guard let q = quotes.first(where: { $0.code == item.symbol }) else { continue }
                    recentTradeQuotes[item.symbol] = CachedTradeQuote(contract: q.paperContract(underlying: underlying, name: item.name), details: nil, optionDetails: q, received: received)
                }
            } catch { /* Keep any existing display cache until expiry. */ }
        }
        recentTradeQuotes = recentTradeQuotes.filter { Date().timeIntervalSince($0.value.received) <= 30 }
    }
    @MainActor private func refreshQuote(_ c: PaperContract, request: UUID) async {
        do {
            let next: PaperContract
            var details: MarketDataService.ContractQuote?
            var optionDetails: MarketDataService.OptionQuote?
            if let option = c.option {
                let q = try await MarketDataService.optionQuote(symbol: c.symbol, underlying: option.underlying)
                optionDetails = q
                next = q.paperContract(underlying: option.underlying, name: c.name)
            } else {
                guard let p = product(c.symbol) else { throw MarketDataError.noData }
                let q = try await MarketDataService.contractQuote(symbol: c.symbol)
                details = q
                next = PaperContract(symbol: q.code, name: p.name, tick: q.priceTick, multiplier: q.volumeMultiple, last: q.last, bid: q.bid, ask: q.ask)
            }
            guard !Task.isCancelled, selectionRequest == request, selected?.symbol == c.symbol else { return }
            guard next.symbol == c.symbol, next.hasMetadata else { throw MarketDataError.noData }
            let received = Date()
            recentTradeQuotes = recentTradeQuotes.filter { received.timeIntervalSince($0.value.received) <= 30 }
            recentTradeQuotes[c.symbol] = CachedTradeQuote(contract: next, details: details, optionDetails: optionDetails, received: received)
            let previousTime = detailedQuote?.time
            optionQuote = optionDetails
            if let previous = previousTime, let incoming = details?.time, incoming < previous, let current = selected, current.symbol == next.symbol {
                selected = PaperContract(symbol: next.symbol, name: next.name, tick: next.tick, multiplier: next.multiplier, last: current.last, bid: current.bid, ask: current.ask, option: next.option)
            } else { selected = next; detailedQuote = details }
            quoteStamp = received; quoteError = false
            if selectedPrice.isEmpty, let last = next.last, last > 0 { selectedPrice = String(last) }
            // Close confirmation price is user controlled; never replace it on a quote update.
        } catch {
            guard !Task.isCancelled, selectionRequest == request, selected?.symbol == c.symbol else { return }
            recentTradeQuotes.removeValue(forKey: c.symbol)
            detailedQuote = nil
            optionQuote = nil
            quoteError = true
            selected = PaperContract(symbol: c.symbol, name: c.name, tick: c.tick, multiplier: c.multiplier, last: nil, bid: nil, ask: nil, option: c.option)
        }
    }
    private var recordsPanel: some View {
        VStack(spacing: 5) {
            HStack(spacing: 0) {
                ForEach(["持仓","挂单","委托","成交"], id: \.self) { item in
                    Button { tab = item; expandedHolding = nil } label: {
                        VStack(spacing: 5) {
                            Text(item).font(.subheadline.weight(tab == item ? .semibold : .regular))
                                .foregroundStyle(tab == item ? MarketPalette.ink : MarketPalette.muted)
                            Rectangle().fill(tab == item ? MarketPalette.accent : Color.clear).frame(width: 30, height: 2)
                        }.frame(maxWidth: .infinity).padding(.top, 5)
                    }.buttonStyle(.plain)
                }
            }
            Divider()
            ScrollView {
            LazyVStack(spacing: 0) {
            if session.snapshot == nil {
                Text("账户数据暂不可用").font(.caption).foregroundStyle(.secondary)
                if tab == "持仓" { positionSummaryUnavailable }
            } else if tab == "持仓" {
                HStack(spacing: 4) {
                    Text("合约 / 多空").frame(maxWidth: .infinity, alignment: .leading)
                    Text("手数 / 可平").frame(width: 65)
                    Text("开仓均价").frame(width: 67, alignment: .trailing)
                    Text("浮盈").frame(width: 65, alignment: .trailing)
                }.font(.system(size: 12)).foregroundStyle(.secondary)
                ForEach(session.snapshot?.positions ?? []) { p in
                    if p.long > 0 { positionRow(p, long: true) }
                    if p.short > 0 { positionRow(p, long: false) }
                }
                if let snapshot = session.snapshot {
                    let held = snapshot.positions.filter { $0.long > 0 || $0.short > 0 }
                    if held.isEmpty {
                        Text("暂无持仓").font(.caption).foregroundStyle(.secondary)
                    }
                    positionSummary(held)
                }
            } else if tab == "成交" {
                HStack(spacing: 3) {
                    recordCell("合约")
                    recordCell("开平", width: 34)
                    recordCell("成交价", width: 53)
                    recordCell("手数", width: 28)
                    recordCell("时间", width: 63)
                }.foregroundStyle(.secondary)
                Divider()
                ForEach((session.snapshot?.fills ?? []).sorted { $0.time_ns > $1.time_ns }) { f in
                    HStack(spacing: 3) {
                        recordCell(contractName(f.symbol))
                        recordCell(recordAction(f.direction, f.offset), width: 34)
                            .foregroundStyle(f.direction == "BUY" ? MarketPalette.up : MarketPalette.down)
                        recordCell(f.price?.formatted() ?? "--", width: 53)
                        recordCell(String(f.quantity), width: 28)
                        recordCell(recordTime(f.time_ns), width: 63)
                    }.padding(.vertical, 10)
                    if let profit = f.calculated_close_profit, profit.isFinite, f.offset != "OPEN" {
                        HStack {
                            Spacer()
                            Text("平仓盈亏（计算）")
                                .foregroundStyle(MarketPalette.muted)
                            Text(money(profit, suffix: false))
                                .foregroundStyle(MarketPalette.movement(profit))
                                .monospacedDigit()
                        }.font(.caption2).padding(.bottom, 6)
                    }
                    Divider()
                }
                if session.snapshot?.fills?.isEmpty != false { Text("暂无成交或未取得数据").font(.caption).foregroundStyle(.secondary) }
            } else {
                let orders = (session.snapshot?.orders ?? []).filter { tab != "挂单" || $0.status == "ALIVE" }.sorted {
                    ($0.time_ns ?? 0) == ($1.time_ns ?? 0) ? $0.id > $1.id : ($0.time_ns ?? 0) > ($1.time_ns ?? 0)
                }
                HStack(spacing: 3) {
                    recordCell("合约")
                    recordCell("状态", width: 40)
                    recordCell("开平", width: 30)
                    recordCell("委托价", width: 48)
                    recordCell("数量", width: 30)
                    recordCell(tab == "挂单" ? "操作" : "时间", width: tab == "挂单" ? 38 : 58)
                }.foregroundStyle(.secondary)
                Divider()
                ForEach(orders) { o in
                    HStack(spacing: 3) {
                        let canCancel = tab == "挂单" && o.status == "ALIVE" && !session.isLive
                        Button { orderDetail = o } label: {
                            HStack(spacing: 3) {
                                recordCell(contractName(o.symbol))
                                recordCell(o.stateText, width: 40)
                                recordCell(recordAction(o.direction, o.offset), width: 30)
                                    .foregroundStyle(o.direction == "BUY" ? MarketPalette.up : MarketPalette.down)
                                recordCell(o.price?.formatted() ?? "--", width: 48)
                                recordCell(String(o.quantity - o.remaining) + "/" + String(o.quantity), width: 30)
                                if !canCancel {
                                    recordCell(recordTime(o.time_ns), width: tab == "挂单" ? 38 : 58)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("查看委托详情及原始回报")
                        if canCancel {
                            Button("撤单", role: .destructive) { cancelID = o.id }
                                .font(.caption2).buttonStyle(.borderless).frame(width: 38).disabled(session.busy)
                        }
                    }.padding(.vertical, 10)
                    Divider()
                }
                if orders.isEmpty { Text(tab == "挂单" ? "暂无挂单" : "暂无委托或未取得数据").font(.caption).foregroundStyle(.secondary) }
            }
            }
            }
        }.padding(.top, 5).frame(maxHeight: .infinity, alignment: .top)
    }

    private func orderDetailSheet(_ initial: CloudSnapshot.Order) -> some View {
        let order = session.snapshot?.orders?.first(where: { $0.id == initial.id }) ?? initial
        let rejected = order.display_state == "REJECTED"
        let message = order.message.trimmingCharacters(in: .whitespacesAndNewlines)
        return NavigationStack {
            Form {
                Section("委托信息") {
                    LabeledContent("合约", value: contractName(order.symbol))
                    LabeledContent("合约代码", value: order.symbol)
                    LabeledContent("方向", value: recordAction(order.direction, order.offset))
                    LabeledContent("状态", value: order.stateText)
                    LabeledContent("委托价", value: order.price?.formatted() ?? "--")
                    LabeledContent("委托手数", value: String(order.quantity))
                    LabeledContent("成交手数", value: String(order.quantity - order.remaining))
                    LabeledContent("未成交手数", value: String(order.remaining))
                    if ["CANCELED", "PARTIAL_CANCELED"].contains(order.display_state ?? "") { LabeledContent("已撤手数", value: String(order.remaining)) }
                    if order.quantity > order.remaining, let price = order.trade_price, price.isFinite, price > 0 { LabeledContent("成交均价", value: price.formatted()) }
                    LabeledContent("委托时间（北京时间）", value: orderDetailTime(order.time_ns))
                }
                Section(rejected ? "拒单原因 / 原始回报" : "原始回报") {
                    Text(message.isEmpty ? "交易网关未提供具体原因，请在快期委托记录中核对。" : message)
                        .foregroundStyle(rejected ? MarketPalette.up : MarketPalette.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section("委托编号") {
                    Text(order.id).font(.caption).textSelection(.enabled)
                }
            }
            .scrollContentBackground(.hidden)
            .background(MarketPalette.background)
            .navigationTitle("委托详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { orderDetail = nil }
                }
            }
        }
        .presentationDetents([.large])
        .tint(MarketPalette.accent)
    }
    private func orderDetailTime(_ ns: Int64?) -> String {
        guard let ns, ns > 0 else { return "--" }
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: Double(ns) / 1e9))
    }

    private func recordCell(_ value: String, width: CGFloat? = nil) -> some View {
        Text(value).font(.system(size: 13)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
    private func recordAction(_ direction: String, _ offset: String) -> String {
        (direction == "BUY" ? "买" : "卖") + (offset == "OPEN" ? "开" : (offset == "CLOSETODAY" ? "平今" : "平"))
    }
    private func recordTime(_ ns: Int64?) -> String {
        guard let ns, ns > 0 else { return "--" }
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: Double(ns) / 1e9))
    }
    private func beginClose(_ p: CloudSnapshot.Position, long: Bool) {
        IndicatorKeyboard.dismiss()
        if selected?.symbol != p.symbol { selectHolding(p.symbol) }
        closePrice = effectivePrice(buy: !long).map { priceText($0) } ?? ""
        closeQuantity = min(max(1, selectedQuantity), availableToClose(long) ?? 0)
        closeToday = false
        closeConfirm = false
        closingSide = long
    }
    private func availableToClose(_ long: Bool) -> Int? {
        guard let symbol = selected?.symbol,
              let p = session.snapshot?.positions.first(where: { $0.symbol == symbol }),
              let frozen = long ? p.frozen_long : p.frozen_short else { return nil }
        return max(0, (long ? p.long : p.short) - frozen)
    }
    private func validClose(_ long: Bool) -> Bool {
        guard (!quickOnly || selected?.option != nil), closingSide == long, session.canTrade,
              !quoteError, let stamp = quoteStamp, Date().timeIntervalSince(stamp) < 60,
              let available = availableToClose(long), closingQuantityAllowed(closeQuantity),
              closeQuantity <= available, let tick = selected?.tick, tick.isFinite, tick > 0,
              let price = Double(closePrice), price.isFinite, price > 0 else { return false }
        let steps = price / tick
        return steps.isFinite && abs(steps - steps.rounded()) < 0.00001
    }
    private func closingBar(_ long: Bool) -> some View {
        let available = availableToClose(long)
        let title = long ? "卖出平多" : "买入平空"
        return VStack(alignment: .leading, spacing: 10) {
            Text(selected.map { contractName($0.symbol) } ?? "--").font(.headline)
            Text((long ? "多头持仓" : "空头持仓") + " · 可平 " + (available.map { String($0) } ?? "--") + " 手").font(.caption)
            if !closeConfirm {
                HStack {
                    Button("买一 " + (selected?.bid.map { $0.formatted() } ?? "--")) {
                        if let v = selected?.bid { closePrice = String(v) }
                    }.buttonStyle(.borderless)
                    Spacer()
                    Button("卖一 " + (selected?.ask.map { $0.formatted() } ?? "--")) {
                        if let v = selected?.ask { closePrice = String(v) }
                    }.buttonStyle(.borderless)
                }.font(.caption)
                HStack {
                    Text("平仓价格")
                    TextField("限价", text: $closePrice).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("平仓手数")
                    TextField("手数", value: $closeQuantity, format: .number.grouping(.never)).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    Button("最多") { closeQuantity = available ?? 0 }.buttonStyle(.borderless).disabled((available ?? 0) <= 0)
                }
                if requiresSplit {
                    Picker("平仓类型", selection: $closeToday) {
                        Text("平昨").tag(false)
                        Text("平今").tag(true)
                    }.pickerStyle(.segmented)
                    Text("平今/平昨具体可平量以柜台回报为准").font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text("\(title) \(closeQuantity) 手 @ \(closePrice)").monospacedDigit()
                if requiresSplit { Text(closeToday ? "平今" : "平昨").font(.caption) }
            }
            HStack {
                Button("取消") { closingSide = nil; closeConfirm = false }.buttonStyle(.bordered).frame(maxWidth: .infinity)
                Button(closeConfirm ? "确认" + title : title) {
                    IndicatorKeyboard.dismiss()
                    if closeConfirm { submitClose(long) } else { closeConfirm = true }
                }.buttonStyle(.borderedProminent).tint(long ? MarketPalette.down : MarketPalette.up)
                    .frame(maxWidth: .infinity).disabled(!validClose(long))
            }
        }.padding(16).background(MarketPalette.raised)
    }
    private func submitClose(_ long: Bool) {
        guard validClose(long), let c = selected else { return }
        let direction = long ? "SELL" : "BUY"
        let offset = requiresSplit && closeToday ? "CLOSETODAY" : "CLOSE"
        let price = closePrice, qty = String(closeQuantity)
        closingSide = nil; closeConfirm = false; tab = "委托"
        Task { await session.submit(symbol: c.symbol, direction: direction, offset: offset, price: price, quantity: qty) }
    }
    private func cancelConfirmationBar(_ id: String) -> some View {
        let order = session.snapshot?.orders?.first(where: { $0.id == id })
        return VStack(alignment: .leading, spacing: 12) {
            Text("确认撤销模拟委托").font(.headline)
            if let order {
                Text(contractName(order.symbol) + " · " + actionName(order.direction, order.offset))
                Text(orderQuantityText(order)).font(.subheadline).monospacedDigit()
            } else {
                Text("委托状态暂不可用").font(.subheadline)
            }
            HStack(spacing: 12) {
                Button("取消") { cancelID = nil }.buttonStyle(.bordered).frame(maxWidth: .infinity)
                Button("确认撤单", role: .destructive) {
                    cancelID = nil
                    Task { await session.cancel(id) }
                }.buttonStyle(.borderedProminent).tint(.red).frame(maxWidth: .infinity)
                    .disabled(order?.status != "ALIVE" || session.busy)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MarketPalette.raised)
        .overlay(alignment: .top) { Divider() }
    }
    private func orderConfirmationBar(_ action: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("确认模拟委托").font(.headline)
            Text(orderConfirmationText(action)).font(.subheadline).monospacedDigit()
            HStack(spacing: 12) {
                Button("取消") { pendingAction = nil; openingDraft = nil }
                    .buttonStyle(.bordered).frame(maxWidth: .infinity)
                Button("确认" + (openingDraft?.title ?? openingTitle(action))) { submitConfirmed(action) }
                    .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                    .disabled(!validDraft(action))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MarketPalette.raised)
        .overlay(alignment: .top) { Divider() }
    }
    private func submitConfirmed(_ action: String) {
        guard pendingAction == action, let draft = openingDraft, validDraft(action) else { return }
        let direction = action == "开多" ? "BUY" : "SELL"
        pendingAction = nil; openingDraft = nil; tab = "委托"
        Task { await session.submit(symbol: draft.symbol, direction: direction, offset: "OPEN", price: draft.price, quantity: String(draft.quantity)) }
    }
    private func openingTitle(_ action: String) -> String {
        selected?.option != nil ? (action == "开多" ? "买开" : "卖开") : action
    }
    private func orderConfirmationText(_ action: String) -> String {
        guard let draft = openingDraft, draft.action == action else { return "委托信息不可用" }
        return "\(contractName(draft.symbol)) \(draft.title) \(draft.quantity) 手 @ \(draft.price)"
    }
    private func fillQuantityText(_ fill: CloudSnapshot.Fill) -> String {
        let price = fill.price?.formatted() ?? "--"
        return "\(price) × \(fill.quantity)"
    }
    private func orderQuantityText(_ order: CloudSnapshot.Order) -> String {
        let price = order.price?.formatted() ?? "--"
        let filled = order.quantity - order.remaining
        return "\(price) · \(filled)/\(order.quantity)手"
    }
    private var positionSummaryUnavailable: some View {
        positionSummaryBar(lots: nil, closable: nil, profit: nil)
    }
    private func positionSummary(_ positions: [CloudSnapshot.Position]) -> some View {
        let lots = positions.reduce(0) { $0 + $1.long + $1.short }
        var closable = 0
        var completeClosable = true
        var profit = 0.0
        var completeProfit = true
        for p in positions {
            for long in [true, false] {
                let qty = long ? p.long : p.short
                guard qty > 0 else { continue }
                if let frozen = long ? p.frozen_long : p.frozen_short {
                    closable += max(0, qty - frozen)
                } else { completeClosable = false }
                let sideProfit = (long ? p.float_profit_long : p.float_profit_short)
                    ?? ((p.long == 0 || p.short == 0) ? p.float_profit : nil)
                if let sideProfit, sideProfit.isFinite {
                    profit += sideProfit
                } else { completeProfit = false }
            }
        }
        let totalProfit: Double? = completeProfit && profit.isFinite ? profit : nil
        return positionSummaryBar(lots: lots,
                                  closable: completeClosable ? closable : nil, profit: totalProfit)
    }
    private func positionSummaryBar(lots: Int?, closable: Int?, profit: Double?) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 4) {
                Text("合计").frame(maxWidth: .infinity, alignment: .leading)
                Text((lots.map { String($0) } ?? "--") + "/" + (closable.map { String($0) } ?? "--"))
                    .lineLimit(1).minimumScaleFactor(0.65).frame(width: 65)
                Text("—").frame(width: 67, alignment: .trailing).foregroundStyle(MarketPalette.muted)
                Text(money(profit, suffix: false))
                    .foregroundStyle(MarketPalette.movement(profit))
                    .lineLimit(1).minimumScaleFactor(0.65)
                    .frame(width: 65, alignment: .trailing)
            }
            .font(.system(size: 14, weight: .semibold)).monospacedDigit().foregroundStyle(MarketPalette.ink)
            .padding(.vertical, 9)
        }
    }
    private func positionRow(_ p: CloudSnapshot.Position, long: Bool) -> some View {
        let qty = long ? p.long : p.short
        let frozen = long ? p.frozen_long : p.frozen_short
        let average = long ? p.open_price_long : p.open_price_short
        let profit = (long ? p.float_profit_long : p.float_profit_short) ?? ((p.long == 0 || p.short == 0) ? p.float_profit : nil)
        let rowID = p.symbol + (long ? "/long" : "/short")
        let expanded = expandedHolding == rowID
        return VStack(spacing: 0) {
        Button {
            if expanded { expandedHolding = nil; selectedQuantity = 1 } else {
                selectHolding(p.symbol)
                expandedHolding = rowID
                selectedQuantity = frozen.map { max(0, qty - $0) } ?? 1
            }
        } label: {
            HStack(spacing: 4) {
                HStack(spacing: 3) {
                    Text(contractName(p.symbol)).font(.system(size: 13, weight: .medium)).lineLimit(1).minimumScaleFactor(0.75)
                    Text(long ? "多" : "空").font(.system(size: 12)).foregroundStyle(long ? MarketPalette.up : MarketPalette.down)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text(String(qty) + "/" + (frozen.map { String(max(0, qty-$0)) } ?? "--")).frame(width: 65)
                Text(average.map { $0.formatted() } ?? "--").frame(width: 67, alignment: .trailing)
                Text(money(profit, suffix: false)).foregroundStyle(MarketPalette.movement(profit)).frame(width: 65, alignment: .trailing)
            }.font(.system(size: 14)).monospacedDigit().foregroundStyle(MarketPalette.ink).lineLimit(1).minimumScaleFactor(0.65)
        }.buttonStyle(.borderless).padding(.vertical, 8)
        if expanded {
            let margin = long ? p.margin_long : p.margin_short
            let value = long ? p.market_value_long : p.market_value_short
            if margin != nil || value != nil {
                HStack {
                    if let margin { Text("保证金 " + money(margin)) }
                    Spacer()
                    if let value { Text("市值 " + money(value)) }
                }.font(.caption2).foregroundStyle(MarketPalette.muted).padding(.bottom, 5)
            }
            HStack(spacing: 10) {
                Spacer()
                if let q = detailedQuote, q.code == p.symbol, let product = product(p.symbol) {
                    Button("查看K线") { chartProduct = product; chartQuote = q; showHoldingChart = true }
                        .buttonStyle(.bordered)
                }
                Button("平仓") { beginClose(p, long: long) }
                    .buttonStyle(.bordered).disabled(!session.canTrade || frozen == nil || qty <= (frozen ?? qty))
            }.font(.caption).padding(.bottom, 8)
        }
        Divider()
        }.background(expanded ? MarketPalette.raised : Color.clear)
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


struct TradeConnectionSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form { TradeConnectionFields() }
                .navigationTitle("交易设置").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }.tint(MarketPalette.accent)
    }
}

struct TradeConnectionFields: View {
    @ObservedObject private var session = CloudTradeSession.shared
    @AppStorage("qihui.trade.endpoint.v1") private var address = "https://8.153.96.190"
    @AppStorage("qihui.trade.default-mode.v1") private var defaultMode = "simulation"
    @AppStorage("qihui.trade.live-endpoint.v1") private var savedLiveEndpoint = ""
    @State private var draftAddress = ""
    @State private var username = ""
    @State private var password = ""
    @State private var key = ""
    @State private var liveAddress = ""
    @State private var liveUsername = ""
    @State private var livePassword = ""
    @State private var liveKey = ""
    @State private var message: String?
    var body: some View {
        Group {
                Section("账户状态") {
                    LabeledContent("交易模式", value: session.signedIn ? (session.isLive ? "实盘只读" : "快期云端模拟") : "未连接")
                    LabeledContent("登录状态", value: session.signedIn ? "已登录" : "未登录")
                    if session.signedIn {
                        Button("退出账户", role: .destructive) {
                            Task { await session.logout(); loadSaved() }
                        }.disabled(session.busy)
                    }
                }
                Section("默认交易模式") {
                    Picker("默认登录", selection: $defaultMode) {
                        Text("模拟交易").tag("simulation")
                        Text("实盘只读").tag("live_readonly")
                    }.pickerStyle(.segmented)
                }.disabled(session.signedIn || session.busy)
                Group {
                    Section("银河期货 · 实盘只读") {
                        TextField("独立 HTTPS 实盘网关", text: $liveAddress).keyboardType(.URL)
                        TextField("快期用户名", text: $liveUsername)
                        SecureField("快期密码", text: $livePassword)
                        SecureField("实盘网关访问密钥", text: $liveKey)
                        Text("仅查询账户，不支持下单及撤单。凭据仅保存在本机钥匙串。").font(.caption)
                        Button("连接实盘只读账户") {
                            session.allowManualLogin()
                            Task {
                                await session.login(address: liveAddress, key: liveKey, username: liveUsername, password: livePassword, mode: "live_readonly")
                                if session.signedIn && session.isLive {
                                    let results = [TradeKeychain.save(liveKey, address: liveAddress), TradeKeychain.save(liveUsername, address: liveAddress, kind: "username"), TradeKeychain.save(livePassword, address: liveAddress, kind: "password")]
                                    if results.allSatisfy({ $0 }) { savedLiveEndpoint = liveAddress; defaultMode = "live_readonly"; message = "实盘只读配置已保存" }
                                    else { message = "安全存储失败" }
                                }
                                livePassword = ""; liveKey = ""
                            }
                        }.disabled(liveAddress.isEmpty || liveAddress == address || liveUsername.isEmpty || livePassword.isEmpty || liveKey.isEmpty)
                    }.disabled(session.signedIn || session.busy)
                }
                Group {
                    Section("快期账户") {
                        TextField("手机号 / 用户名", text: $username)
                        SecureField("快期账户密码", text: $password)
                    }.disabled(session.signedIn || session.busy)
                    Section("交易网关") {
                        TextField("HTTPS 网关地址", text: $draftAddress).keyboardType(.URL)
                        SecureField("网关访问密钥", text: $key)
                        Text("模拟账户登录成功后，密码、密钥及会话保存在本机钥匙串，交易入口自动恢复。").font(.caption)
                        Button("保存并连接") {
                            let target = draftAddress.trimmingCharacters(in: .whitespacesAndNewlines)
                            let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
                            session.allowManualLogin()
                            Task {
                                await session.login(address: target, key: key, username: user, password: password)
                                if session.signedIn && !session.isLive {
                                    defaultMode = "simulation"
                                    address = target
                                    message = "账户已连接"
                                    password = ""; key = ""
                                }
                            }
                        }.disabled(draftAddress.isEmpty || username.isEmpty || password.isEmpty || key.isEmpty)
                        Button("清除已保存登录信息", role: .destructive) {
                            let results = ["gateway", "username", "password", "session"].map { TradeKeychain.remove(address, kind: $0) }
                            message = results.allSatisfy { $0 } ? "已清除登录信息" : "部分登录信息清除失败"
                            loadSaved()
                        }
                    }.disabled(session.signedIn || session.busy)
                }
                if session.busy { ProgressView("正在连接") }
                if let error = session.error { Text(error).foregroundStyle(.red).font(.caption) }
                if let message { Text(message).font(.caption) }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onAppear { loadSaved() }
            .onDisappear { password = ""; key = ""; livePassword = ""; liveKey = "" }
    }
    private func loadSaved() {
        draftAddress = address
        liveAddress = savedLiveEndpoint
        liveUsername = TradeKeychain.load(liveAddress, kind: "username")
        livePassword = TradeKeychain.load(liveAddress, kind: "password")
        liveKey = TradeKeychain.load(liveAddress)
        username = TradeKeychain.load(address, kind: "username")
        password = TradeKeychain.load(address, kind: "password")
        key = TradeKeychain.load(address)
    }
}
