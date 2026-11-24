import Foundation

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
    private static let cacheWriter = DispatchQueue(label: "qihui.kline.cache-writer", qos: .utility)
    private static func cacheURL(symbol: String, period: Int) -> URL? {
        guard let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let safeSymbol = symbol.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? String($0) : "_"
        }.joined()
        return directory.appendingPathComponent("qihui_klines_\(safeSymbol)_\(period).json")
    }

    // Persist an authoritative SSE snapshot for an immediate next visit.
    // Callers throttle writes; never write each market tick to flash storage.
    static func cache(_ bars: [MarketBar], symbol: String, period: Int) {
        guard !bars.isEmpty else { return }
        save(bars, symbol: symbol, period: period)
    }

    static func cached(symbol: String, period: Int) -> [MarketBar]? {
        guard let url = cacheURL(symbol: symbol, period: period),
              let data = try? Data(contentsOf: url),
              let bars = try? JSONDecoder().decode([MarketBar].self, from: data),
              !bars.isEmpty else { return nil }
        return bars.sorted { $0.time < $1.time }
    }

    private static func save(_ bars: [MarketBar], symbol: String, period: Int) {
        guard let url = cacheURL(symbol: symbol, period: period) else { return }
        // Preserve write ordering; encoding and atomic file replacement must
        // not block the main-actor SSE callback or the chart render pass.
        cacheWriter.async {
            guard let data = try? JSONEncoder().encode(bars) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    // Configure via QIHUI_API_BASE_URL in Info.plist at build time.
    // Must be an authenticated HTTPS gateway reachable from the device.
    private static func baseURL() throws -> URL {
        // Temporary device-test endpoint. Quick Tunnel URLs change when restarted.
        // The Info.plist setting takes precedence when available.
        let configured = Bundle.main.object(forInfoDictionaryKey: "QIHUI_API_BASE_URL") as? String
        let raw = (configured?.hasPrefix("https://") == true)
            ? configured!
            : "https://8.153.96.190"
        guard let base = URL(string: raw), base.scheme == "https",
              let host = base.host, !host.isEmpty else {
            throw MarketDataError.notConfigured
        }
        return base
    }

    /// Schedule a bounded VPS history warmup for actual watchlist contracts.
    /// This never changes the user's favorites or creates an account.
    static func warmFavoriteHistory(_ symbols: [String]) async throws {
        let unique = Array(Set(symbols)).sorted()
        guard !unique.isEmpty else { return }
        for start in stride(from: 0, to: unique.count, by: 16) {
            try Task.checkCancellation()
            let batch = Array(unique[start..<min(start + 16, unique.count)])
            let url = try baseURL().appendingPathComponent("v1/cache/warm")
                .appending(queryItems: batch.map {
                    URLQueryItem(name: "symbol", value: $0)
                })
            let (data, response) = try await URLSession.shared.data(
                for: URLRequest(url: url, timeoutInterval: 12)
            )
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  (try? JSONSerialization.jsonObject(with: data)) != nil else {
                throw MarketDataError.invalidResponse
            }
        }
    }

    static func catalogProducts() async throws -> [FuturesInstrument] {
        let url = try baseURL().appendingPathComponent("v1/catalog")
        let (data, response) = try await URLSession.shared.data(
            for: URLRequest(url: url, timeoutInterval: 35)
        )
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw MarketDataError.invalidResponse
        }
        let catalog = try JSONDecoder().decode([FuturesInstrument].self, from: data)
        guard !catalog.isEmpty else { throw MarketDataError.noData }
        return catalog
    }

    /// Fetches only actively viewed or favorited main-contract quotes.
    /// The server rejects requests larger than 48 products.
    static func selectedProductQuotes(_ products: [String]) async throws -> [String: MainContract] {
        guard !products.isEmpty, products.count <= 48 else { return [:] }
        let url = try baseURL().appendingPathComponent("v1/product-quotes")
            .appending(queryItems: products.map { URLQueryItem(name: "product", value: $0) })
        let (data, response) = try await URLSession.shared.data(
            for: URLRequest(url: url, timeoutInterval: 12)
        )
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw MarketDataError.invalidResponse
        }
        return try JSONDecoder().decode([String: MainContract].self, from: data)
    }

    struct MainContract: Codable, Equatable, Sendable {
        let code: String
        let month: String
        let last, settlement, bid, ask, volume, interest, previousInterest: Double?
        let bidVolume, askVolume: Double?
        let time: String?

        var identity: MainContract {
            MainContract(code: code, month: month, last: nil, settlement: nil, bid: nil,
                         ask: nil, volume: nil, interest: nil, previousInterest: nil,
                         bidVolume: nil, askVolume: nil, time: nil)
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

    struct ContractQuote: Decodable, Identifiable {
        let code: String
        let month: String
        let last, settlement, bid, ask, volume, interest, priceTick, volumeMultiple: Double?
        let bidVolume, askVolume: Double?
        let time: String?
        var id: String { code }

        var change: Double? {
            guard let last, let settlement, settlement > 0 else { return nil }
            return last - settlement
        }
        var changePercent: String {
            guard let change, let settlement else { return "--" }
            return String(format: "%+.2f%%", change / settlement * 100)
        }
    }

    static func listedContracts(for product: String) async throws -> [ContractQuote] {
        let url = try baseURL().appendingPathComponent("v1/contracts")
            .appending(queryItems: [URLQueryItem(name: "product", value: product)])
        let (data, response) = try await URLSession.shared.data(
            for: URLRequest(url: url, timeoutInterval: 35)
        )
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw MarketDataError.invalidResponse
        }
        return try JSONDecoder().decode([ContractQuote].self, from: data)
    }

    struct OptionQuote: Decodable, Identifiable {
        let code, side: String
        let strike: Double
        let last, ask, bid, volume, interest: Double?
        var id: String { code }
    }

    static func options(for code: String) async throws -> [OptionQuote] {
        let url = try baseURL().appendingPathComponent("v1/options")
            .appending(queryItems: [URLQueryItem(name: "symbol", value: code)])
        let (data, response) = try await URLSession.shared.data(from: url)
        if (response as? HTTPURLResponse)?.statusCode == 404 {
            throw NSError(domain: "Futures", code: 404, userInfo: [NSLocalizedDescriptionKey: "请升级行情网关以查看期权"])
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MarketDataError.invalidResponse }
        return try JSONDecoder().decode([OptionQuote].self, from: data)
    }

    static func mainContracts() async throws -> [String: MainContract] {
        let url = try baseURL().appendingPathComponent("v1/main-contracts")
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 25))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MarketDataError.invalidResponse }
        return try JSONDecoder().decode([String: MainContract].self, from: data)
    }

    struct CandlePush: Decodable, Sendable {
        struct Timing: Decodable, Sendable {
            let version: Int
            let received_at: Double
            let sent_at: Double
        }
        let symbol: String
        let bars: [MarketBar]?
        let bar: MarketBar?
        let diag: Timing?
        var phoneEpoch: Double? = nil
        var phoneUptime: Double? = nil
        private enum CodingKeys: String, CodingKey { case symbol, bars, bar, diag }
    }

    // Reads real server-sent events. Heartbeats carry no data and are ignored.
    // Ending the connection throws so the caller can reconnect or fall back to HTTP.
    private static func events<T: Decodable & Sendable>(
        from endpoint: URL,
        stamp: ((T, Double, Double) -> T)? = nil,
        onEvent: @MainActor @escaping (T) -> Void
    ) async throws {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = 45
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        // Parse and decode on the serial network delegate, independently
        // of the main actor. Keep every decoded delta in arrival order.
        let label = endpoint.path + "?" + (endpoint.query ?? "")
        let streamID = String(UUID().uuidString.prefix(8))
        let (frames, continuation) = AsyncThrowingStream<SSEDecodedFrame<T>, Error>.makeStream()
        let receiver = SSEEventReceiver<T>(continuation: continuation, label: label, streamID: streamID)
        let delegateQueue = OperationQueue()
        delegateQueue.name = "qihui.sse.receive." + streamID
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.qualityOfService = .userInitiated
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 45
        let session = URLSession(configuration: configuration, delegate: receiver, delegateQueue: delegateQueue)
        let task = session.dataTask(with: request)
        defer {
            task.cancel()
            session.invalidateAndCancel()
            continuation.finish()
        }
        task.resume()
        for try await frame in frames {
            try Task.checkCancellation()
            let value = stamp?(frame.value, frame.epoch, frame.uptime) ?? frame.value
            // Preserve order, and measure the actual start of main-actor work
            // instead of when the background consumer schedules that work.
            await MainActor.run {
                guard !Task.isCancelled else { return }
                let started = ProcessInfo.processInfo.systemUptime
                onEvent(value)
                let ended = ProcessInfo.processInfo.systemUptime
                SSEReceiveTrace.record("apply id=\(streamID) seq=\(frame.sequence) queue_ms=\(SSEReceiveTrace.ms(started - frame.decodedUptime)) receive_to_apply_ms=\(SSEReceiveTrace.ms(started - frame.uptime)) apply_ms=\(SSEReceiveTrace.ms(ended - started))")
            }
        }
        try Task.checkCancellation()
        throw MarketDataError.invalidResponse
    }

    static func streamQuotes(
        onEvent: @MainActor @escaping ([String: MainContract]) -> Void
    ) async throws {
        try await events(from: try baseURL().appendingPathComponent("v1/stream/quotes"),
                         onEvent: onEvent)
    }

    static func streamCandles(
        symbol: String, period: Int, count: Int = 200,
        onEvent: @MainActor @escaping (CandlePush) -> Void
    ) async throws {
        let url = try baseURL().appendingPathComponent("v1/stream/klines")
            .appending(queryItems: [
                URLQueryItem(name: "symbol", value: symbol),
                URLQueryItem(name: "period", value: String(period)),
                URLQueryItem(name: "count", value: String(count))
            ])
        try await events(from: url, stamp: { (event: CandlePush, epoch, uptime) in
            var timed = event
            timed.phoneEpoch = epoch
            timed.phoneUptime = uptime
            return timed
        }, onEvent: onEvent)
    }

    /// Returns candles strictly older than `before`. The server progressively
    /// widens the TqSdk rolling window; no fabricated historical candles.
    static func fetchOlder(
        symbol: String, period: Int, before: Int64,
        count: Int = 300, depth: Int = 1100
    ) async throws -> [MarketBar] {
        let url = try baseURL().appendingPathComponent("v1/history")
            .appending(queryItems: [
                URLQueryItem(name: "symbol", value: symbol),
                URLQueryItem(name: "period", value: String(period)),
                URLQueryItem(name: "before", value: String(before)),
                URLQueryItem(name: "count", value: String(count)),
                URLQueryItem(name: "depth", value: String(depth))
            ])
        var request = URLRequest(url: url)
        request.timeoutInterval = 35
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw MarketDataError.invalidResponse
        }
        let result = try JSONDecoder().decode(KlineResponse.self, from: data)
        guard result.symbol == symbol else { throw MarketDataError.invalidResponse }
        return result.bars.filter { $0.time < before }.sorted { $0.time < $1.time }
    }

    /// Read-only backtest history, separate from the live chart cache.
    /// The gateway accepts at most 500 recent bars and 300 per older page.
    static func backtestHistory(symbol: String, period: Int, count: Int) async throws -> [MarketBar] {
        let wanted = min(7001,max(50,count))
        let recent = try await fetch(symbol:symbol,period:period,count:min(500,wanted),mergeCached:false)
        var indexed: [Int64:MarketBar] = [:]
        for bar in recent { indexed[bar.time] = bar }
        var cursor = indexed.keys.min()
        var pages = 0
        while indexed.count < wanted, let before = cursor, pages < 24 {
            try Task.checkCancellation()
            let older = try await fetchOlder(symbol:symbol,period:period,before:before,
                count:min(300,max(5,wanted-indexed.count)),depth:min(8964,max(1200,wanted+300)))
            let valid = older.filter { $0.time < before }
            guard let next = valid.map(\.time).min(), next < before else { break }
            for bar in valid { indexed[bar.time] = bar }
            cursor = next
            pages += 1
        }
        return Array(indexed.values.sorted { $0.time < $1.time }.suffix(wanted))
    }

    static func fetch(symbol: String, period: Int, count: Int = 100, mergeCached: Bool = true) async throws -> [MarketBar] {
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
        // The chart startup merges on the main actor with the latest SSE bar.
        // Return only the requested network page and do not overwrite its cache.
        if !mergeCached {
            return Array(bars.sorted { $0.time < $1.time }.suffix(max(1, count)))
        }
        // Never destroy a previously hydrated phone history with a short
        // 2-bar HTTP snapshot or a partial first subscription response.
        var byTime: [Int64: MarketBar] = [:]
        for bar in cached(symbol: symbol, period: period) ?? [] {
            byTime[bar.time] = bar
        }
        for bar in bars { byTime[bar.time] = bar }
        let merged = Array(byTime.values.sorted { $0.time < $1.time }.suffix(500))
        save(merged, symbol: symbol, period: period)
        return merged
    }
}

