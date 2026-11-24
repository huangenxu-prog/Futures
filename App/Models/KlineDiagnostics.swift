import Foundation
import OSLog

/// Sampled diagnostics only. No market or account data is uploaded from iOS.
@MainActor
enum KlineDiagnostics {
    private static let logger = Logger(subsystem: "com.huangenxu.futures", category: "KlineLatency")
    private struct Sample {
        let symbol: String
        let period: Int
        let bar: MarketBar
        let received: Double
        let version: String
    }
    private static var pending: Sample?
    private static var lastLocalSample = -Double.infinity

    static func record(_ event: MarketDataService.CandlePush, period: Int,
                       newest: MarketBar?, started: Double) {
        guard let bar = newest, let received = event.phoneUptime else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // If another event replaces the pending bar before SwiftUI observes it,
        // do not incorrectly attribute the next model update to the old event.
        if let old = pending, old.symbol == event.symbol, old.period == period, old.bar != bar {
            pending = nil
        }
        guard event.diag != nil || now - lastLocalSample >= 2 else { return }
        lastLocalSample = now
        let version = event.diag.map { String($0.version) } ?? "local"
        let server = event.diag.map { ($0.sent_at - $0.received_at) * 1000 }
        let transit = event.diag.flatMap { timing in event.phoneEpoch.map { ($0 - timing.sent_at) * 1000 } }
        let message = "QIHUI_LATENCY receive symbol=\(event.symbol) period=\(period) version=\(version) server_ms=\(format(server)) transit_est_ms=\(format(transit)) phone_queue_ms=\(format((started - received) * 1000)) apply_ms=\(format((now - started) * 1000))"
        logger.notice("\(message, privacy: .public)")
        pending = Sample(symbol: event.symbol, period: period, bar: bar, received: received, version: version)
    }

    static func chartUpdated(symbol: String, period: Int, newest: MarketBar?, started: Double) {
        guard let sample = pending, sample.symbol == symbol, sample.period == period,
              sample.bar == newest else { return }
        pending = nil
        let now = ProcessInfo.processInfo.systemUptime
        let message = "QIHUI_LATENCY chart_model symbol=\(symbol) period=\(period) version=\(sample.version) model_ms=\(format((now - started) * 1000)) phone_total_ms=\(format((now - sample.received) * 1000))"
        logger.notice("\(message, privacy: .public)")
    }

    private static func format(_ value: Double?) -> String {
        value.map { String(format: "%.1f", $0) } ?? "na"
    }
}
