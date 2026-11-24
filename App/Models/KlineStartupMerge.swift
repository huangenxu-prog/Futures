import Foundation

/// Reconcile an immediate VPS history snapshot with a concurrently arriving
/// SSE bar. Server data corrects old phone-cache candles; the newest live
/// exchange bar remains authoritative if it is at least as recent as the
/// server snapshot's last candle. The exchange timestamp is the identity.
enum KlineStartupMerge {
    static func combine<Bar>(
        server: [Bar],
        existing: [Bar],
        live: Bar?,
        limit: Int = 500,
        timestamp: (Bar) -> Int64
    ) -> [Bar] {
        var byTime: [Int64: Bar] = [:]
        for bar in existing {
            byTime[timestamp(bar)] = bar
        }
        for bar in server {
            byTime[timestamp(bar)] = bar
        }
        if let live,
           timestamp(live) >= (server.map(timestamp).max() ?? Int64.min) {
            byTime[timestamp(live)] = live
        }
        let times = byTime.keys.sorted().suffix(max(1, limit))
        return times.compactMap { byTime[$0] }
    }
}
