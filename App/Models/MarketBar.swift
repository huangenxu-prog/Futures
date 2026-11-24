import Foundation

struct MarketBar: Codable, Equatable, Sendable {
    let time: Int64
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let preSettlement: Double?
    let volume: Int64
    let openInterest: Double?
    let closeInterest: Double?

    init(time: Int64, open: Double, high: Double, low: Double, close: Double,
         preSettlement: Double?, volume: Int64,
         openInterest: Double? = nil, closeInterest: Double? = nil) {
        self.time = time; self.open = open; self.high = high; self.low = low
        self.close = close; self.preSettlement = preSettlement; self.volume = volume
        self.openInterest = openInterest; self.closeInterest = closeInterest
    }
}

