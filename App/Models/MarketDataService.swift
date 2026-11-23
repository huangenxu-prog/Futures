import Foundation

struct MarketBar: Codable {
    let time: Int64
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let preSettlement: Double?
    let volume: Int64
}

private struct KlineResponse: Decodable {
    let symbol: String
    let bars: [MarketBar]
}

enum MarketDataError: LocalizedError {
    case notConfigured
    case invalidResponse
    case noData

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "尚未配置行情服务器地址"
        case .invalidResponse: return "行情服务器返回异常"
        case .noData: return "暂无可用行情"
        }
    }
}

enum MarketDataService {
    private static func cacheURL(symbol: String, period: Int) -> URL? {
        guard let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let safeSymbol = symbol.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? String($0) : "_"
        }.joined()
        return directory.appendingPathComponent("qihui_klines_\(safeSymbol)_\(period).json")
    }

    static func cached(symbol: String, period: Int) -> [MarketBar]? {
        guard let url = cacheURL(symbol: symbol, period: period),
              let data = try? Data(contentsOf: url),
              let bars = try? JSONDecoder().decode([MarketBar].self, from: data),
              !bars.isEmpty else { return nil }
        return bars.sorted { $0.time < $1.time }
    }

    private static func save(_ bars: [MarketBar], symbol: String, period: Int) {
        guard let url = cacheURL(symbol: symbol, period: period),
              let data = try? JSONEncoder().encode(bars) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // Configure via QIHUI_API_BASE_URL in Info.plist at build time.
    // Must be an authenticated HTTPS gateway reachable from the device.
    private static func baseURL() throws -> URL {
        // Temporary device-test endpoint. Quick Tunnel URLs change when restarted.
        // The Info.plist setting takes precedence when available.
        let configured = Bundle.main.object(forInfoDictionaryKey: "QIHUI_API_BASE_URL") as? String
        let raw = (configured?.hasPrefix("https://") == true)
            ? configured!
            : "https://fill-investments-ordinance-mumbai.trycloudflare.com"
        guard let base = URL(string: raw), base.scheme == "https",
              let host = base.host, !host.isEmpty else {
            throw MarketDataError.notConfigured
        }
        return base
    }

    struct MainContract: Codable {
        let code: String
        let month: String
        let last, settlement, bid, ask, volume, interest, previousInterest: Double?
        let time: String?

        var identity: MainContract {
            MainContract(code: code, month: month, last: nil, settlement: nil, bid: nil,
                         ask: nil, volume: nil, interest: nil, previousInterest: nil, time: nil)
        }

        var change: Double? {
            guard let last, let settlement, settlement > 0 else { return nil }
            return last - settlement
        }

        var changePercent: String {
            guard let change, let settlement else { return "--" }
            return String(format: "%+.2f%%", change / settlement * 100)
        }

        var interestChange: Double? {
            guard let interest, let previousInterest else { return nil }
            return interest - previousInterest
        }
    }

    static func mainContracts() async throws -> [String: MainContract] {
        let url = try baseURL().appendingPathComponent("v1/main-contracts")
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 25))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MarketDataError.invalidResponse }
        return try JSONDecoder().decode([String: MainContract].self, from: data)
    }

    static func fetch(symbol: String, period: Int, count: Int = 100) async throws -> [MarketBar] {
        let url = try baseURL().appendingPathComponent("v1/klines")
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw MarketDataError.invalidResponse
        }
        parts.queryItems = [
            URLQueryItem(name: "symbol", value: symbol),
            URLQueryItem(name: "period", value: String(period)),
            URLQueryItem(name: "count", value: String(count))
        ]
        guard let endpoint = parts.url else { throw MarketDataError.invalidResponse }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 25
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw MarketDataError.invalidResponse
        }
        let responseBars = try JSONDecoder().decode(KlineResponse.self, from: data)
        guard responseBars.symbol == symbol else { throw MarketDataError.invalidResponse }
        let bars = responseBars.bars
        guard !bars.isEmpty else { throw MarketDataError.noData }
        let sorted = bars.sorted { $0.time < $1.time }
        save(sorted, symbol: symbol, period: period)
        return sorted
    }
}
