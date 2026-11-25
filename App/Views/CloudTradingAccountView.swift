
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
    case invalidURL, rejected, unavailable, expired, conflict
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "请输入有效的 HTTPS 交易网关地址"
        case .rejected: return "登录或授权失败，请检查快期账户及网关访问密钥"
        case .unavailable: return "交易网关或快期服务暂不可用"
        case .expired: return "会话已失效，请退出后重新登录"
        case .conflict: return "上一次会话仍在使用，请退出旧会话或等待释放"
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
            actionMessage = order.remaining == 0 ? "委托已全部成交" : "委托已结束，请核对撤单结果"
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
        let unresolved = TradeKeychain.load(address, kind: "pending")
        if !unresolved.isEmpty { pendingOrder = unresolved }
        reconcile(data)
        snapshot = data; signedIn = true
        error = nil
    }
    func recover(address: String) async {
        guard !manualLogout, !busy, !signedIn, !recovering, Date() >= retryAfter else { return }
        let key = TradeKeychain.load(address)
        let user = TradeKeychain.load(address, kind: "username")
        let password = TradeKeychain.load(address, kind: "password")
        guard !key.isEmpty, !user.isEmpty, !password.isEmpty else { return }
        recovering = true
        retryAfter = Date().addingTimeInterval(20)
        defer { recovering = false }
        await login(address: address, key: key, username: user, password: password)
    }
    @Published private(set) var pendingOrder: String?
    @Published private(set) var actionMessage: String?
    private var mutating = false
    var canTrade: Bool { signedIn && snapshot?.simulation_orders == true && !busy && !mutating && pendingOrder == nil }
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
        guard signedIn, snapshot?.simulation_orders == true, !busy, !mutating, let url = endpoint, let token else { return }
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
            let previous = TradeKeychain.load(address, kind: "session")
            if !previous.isEmpty,
               TradeKeychain.load(address, kind: "username") == username,
               TradeKeychain.load(address, kind: "password") == password {
                do {
                    let reply = try await request(base: url, action: "snapshot", key: key, token: previous, body: nil)
                    guard let data = reply.snapshot else { throw CloudTradeError.unavailable }
                    install(data, token: previous, url: url, address: address, key: key)
                    return
                } catch let failure as CloudTradeError {
                    guard case .expired = failure else { throw failure }
                    _ = TradeKeychain.remove(address, kind: "session")
                }
            }
            let reply = try await request(base: url, action: "login", key: key, token: nil,
                                          body: ["username": username, "password": password])
            guard let session = reply.token, !session.isEmpty, let data = reply.snapshot else { throw CloudTradeError.unavailable }
            install(data, token: session, url: url, address: address, key: key)
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
            reconcile(data)
        } catch {
            guard current == generation, !Task.isCancelled else { return }
            snapshot = nil
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
        if !activeAddress.isEmpty {
            _ = TradeKeychain.remove(activeAddress, kind: "password")
            _ = TradeKeychain.remove(activeAddress, kind: "session")
        }
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
        case 409: throw CloudTradeError.conflict
        case 429: throw CloudTradeError.unavailable
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
    @State private var key = ""
    @State private var keychainMessage: String?
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
                    VStack(spacing: 0) {
                        if !quickOnly { accountHeader; Divider() }
                        else { Text("快期云端模拟").font(.caption).foregroundStyle(.secondary) }
                        orderPanel
                        if !quickOnly { Divider(); recordsPanel }
                        else { Spacer(minLength: 0) }
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
                } else {
                    List {
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
                            if key.isEmpty {
                                SecureField("网关访问密钥", text: $key)
                            } else {
                                LabeledContent("网关访问密钥", value: "已填写")
                            }
                            Button("清除已保存密钥", role: .destructive) {
                                if TradeKeychain.remove(address) { key = ""; keychainMessage = nil; _ = TradeKeychain.remove(address, kind: "password"); _ = TradeKeychain.remove(address, kind: "session") }
                                else { keychainMessage = "无法清除设备钥匙串密钥" }
                            }.disabled(session.busy)
                            if let keychainMessage { Text(keychainMessage).font(.caption).foregroundStyle(.red) }
                            Text("首次登录成功后，本机钥匙串安全记住模拟账户及密钥，之后自动恢复。退出账户将停止自动登录。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Section {
                            Button {
                                let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
                                let secret = password
                                let access = key
                                session.allowManualLogin()
                                Task { await session.login(address: address, key: access, username: user, password: secret); if session.signedIn { password = "" } }
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
                    if let message = session.error { Section { Text(message).font(.caption).foregroundStyle(.red) } }
                    }
                    .listStyle(.insetGrouped)
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
            .navigationTitle(quickOnly ? "快捷开仓" : "交易")
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
            .task(id: selectionRequest) {
                guard let c = selected else { return }
                await Task.yield()
                while !Task.isCancelled {
                    await refreshQuote(c)
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                }
            }
            .onAppear {
                if key.isEmpty { key = TradeKeychain.load(address) }
                if username.isEmpty { username = TradeKeychain.load(address, kind: "username") }
                openInitialIfReady()
            }
            .onChange(of: address) { _, newAddress in
                key = TradeKeychain.load(newAddress); keychainMessage = nil
                username = TradeKeychain.load(newAddress, kind: "username"); password = ""
            }
            .onChange(of: session.signedIn) { _, signedIn in
                if signedIn {
                    openInitialIfReady()
                } else {
                    pendingAction = nil; cancelID = nil; closingSide = nil; closeConfirm = false
                    key = TradeKeychain.load(address)
                }
            }
            .sheet(isPresented: $local) {
                LocalPaperTradingCenterView(favoriteIDs: favoriteIDs, mainCodes: mainCodes, initialContract: initialContract)
            }
            .task(id: "\(address)-\(scenePhase)") {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    if session.signedIn { await session.refresh() }
                    else if !real { await session.recover(address: address) }
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                }
            }
        }.tint(MarketPalette.accent)
    }
    private func openInitialIfReady() {
        guard !openedInitial, initialContract != nil, session.signedIn else { return }
        openedInitial = true
        if let initialContract { choose(initialContract) }
    }

    private var accountHeader: some View {
        VStack(spacing: 5) {
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
        }.padding(.vertical, 6)
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
        guard action == "开多" || action == "开空" else { return false }
        guard session.canTrade, let c = selected, let p = Double(selectedPrice), p.isFinite, p > 0, (1...10).contains(selectedQuantity) else { return false }
        guard let tick = c.tick, tick.isFinite, tick > 0 else { return false }
        do {
            let steps = p / tick
            if abs(steps - steps.rounded()) > 0.00001 { return false }
        }
        return true
    }
    private var orderPanel: some View {
        VStack(spacing: 7) {
            Button { if !quickOnly { selecting = true } } label: {
                HStack {
                    Image(systemName: "magnifyingglass")
                    Text(selected.map { contractName($0.symbol) } ?? "选择交易合约")
                    Spacer()
                    Text(selected?.symbol ?? "").font(.caption2).foregroundStyle(.secondary)
                    if !quickOnly { Image(systemName: "chevron.right").font(.caption2) }
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
            HStack(spacing: 8) {
                tradeButton("开多", color: MarketPalette.up)
                tradeButton("开空", color: MarketPalette.down)
            }
        }.padding(.vertical, 8)
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
        Button { IndicatorKeyboard.dismiss(); pendingAction = action } label: {
            Text(selected?.option != nil ? (action == "开多" ? "买开" : "卖开") : action).font(.system(size: 15, weight: .semibold))
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
            if closingSide != nil, closePrice.isEmpty, let last = next.last, last > 0 { closePrice = String(last) }
        } catch {
            guard !Task.isCancelled, selected?.symbol == c.symbol else { return }
            quoteError = true
            selected = PaperContract(symbol: c.symbol, name: c.name, tick: c.tick, multiplier: c.multiplier, last: nil, bid: nil, ask: nil, option: c.option)
        }
    }
    private var recordsPanel: some View {
        VStack(spacing: 5) {
            Picker("交易记录", selection: $tab) {
                ForEach(["持仓","挂单","委托","成交"], id: \.self) { Text($0) }
            }.pickerStyle(.segmented)
            ScrollView {
            LazyVStack(spacing: 0) {
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
                        HStack { Text(fillQuantityText(f)); Spacer(); Text(Date(timeIntervalSince1970: Double(f.time_ns)/1e9).formatted(date: .omitted, time: .standard)) }.font(.caption).foregroundStyle(.secondary)
                    }
                }
                if session.snapshot?.fills?.isEmpty != false { Text("暂无成交或未取得数据").font(.caption).foregroundStyle(.secondary) }
            } else {
                let orders = (session.snapshot?.orders ?? []).filter { tab != "挂单" || $0.status == "ALIVE" }
                ForEach(orders) { o in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(contractName(o.symbol)).fontWeight(.medium); Spacer(); Text(actionName(o.direction,o.offset)) }
                        HStack {
                            Text(orderQuantityText(o))
                            Spacer()
                            Text(o.status == "ALIVE" ? (o.remaining < o.quantity ? "部分成交" : "挂单") : (o.remaining == 0 ? "全部成交" : "已结束"))
                            if tab == "挂单" && o.status == "ALIVE" { Button("撤单", role: .destructive) { cancelID = o.id }.buttonStyle(.borderless).disabled(session.busy) }
                        }.font(.caption)
                        if !o.message.isEmpty { Text(o.message).font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                if orders.isEmpty { Text(tab == "挂单" ? "暂无挂单" : "暂无委托或未取得数据").font(.caption).foregroundStyle(.secondary) }
            }
            }
            }
        }.padding(.top, 5).frame(maxHeight: .infinity, alignment: .top)
    }

    private func beginClose(_ p: CloudSnapshot.Position, long: Bool) {
        IndicatorKeyboard.dismiss()
        if selected?.symbol != p.symbol { selectHolding(p.symbol) }
        closePrice = selected?.last.map { String($0) } ?? ""
        closeQuantity = 1
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
        guard !quickOnly, closingSide == long, session.canTrade,
              let available = availableToClose(long), (1...10).contains(closeQuantity),
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
                    Button("最多") { closeQuantity = min(10, available ?? 0) }.buttonStyle(.borderless).disabled((available ?? 0) <= 0)
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
                Button("取消") { pendingAction = nil }
                    .buttonStyle(.bordered).frame(maxWidth: .infinity)
                Button("确认" + openingTitle(action)) { submitConfirmed(action) }
                    .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                    .disabled(!validOrder(action))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MarketPalette.raised)
        .overlay(alignment: .top) { Divider() }
    }
    private func submitConfirmed(_ action: String) {
        guard let c = selected, validOrder(action) else { return }
        let direction = action == "开多" ? "BUY" : "SELL"
        let offset = "OPEN"
        let price = selectedPrice, qty = String(selectedQuantity)
        pendingAction = nil; tab = "委托"
        Task { await session.submit(symbol: c.symbol, direction: direction, offset: offset, price: price, quantity: qty) }
    }
    private func openingTitle(_ action: String) -> String {
        selected?.option != nil ? (action == "开多" ? "买开" : "卖开") : action
    }
    private func orderConfirmationText(_ action: String) -> String {
        let name = selected.map { contractName($0.symbol) } ?? ""
        let suffix = ""
        return "\(name) \(openingTitle(action))\(suffix) \(selectedQuantity) 手 @ \(selectedPrice)"
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
    private func positionRow(_ p: CloudSnapshot.Position, long: Bool) -> some View {
        let qty = long ? p.long : p.short
        let frozen = long ? p.frozen_long : p.frozen_short
        let average = long ? p.open_price_long : p.open_price_short
        let profit = (long ? p.float_profit_long : p.float_profit_short) ?? ((p.long == 0 || p.short == 0) ? p.float_profit : nil)
        return Button { beginClose(p, long: long) } label: {
            HStack(spacing: 4) {
                HStack(spacing: 3) {
                    Text(contractName(p.symbol)).font(.caption.weight(.medium)).lineLimit(1)
                    Text(long ? "多" : "空").font(.caption2).foregroundStyle(long ? MarketPalette.up : MarketPalette.down)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text(String(qty) + "/" + (frozen.map { String(max(0, qty-$0)) } ?? "--")).frame(width: 65)
                Text(average.map { $0.formatted() } ?? "--").frame(width: 67, alignment: .trailing)
                Text(money(profit, suffix: false)).foregroundStyle(MarketPalette.movement(profit)).frame(width: 65, alignment: .trailing)
            }.font(.caption).monospacedDigit().foregroundStyle(MarketPalette.ink)
        }.buttonStyle(.borderless).padding(.vertical, 8)
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
    @ObservedObject private var session = CloudTradeSession.shared
    @AppStorage("qihui.trade.endpoint.v1") private var address = "https://8.153.96.190"
    @State private var storedKey = false
    @State private var message: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("账户状态") {
                    LabeledContent("交易模式", value: "快期云端模拟")
                    LabeledContent("登录状态", value: session.signedIn ? "已登录" : "未登录")
                    if session.signedIn {
                        Button("退出账户", role: .destructive) { Task { await session.logout() } }.disabled(session.busy)
                    }
                }
                Section("交易网关") {
                    TextField("HTTPS 网关地址", text: $address)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .disabled(session.signedIn || session.busy)
                    LabeledContent("访问密钥", value: storedKey ? "本机已保存" : "未保存")
                    Button("清除已保存密钥", role: .destructive) {
                        if TradeKeychain.remove(address) { storedKey = false; message = nil; _ = TradeKeychain.remove(address, kind: "password"); _ = TradeKeychain.remove(address, kind: "session") }
                        else { message = "清除失败" }
                    }.disabled(!storedKey || session.signedIn || session.busy)
                    Text("登录与下单请使用首页的交易入口。").font(.caption).foregroundStyle(.secondary)
                    if let message { Text(message).font(.caption).foregroundStyle(.red) }
                }
            }
            .navigationTitle("交易设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .onAppear { storedKey = !TradeKeychain.load(address).isEmpty }
            .onChange(of: address) { _, value in storedKey = !TradeKeychain.load(value).isEmpty }
        }.tint(MarketPalette.accent)
    }
}
