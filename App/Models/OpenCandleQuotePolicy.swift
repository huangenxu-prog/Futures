import Foundation

/// Only real quotes inside the already established candle may affect its
/// provisional display. Session boundaries/new bars remain server-authoritative.
enum OpenCandleQuotePolicy {
    static func accepts(quoteTime: Double, barTime: Int64, period: Int) -> Bool {
        guard quoteTime.isFinite, period > 0 else { return false }
        let start = Double(barTime)
        return quoteTime >= start && quoteTime < start + Double(period)
    }
}