// The delegate queue is explicitly serial; its parser and decoder never
// touch SwiftUI state. Network chunks can be decoded while UI work is pending.
private final class SSEEventReceiver<T: Decodable & Sendable>: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let continuation: AsyncThrowingStream<SSEDecodedFrame<T>, Error>.Continuation
    private let label: String
    private let streamID: String
    private var parser = SSEFrameDecoder<T>()
    private var chunkSequence = 0

    init(continuation: AsyncThrowingStream<SSEDecodedFrame<T>, Error>.Continuation,
         label: String, streamID: String) {
        self.continuation = continuation
        self.label = label
        self.streamID = streamID
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              (http.value(forHTTPHeaderField: "Content-Type") ?? "").hasPrefix("text/event-stream") else {
            SSEReceiveTrace.record("invalid_response id=\(streamID) endpoint=\(label) status=\((response as? HTTPURLResponse)?.statusCode ?? 0)")
            continuation.finish(throwing: MarketDataError.invalidResponse)
            completionHandler(.cancel)
            return
        }
        SSEReceiveTrace.record("connected id=\(streamID) endpoint=\(label)")
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let epoch = Date().timeIntervalSince1970
        let uptime = ProcessInfo.processInfo.systemUptime
        chunkSequence += 1
        let chunkID = chunkSequence
        SSEReceiveTrace.record("chunk id=\(streamID) chunk=\(chunkID) epoch=\(String(format: "%.3f", epoch)) bytes=\(data.count)")
        do {
            try parser.append(data, epoch: epoch, uptime: uptime) { frame in
                var details = ""
                if let push = frame.value as? MarketDataService.CandlePush,
                   let bar = push.bar ?? push.bars?.last {
                    details = " symbol=\(push.symbol) candle=\(bar.time) close=\(bar.close) volume=\(bar.volume)"
                }
                SSEReceiveTrace.record("decoded id=\(streamID) chunk=\(chunkID) seq=\(frame.sequence) decode_ms=\(SSEReceiveTrace.ms(frame.decodedUptime - frame.uptime))" + details)
                continuation.yield(frame)
            }
        } catch {
            SSEReceiveTrace.record("decode_error id=\(streamID) chunk=\(chunkID)")
            continuation.finish(throwing: error)
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let code = error.map { ($0 as NSError).code } ?? 0
        SSEReceiveTrace.record("disconnected id=\(streamID) endpoint=\(label) error_code=\(code)")
        continuation.finish(throwing: error)
    }
}
