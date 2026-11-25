
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
    let positions: [Position]
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
                                        Text("多 (p.long) 手 · 空 (p.short) 手")
                                        Spacer()
                                        Text(money(p.float_profit))
                                    }.font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        } else { Text("持仓未取得").foregroundStyle(.secondary) }
                    }
                    Section("交易功能") {
                        Button("下单、撤单、委托与成交（待接入）") {}.disabled(true)
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
    private func money(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "--" }
        return value.formatted(.number.precision(.fractionLength(2))) + " 元"
    }
}
