
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
        let commission: Double?
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
    private var trackedOrderID: String?
    private var trackedFeedbackKey: String?
    private var feedbackTask: Task<Void, Never>?
    @Published private(set) var lastFilledOrderID: String?
    private func showFeedback(_ message: String, transient: Bool = false) {
        feedbackTask?.cancel()
        actionMessage = message
        guard transient else { return }
        feedbackTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self, self.actionMessage == message, self.pendingOrder == nil else { return }
            self.actionMessage = nil
        }
    }
    private func reconcile(_ data: CloudSnapshot) {
        if let id = awaitingCancelID, let order = data.orders?.first(where: { $0.id == id }), order.status == "FINISHED" {
            awaitingCancelID = nil
            showFeedback("委托状态：" + order.stateText, transient: order.display_state == "CANCELED" || order.display_state == "PARTIAL_CANCELED" || order.display_state == "FILLED")
        }
        guard let id = pendingOrder ?? trackedOrderID,
              let order = data.orders?.first(where: { $0.id == id }) else { return }
        if pendingOrder == id { clearPending() }
        trackedOrderID = id
        let filled = max(0, order.quantity - order.remaining)
        let key = "\(id)|\(order.display_state ?? order.status)|\(filled)|\(order.message)"
        guard trackedFeedbackKey != key else { return }
        trackedFeedbackKey = key
        let prefix = "委托：" + order.symbol + " "
        switch order.display_state {
        case "FILLED" where order.quantity > 0 && order.remaining == 0:
            lastFilledOrderID = id
            trackedOrderID = nil
            showFeedback(prefix + "全部成交 \(filled)手", transient: true)
        case "PARTIAL":
            showFeedback(prefix + "部分成交 \(filled)/\(order.quantity)手", transient: true)
        case "ALIVE":
            showFeedback(prefix + "已挂单", transient: true)
        case "REJECTED":
            trackedOrderID = nil
            showFeedback(prefix + "拒单" + (order.message.isEmpty ? "" : " · " + order.message))
        case "CANCELED", "PARTIAL_CANCELED":
            trackedOrderID = nil
            showFeedback(prefix + order.stateText, transient: true)
        default:
            if order.status == "FINISHED" { trackedOrderID = nil }
            showFeedback(prefix + order.stateText + (order.message.isEmpty ? "" : " · " + order.message))
        }
    }
    private func install(_ data: CloudSnapshot, token: String, url: URL, address: String, key: String) {
        self.token = token; endpoint = url; accessKey = key; activeAddress = address
        generation = UUID()
        savedPendingAddress = address
        let unresolved = isLive ? "" : TradeKeychain.load(address, kind: "pending")
        pendingOrder = unresolved.isEmpty ? nil : unresolved
        trackedOrderID = pendingOrder; trackedFeedbackKey = nil; lastFilledOrderID = nil
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
    @discardableResult
    func submit(symbol: String, direction: String, offset: String, price: String, quantity: String) async -> String? {
        guard canTrade, let url = endpoint, let token else { return nil }
        mutating = true; busy = true
        defer { mutating = false; busy = false }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        guard !activeAddress.isEmpty, TradeKeychain.save(id, address: activeAddress, kind: "pending") else {
            showFeedback("无法保存委托保护记录，未发送委托")
            return nil
        }
        savedPendingAddress = activeAddress
        pendingOrder = id
        trackedOrderID = id; trackedFeedbackKey = nil; lastFilledOrderID = nil
        showFeedback("正在提交模拟委托")
        do {
            _ = try await request(base: url, action: "order", key: accessKey, token: token,
                                  body: ["id": id, "symbol": symbol, "direction": direction, "offset": offset, "price": price, "quantity": quantity])
            if pendingOrder == id { showFeedback("指令已交给SDK，等待委托回报") }
        } catch {
            if pendingOrder == id { showFeedback("提交结果未确认，请查看委托列表，勿重复下单。编号：" + id) }
        }
        await refresh()
        return id
    }
    func cancel(_ id: String) async {
        guard signedIn, !isLive, snapshot?.simulation_orders == true, snapshot?.maintenance != true, !busy, !mutating, let url = endpoint, let token else { return }
        mutating = true; busy = true
        defer { mutating = false; busy = false }
        do {
            _ = try await request(base: url, action: "cancel", key: accessKey, token: token, body: ["id": id])
            awaitingCancelID = id
            showFeedback("撤单指令已交给SDK，等待回报")
        } catch {
            showFeedback("撤单结果未确认，请核对委托状态")
        }
        await refresh()
    }
    func acknowledgeUncertainOrder() {
        clearPending()
        trackedOrderID = nil; trackedFeedbackKey = nil
        showFeedback("已手动解除提交锁定，请先核对快期委托记录")
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
        feedbackTask?.cancel(); actionMessage = nil; trackedOrderID = nil; trackedFeedbackKey = nil; lastFilledOrderID = nil; awaitingCancelID = nil
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
    @State private var quickSubmittedID: String?
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
                else if let action = pendingAction { orderConfirmationBar(action) }
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
            .task(id: quickFilledID) {
                guard let id = quickFilledID else { return }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard quickFilledID == id, !session.busy, pendingAction == nil, closingSide == nil else { return }
                dismiss()
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
                    pendingAction = nil; openingDraft = nil; quickSubmittedID = nil; cancelID = nil; closingSide = nil; closeConfirm = false
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
    private var quickFilledID: String? {
        guard quickOnly, !session.busy, let id = quickSubmittedID, session.lastFilledOrderID == id,
              pendingAction == nil, closingSide == nil else { return nil }
        return id
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
                        if session.isLive {
                            Text("实盘只读 · 禁止下单及撤单").font(.caption).foregroundStyle(.secondary)
                            if quickOnly { Button("退出账户") { Task { await session.logout() } } }
                        } else if quickOnly { quickOrderPanel } else { orderPanel }
                        if !quickOnly { Divider(); recordsPanel }

                    if let message = session.actionMessage { Text(message).font(.caption).foregroundStyle(MarketPalette.ink).lineLimit(3).padding(.vertical, 5) }
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
        .padding(.top, 8)
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
        HStack(spacing: 8) {
            VStack(spacing: 5) {
                accountMetric("账户权益", money(session.snapshot?.account.balance, suffix: false))
                accountMetric("可用资金", money(session.snapshot?.account.available, suffix: false))
            }
            Divider().frame(height: 34)
            VStack(spacing: 5) {
                accountMetric("持仓盈亏", money(session.snapshot?.account.float_profit, suffix: false),
                              tint: MarketPalette.movement(session.snapshot?.account.float_profit))
                accountMetric("保证金占比", usage)
            }
        }.padding(.vertical, 8)
    }
    private func accountMetric(_ label: String, _ value: String, tint: Color = MarketPalette.ink) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(MarketPalette.muted).fixedSize()
            Spacer(minLength: 0)
            Text(value).font(.system(size: 14, weight: .medium)).monospacedDigit()
                .foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.65)
        }.frame(maxWidth: .infinity)
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
        if let minimum = openingMinimum, minimum > 1, selectedQuantity < minimum {
            Text("最小开仓 \(minimum)手").font(.caption).foregroundStyle(Color.yellow)
        }
        if let maximum = openingMaximum, maximum > 0, selectedQuantity > maximum {
            Text("单笔最多开仓 \(maximum)手").font(.caption).foregroundStyle(Color.yellow)
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
                    Text(mode.rawValue).font(.caption2.weight(.medium))
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                        .foregroundStyle(priceMode == mode ? MarketPalette.accent : MarketPalette.muted)
                        .background(priceMode == mode ? MarketPalette.accent.opacity(0.12) : MarketPalette.raised, in: RoundedRectangle(cornerRadius: 4))
                }.buttonStyle(.plain)
            }
        }
    }
    private var priceInput: some View {
        HStack(spacing: 2) {
            Button { stepPrice(-1) } label: { Image(systemName: "minus").font(.system(size: 13)).frame(width: 30, height: 44) }
                .buttonStyle(.plain).disabled(selected?.tick == nil)
            if priceMode == .limit {
                TextField("限价", text: $selectedPrice).keyboardType(.decimalPad).multilineTextAlignment(.center).font(.system(size: 13)).monospacedDigit()
            } else {
                Text(priceMode.rawValue).font(.system(size: 13)).lineLimit(1).frame(maxWidth: .infinity)
            }
            Button { stepPrice(1) } label: { Image(systemName: "plus").font(.system(size: 13)).frame(width: 30, height: 44) }
                .buttonStyle(.plain).disabled(selected?.tick == nil)
        }.frame(height: 44).overlay(RoundedRectangle(cornerRadius: 6).stroke(MarketPalette.divider))
    }
    private var quantityInput: some View {
        HStack(spacing: 2) {
            Button { if selectedQuantity > 1 { selectedQuantity -= 1 } else { selectedQuantity = 1 } } label: {
                Image(systemName: "minus").font(.system(size: 13)).frame(width: 30, height: 44)
            }.buttonStyle(.plain).accessibilityLabel("减少手数")
            TextField("手数", value: $selectedQuantity, format: .number.grouping(.never))
                .keyboardType(.numberPad).multilineTextAlignment(.center).font(.system(size: 13)).monospacedDigit()
            Button { if selectedQuantity < Int.max { selectedQuantity += 1 } } label: {
                Image(systemName: "plus").font(.system(size: 13)).frame(width: 30, height: 44)
            }.buttonStyle(.plain).accessibilityLabel("增加手数")
        }.frame(height: 44).overlay(RoundedRectangle(cornerRadius: 6).stroke(MarketPalette.divider))
    }
    private var fundingIsFresh: Bool {
        guard !quoteError, let stamp = quoteStamp, selectedQuantity > 0 else { return false }
        return Date().timeIntervalSince(stamp) < 60
    }
    private var ticketMargin: String {
        guard fundingIsFresh, let c = selected else { return "--" }
        // For options this field refers only to seller margin; unavailable is unknown.
        if c.isOption { return "--" }
        guard let q = detailedQuote, q.code == c.symbol, let value = q.referenceMargin,
              value.isFinite, value > 0 else { return "--" }
        return money(value * Double(selectedQuantity))
    }
    private var ticketFeeOrPremium: String {
        guard fundingIsFresh, let c = selected else { return "--" }
        if c.isOption {
            guard let multiplier = c.multiplier, multiplier.isFinite, multiplier > 0,
                  let price = effectivePrice(buy: true), price.isFinite, price > 0 else { return "--" }
            return money(price * multiplier * Double(selectedQuantity))
        }
        guard let q = detailedQuote, q.code == c.symbol, let fee = q.referenceCommission,
              fee.isFinite, fee > 0 else { return "--" }
        return money(fee) + "/手"
    }
    private func ticketInfo(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.system(size: 13)).foregroundStyle(MarketPalette.muted).fixedSize()
            Spacer(minLength: 0)
            Text(value).font(.system(size: 13)).foregroundStyle(MarketPalette.ink).lineLimit(1)
        }.font(.system(size: 13)).monospacedDigit()
    }
    private var sharedTradeControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                VStack(spacing: 12) {
                    HStack(spacing: 5) {
                        Text("价格").font(.system(size: 13)).foregroundStyle(MarketPalette.muted).fixedSize()
                        priceInput
                    }
                    HStack(spacing: 5) {
                        Text("手数").font(.system(size: 13)).foregroundStyle(MarketPalette.muted).fixedSize()
                        quantityInput
                    }
                }.frame(maxWidth: .infinity)
                Divider().frame(height: 100)
                VStack(spacing: 6) {
                    quoteLine("卖一", selected?.ask, volume: optionQuote?.askVolume ?? detailedQuote?.askVolume)
                    quoteLine("买一", selected?.bid, volume: optionQuote?.bidVolume ?? detailedQuote?.bidVolume)
                    Divider()
                    ticketInfo("保证金", ticketMargin)
                    ticketInfo(selected?.isOption == true ? "权利金" : "手续费", ticketFeeOrPremium)
                }.frame(width: 150)
            }.padding(8).overlay(RoundedRectangle(cornerRadius: 8).stroke(MarketPalette.divider))
            priceModePicker
            openingLimitNotice
            if quoteError { Text("报价获取失败").font(.caption).foregroundStyle(Color.yellow) }
            HStack(spacing: 8) {
                tradeButton("开多", color: MarketPalette.up, title: selected?.isOption == true ? "买开" : "买多")
                if !quickOnly || selected?.isOption != true {
                    tradeButton("开空", color: MarketPalette.down, title: selected?.isOption == true ? "卖开" : "卖空")
                }
                if !quickOnly || selected?.isOption == true { unifiedCloseButton }
            }
        }
    }
    private var quickOrderPanel: some View {
        VStack(spacing: 8) {
            HStack {
                Text(selected.map { contractName($0.symbol) } ?? initialContract.map { contractName($0.symbol) } ?? "--")
                    .font(.headline).lineLimit(1).minimumScaleFactor(0.7)
                Spacer()
                Text(priceText(selected?.last)).font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(quoteColor(selected?.last)).monospacedDigit()
                Text(quoteChangeText).font(.caption2).foregroundStyle(MarketPalette.movement(quoteChange))
            }
            sharedTradeControls
            if let quickConfirmationError { Text(quickConfirmationError).font(.caption).foregroundStyle(.red) }
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
            sharedTradeControls
        }.padding(.vertical, 6)
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
                Text(title).font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(value.map { $0.formatted() } ?? "--").font(.system(size: 13)).foregroundStyle(quoteColor(value))
                if let volume { Text(volume.formatted()).font(.system(size: 13)).foregroundStyle(.secondary) }
            }.font(.system(size: 13)).monospacedDigit().lineLimit(1)
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
            quickSubmittedID = nil
        } label: {
            VStack(spacing: 3) {
                Text(priceText(effectivePrice(buy: action == "开多"))).font(.system(size: 22, weight: .semibold).monospacedDigit())
                Text(title ?? (selected?.option != nil ? (action == "开多" ? "买开" : "卖开") : action))
            }.font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 64)
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
    private let frozenContractWidth: CGFloat = 132
    private let recordHeaderHeight: CGFloat = 28
    private let recordRowHeight: CGFloat = 34

    private func recordBand<Content: View>(height: CGFloat, selected: Bool = false,
                                          @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(height: height)
            .background(selected ? MarketPalette.raised : MarketPalette.background)
            .overlay(alignment: .bottom) {
                Rectangle().fill(MarketPalette.divider).frame(height: 0.5)
            }
    }

    private func frozenRecordTable<Left: View, Right: View>(
        @ViewBuilder left: () -> Left, @ViewBuilder right: () -> Right
    ) -> some View {
        HStack(alignment: .top, spacing: 0) {
            left()
                .frame(width: tab == "挂单" ? 116 : frozenContractWidth, alignment: .leading)
                .background(MarketPalette.background)
                .zIndex(1)
            ScrollView(.horizontal, showsIndicators: true) {
                right().fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
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
                VStack(spacing: 0) {
                    if let snapshot = session.snapshot {
                        if tab == "持仓" {
                            frozenPositions(snapshot.positions)
                        } else if tab == "成交" {
                            frozenFills((snapshot.fills ?? []).sorted { $0.time_ns > $1.time_ns })
                        } else {
                            frozenOrders((snapshot.orders ?? []).filter { tab != "挂单" || $0.status == "ALIVE" }.sorted {
                                ($0.time_ns ?? 0) == ($1.time_ns ?? 0) ? $0.id > $1.id : ($0.time_ns ?? 0) > ($1.time_ns ?? 0)
                            })
                        }
                    } else {
                        Text("账户数据暂不可用").font(.caption).foregroundStyle(.secondary)
                        if tab == "持仓" { positionSummaryUnavailable }
                    }
                }
            }
            .id(tab)
        }.padding(.top, 5).frame(maxHeight: .infinity, alignment: .top)
    }

    private func frozenPositions(_ positions: [CloudSnapshot.Position]) -> some View {
        let held = positions.filter { $0.long > 0 || $0.short > 0 }
        return VStack(spacing: 0) {
            frozenRecordTable {
                VStack(spacing: 0) {
                    recordBand(height: recordHeaderHeight) {
                        recordCell("合约 / 多空", width: frozenContractWidth).foregroundStyle(.secondary)
                    }
                    ForEach(held) { p in
                        if p.long > 0 { frozenPositionName(p, long: true) }
                        if p.short > 0 { frozenPositionName(p, long: false) }
                    }
                    recordBand(height: recordRowHeight) {
                        Text("合计").font(.system(size: 13, weight: .semibold))
                            .frame(width: frozenContractWidth, alignment: .leading)
                    }
                }
            } right: {
                VStack(spacing: 0) {
                    recordBand(height: recordHeaderHeight) {
                        HStack(spacing: 4) {
                            Text("手数/可平").lineLimit(1).fixedSize(horizontal: true, vertical: false).frame(width: 72)
                            Text("开仓均价").frame(width: 70, alignment: .trailing)
                            Text("浮盈").frame(width: 75, alignment: .trailing)
                            Text("保证金").frame(width: 85, alignment: .trailing)
                            Text("市值").frame(width: 85, alignment: .trailing)
                        }.font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    ForEach(held) { p in
                        if p.long > 0 { positionRow(p, long: true) }
                        if p.short > 0 { positionRow(p, long: false) }
                    }
                    positionSummary(held)
                }
            }
            if held.isEmpty { Text("暂无持仓").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func frozenFills(_ fills: [CloudSnapshot.Fill]) -> some View {
        let closes = fills.filter { $0.offset != "OPEN" }
        let profits = closes.compactMap { $0.calculated_close_profit }.filter { $0.isFinite }
        let total: Double? = profits.isEmpty ? nil : profits.reduce(0, +)
        return VStack(spacing: 0) {
            frozenRecordTable {
                VStack(spacing: 0) {
                    recordBand(height: recordHeaderHeight) {
                        recordCell("合约", width: frozenContractWidth).foregroundStyle(.secondary)
                    }
                    ForEach(fills) { f in
                        recordBand(height: recordRowHeight) {
                            recordCell(contractName(f.symbol), width: frozenContractWidth)
                        }
                    }
                    if !fills.isEmpty {
                        recordBand(height: recordRowHeight) {
                            recordCell("合计", width: frozenContractWidth).fontWeight(.semibold)
                        }
                    }
                }
            } right: {
                VStack(spacing: 0) {
                    recordBand(height: recordHeaderHeight) {
                        HStack(spacing: 5) {
                            recordCell("开平", width: 38)
                            recordCell("成交价", width: 60)
                            recordCell("手数", width: 32)
                            recordCell("平仓盈亏", width: 88)
                            recordCell("时间", width: 76)
                        }.foregroundStyle(.secondary)
                    }
                    ForEach(fills) { f in
                        recordBand(height: recordRowHeight) {
                            HStack(spacing: 5) {
                                recordCell(recordAction(f.direction, f.offset), width: 38)
                                    .foregroundStyle(f.direction == "BUY" ? MarketPalette.up : MarketPalette.down)
                                recordCell(f.price?.formatted() ?? "", width: 60)
                                recordCell(String(f.quantity), width: 32)
                                recordCell(f.offset != "OPEN" && f.calculated_close_profit?.isFinite == true ? money(f.calculated_close_profit, suffix: false) : "", width: 88)
                                    .foregroundStyle(MarketPalette.movement(f.calculated_close_profit))
                                recordCell(recordTime(f.time_ns), width: 76)
                            }
                        }
                    }
                    if !fills.isEmpty {
                        recordBand(height: recordRowHeight) {
                            HStack(spacing: 5) {
                                Color.clear.frame(width: 38)
                                Color.clear.frame(width: 60)
                                recordCell(String(fills.reduce(0) { $0 + $1.quantity }), width: 32).fontWeight(.semibold)
                                recordCell(total.map { money($0, suffix: false) } ?? "", width: 88)
                                    .foregroundStyle(MarketPalette.movement(total)).fontWeight(.semibold)
                                Color.clear.frame(width: 76)
                            }
                        }
                    }
                }
            }
            if fills.isEmpty { Text("暂无成交或未取得数据").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func rejectionReason(_ order: CloudSnapshot.Order) -> String? {
        guard order.display_state == "REJECTED" else { return nil }
        let message = order.message.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : message
    }

    private func frozenOrders(_ orders: [CloudSnapshot.Order]) -> some View {
        VStack(spacing: 0) {
            frozenRecordTable {
                VStack(spacing: 0) {
                    recordBand(height: recordHeaderHeight) {
                        recordCell("合约", width: tab == "挂单" ? 116 : frozenContractWidth).foregroundStyle(.secondary)
                    }
                    ForEach(orders) { o in
                        recordBand(height: recordRowHeight) {
                            recordCell(contractName(o.symbol), width: tab == "挂单" ? 116 : frozenContractWidth)
                        }
                        if rejectionReason(o) != nil { recordBand(height: 23) { Color.clear.frame(width: tab == "挂单" ? 116 : frozenContractWidth) } }
                    }
                }
            } right: {
                VStack(spacing: 0) {
                    recordBand(height: recordHeaderHeight) {
                        HStack(spacing: tab == "挂单" ? 2 : 5) {
                            recordCell("状态", width: tab == "挂单" ? 31 : 56)
                            recordCell("开平", width: tab == "挂单" ? 29 : 38)
                            recordCell("委托价", width: tab == "挂单" ? 48 : 60)
                            recordCell(tab == "挂单" ? "手数" : "委托量", width: tab == "挂单" ? 28 : 48)
                            if tab != "挂单" {
                                recordCell("已成交", width: 48)
                                recordCell("已撤单", width: 48)
                                recordCell("成交均价", width: 72)
                            }
                            if tab == "挂单" { recordCell("操作", width: 32) }
                            recordCell("时间", width: 76)
                        }.foregroundStyle(.secondary)
                    }
                    ForEach(orders) { o in
                        recordBand(height: recordRowHeight) {
                            HStack(spacing: tab == "挂单" ? 2 : 5) {
                                    HStack(spacing: tab == "挂单" ? 2 : 5) {
                                        recordCell(o.stateText, width: tab == "挂单" ? 31 : 56)
                                        recordCell(recordAction(o.direction, o.offset), width: tab == "挂单" ? 29 : 38)
                                            .foregroundStyle(o.direction == "BUY" ? MarketPalette.up : MarketPalette.down)
                                        recordCell(o.price?.formatted() ?? "", width: tab == "挂单" ? 48 : 60)
                                        recordCell(String(o.quantity), width: tab == "挂单" ? 28 : 48)
                                        if tab != "挂单" {
                                            recordCell(String(max(0, o.quantity - o.remaining)), width: 48)
                                            recordCell(canceledQuantity(o) == "--" ? "" : canceledQuantity(o), width: 48)
                                            recordCell(o.trade_price?.formatted(.number.precision(.fractionLength(2))) ?? "", width: 72)
                                        }
                                        if tab == "挂单" {
                                            Button("撤单", role: .destructive) { cancelID = o.id }
                                                .font(.system(size: 13)).lineLimit(1).buttonStyle(.plain)
                                                .foregroundStyle(MarketPalette.up)
                                                .frame(width: 32, height: recordRowHeight)
                                                .contentShape(Rectangle())
                                                .disabled(session.busy || session.isLive || o.status != "ALIVE")
                                                .opacity(session.busy || session.isLive || o.status != "ALIVE" ? 0.4 : 1)
                                                .accessibilityLabel("撤单 " + contractName(o.symbol))
                                        }
                                        recordCell(recordTime(o.time_ns), width: 76)
                                    }.frame(height: recordRowHeight)
                            }
                        }
                        if let reason = rejectionReason(o) {
                            recordBand(height: 23) {
                                Text(reason).font(.system(size: 13)).foregroundStyle(MarketPalette.up)
                                    .lineLimit(1).frame(width: 300, alignment: .leading)
                            }.accessibilityLabel(reason)
                        }
                    }
                }
            }
            if orders.isEmpty { Text(tab == "挂单" ? "暂无挂单" : "暂无委托或未取得数据").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func canceledQuantity(_ order: CloudSnapshot.Order) -> String {
        switch order.display_state {
        case "CANCELED", "PARTIAL_CANCELED": return String(max(0, order.remaining))
        case "FILLED", "ALIVE", "PARTIAL": return "0"
        default: return "--"
        }
    }
    private func recordCell(_ value: String, width: CGFloat? = nil) -> some View {
        Text(value).font(.system(size: 13)).monospacedDigit().lineLimit(1).truncationMode(.tail)
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
    private func confirmationRow<Content: View>(_ label: String, @ViewBuilder value: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label).foregroundStyle(MarketPalette.muted)
            Spacer(minLength: 8)
            value().foregroundStyle(MarketPalette.ink).monospacedDigit()
        }.font(.system(size: 15)).frame(minHeight: 32)
    }

    private func confirmationCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 4, content: content)
            .padding(12).background(MarketPalette.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(MarketPalette.divider))
    }

    private func confirmationPanel<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 12) {
            Text(title).font(.headline).frame(maxWidth: .infinity)
            content()
        }.padding(16).frame(maxWidth: .infinity)
            .background(MarketPalette.raised, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(MarketPalette.divider))
    }

    private func confirmationButtons(_ title: String, tint: Color, enabled: Bool,
                                     cancel: @escaping () -> Void, confirm: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Button(action: cancel) {
                Text("取消").font(.system(size: 16, weight: .medium)).frame(maxWidth: .infinity).frame(height: 44)
                    .foregroundStyle(MarketPalette.accent)
                    .background(MarketPalette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain)
            Button(action: confirm) {
                Text(title).font(.system(size: 16, weight: .medium)).frame(maxWidth: .infinity).frame(height: 44)
                    .foregroundStyle(.white)
                    .background(tint.opacity(enabled ? 0.9 : 0.3), in: RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain).disabled(!enabled)
        }
    }

    private func closingBar(_ long: Bool) -> some View {
        let available = availableToClose(long)
        let title = long ? "卖出平多" : "买入平空"
        return confirmationPanel("确认平仓") {
            confirmationCard {
                confirmationRow("合约") { Text(selected.map { contractName($0.symbol) } ?? "--") }
                confirmationRow("持仓") { Text((long ? "多头" : "空头") + " · 可平 " + (available.map { String($0) } ?? "--") + " 手") }
                Divider()
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
                    confirmationRow("平仓价格") {
                        TextField("限价", text: $closePrice).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    confirmationRow("平仓手数") {
                        HStack {
                            TextField("手数", value: $closeQuantity, format: .number.grouping(.never)).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                            Button("最多") { closeQuantity = available ?? 0 }.buttonStyle(.borderless).disabled((available ?? 0) <= 0)
                        }
                    }
                    if requiresSplit {
                        Picker("平仓类型", selection: $closeToday) {
                            Text("平昨").tag(false)
                            Text("平今").tag(true)
                        }.pickerStyle(.segmented)
                        Text("平今/平昨具体可平量以柜台回报为准").font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    confirmationRow("平仓价格") { Text(closePrice) }
                    confirmationRow("平仓手数") { Text("\(closeQuantity) 手") }
                    if requiresSplit { confirmationRow("平仓类型") { Text(closeToday ? "平今" : "平昨") } }
                }
            }
            confirmationButtons(closeConfirm ? "确认" + title : title, tint: long ? MarketPalette.down : MarketPalette.up,
                                enabled: validClose(long), cancel: { closingSide = nil; closeConfirm = false }) {
                IndicatorKeyboard.dismiss()
                if closeConfirm { submitClose(long) } else { closeConfirm = true }
            }
        }
    }
    private func submitClose(_ long: Bool) {
        guard validClose(long), let c = selected else { return }
        let direction = long ? "SELL" : "BUY"
        let offset = requiresSplit && closeToday ? "CLOSETODAY" : "CLOSE"
        let price = closePrice, qty = String(closeQuantity)
        closingSide = nil; closeConfirm = false; tab = "委托"
        quickSubmittedID = nil
        Task {
            let id = await session.submit(symbol: c.symbol, direction: direction, offset: offset, price: price, quantity: qty)
            if quickOnly { quickSubmittedID = id }
        }
    }
    private func cancelConfirmationBar(_ id: String) -> some View {
        let order = session.snapshot?.orders?.first(where: { $0.id == id })
        return confirmationPanel("确认撤销模拟委托") {
            confirmationCard {
                if let order {
                    confirmationRow("合约") { Text(contractName(order.symbol) + " · " + actionName(order.direction, order.offset)) }
                    Divider()
                    confirmationRow("委托") { Text(orderQuantityText(order)) }
                } else {
                    Text("委托状态暂不可用").font(.subheadline)
                }
            }
            confirmationButtons("确认撤单", tint: MarketPalette.up,
                                enabled: order?.status == "ALIVE" && !session.busy && !session.isLive,
                                cancel: { cancelID = nil }) {
                cancelID = nil
                Task { await session.cancel(id) }
            }
        }
    }
    private func orderConfirmationBar(_ action: String) -> some View {
        confirmationPanel("确认模拟委托") {
            confirmationCard {
                if let draft = openingDraft {
                    confirmationRow("合约") { Text(contractName(draft.symbol)) }
                    confirmationRow("方向") { Text(draft.title) }
                    Divider()
                    confirmationRow("委托价格") { Text(draft.price) }
                    confirmationRow("委托手数") { Text("\(draft.quantity) 手") }
                } else { Text("委托信息不可用").font(.subheadline) }
            }
            confirmationButtons("确认" + (openingDraft?.title ?? openingTitle(action)),
                                tint: action == "开多" ? MarketPalette.up : MarketPalette.down,
                                enabled: validDraft(action), cancel: { pendingAction = nil; openingDraft = nil }) {
                submitConfirmed(action)
            }
        }
    }
    private func submitConfirmed(_ action: String) {
        guard pendingAction == action, let draft = openingDraft, validDraft(action) else { return }
        let direction = action == "开多" ? "BUY" : "SELL"
        pendingAction = nil; openingDraft = nil; tab = "委托"
        Task {
            let id = await session.submit(symbol: draft.symbol, direction: direction, offset: "OPEN", price: draft.price, quantity: String(draft.quantity))
            if quickOnly { quickSubmittedID = id }
        }
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
        Text("合计 --").font(.system(size: 13)).foregroundStyle(MarketPalette.muted)
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
        recordBand(height: recordRowHeight) {
            HStack(spacing: 4) {
                Text((lots.map { String($0) } ?? "--") + "/" + (closable.map { String($0) } ?? "--"))
                    .lineLimit(1).frame(width: 72)
                Color.clear.frame(width: 70)
                Text(money(profit, suffix: false))
                    .foregroundStyle(MarketPalette.movement(profit))
                    .lineLimit(1).frame(width: 75, alignment: .trailing)
                Color.clear.frame(width: 85)
                Color.clear.frame(width: 85)
            }.font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(MarketPalette.ink)
        }
    }
    private func selectPosition(_ p: CloudSnapshot.Position, long: Bool) {
        let qty = long ? p.long : p.short
        let frozen = long ? p.frozen_long : p.frozen_short
        selectHolding(p.symbol)
        expandedHolding = p.symbol + (long ? "/long" : "/short")
        selectedQuantity = frozen.map { max(1, qty - $0) } ?? 1
    }
    private func frozenPositionName(_ p: CloudSnapshot.Position, long: Bool) -> some View {
        let selectedRow = expandedHolding == p.symbol + (long ? "/long" : "/short")
        return recordBand(height: recordRowHeight, selected: selectedRow) {
            Button { selectPosition(p, long: long) } label: {
                HStack(spacing: 3) {
                    Text(contractName(p.symbol)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(long ? "多" : "空").font(.system(size: 13))
                        .foregroundStyle(long ? MarketPalette.up : MarketPalette.down).fixedSize()
                }.frame(width: frozenContractWidth, alignment: .leading)
                    .frame(height: recordRowHeight).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(contractName(p.symbol) + (long ? " 多" : " 空"))
        }
    }
    private func positionRow(_ p: CloudSnapshot.Position, long: Bool) -> some View {
        let qty = long ? p.long : p.short
        let frozen = long ? p.frozen_long : p.frozen_short
        let average = long ? p.open_price_long : p.open_price_short
        let profit = (long ? p.float_profit_long : p.float_profit_short) ?? ((p.long == 0 || p.short == 0) ? p.float_profit : nil)
        let selectedRow = expandedHolding == p.symbol + (long ? "/long" : "/short")
        return recordBand(height: recordRowHeight, selected: selectedRow) {
            Button { selectPosition(p, long: long) } label: {
                HStack(spacing: 4) {
                    Text(String(qty) + "/" + (frozen.map { String(max(0, qty-$0)) } ?? "--")).frame(width: 72)
                    Text(average.map { $0.formatted(.number.precision(.fractionLength(2))) } ?? "--").frame(width: 70, alignment: .trailing)
                    Text(money(profit, suffix: false)).foregroundStyle(MarketPalette.movement(profit)).frame(width: 75, alignment: .trailing)
                    Text(money(long ? p.margin_long : p.margin_short, suffix: false)).frame(width: 85, alignment: .trailing)
                    Text(money(long ? p.market_value_long : p.market_value_short, suffix: false)).frame(width: 85, alignment: .trailing)
                }.font(.system(size: 13)).monospacedDigit().foregroundStyle(MarketPalette.ink).lineLimit(1)
                    .frame(height: recordRowHeight).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
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
