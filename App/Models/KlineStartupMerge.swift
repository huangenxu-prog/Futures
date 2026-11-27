import Foundation

/// Reconcile an immediate VPS history snapshot with a concurrently arriving
/// SSE bar. Server data corrects old phone-cache candles; the newest live
/// exchange bar remains authoritative if it is at least as recent as the
/// server snapshot's last candle. The exchange timestamp is the identity.
enum KlineStartupMerge {
    static let initialCount = 200
    static let historyPageCount = 300

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


/// Limits discretionary chart paging, not the backtest endpoint or indicator warm-up.
enum ChartHistoryBudget {
    static func limit(period: Int) -> (days: Int, bars: Int) {
        switch period {
        case 60: return (7,1500)
        case 180: return (7,800)
        case 300: return (15,800)
        case 600: return (15,500)
        case 900,1800: return (30,500)
        case 3600: return (60,500)
        case 7200: return (90,300)
        case 86400: return (365,300)
        case 604800: return (1826,300)
        default: return (30,500)
        }
    }
    static func cutoff(period: Int, now: Int64) -> Int64 {
        now - Int64(limit(period: period).days) * 86400
    }
    static func remaining(period: Int, loaded: Int) -> Int {
        max(0, limit(period: period).bars - loaded)
    }
}
