import Foundation

/// Display precision of genuine futures prices. Never impose two decimal
/// places on whole-tick contracts, but preserve fractional exchange ticks.
enum MarketPricePrecision {
    /// Decimal places needed to display a tick without losing precision.
    static func tickDigits(_ tick: Double?) -> Int? {
        guard let tick, tick.isFinite, tick > 0 else { return nil }
        for places in 0...6 {
            let scale = pow(10.0, Double(places))
            let scaled = tick * scale
            if abs(scaled - scaled.rounded()) <= 1e-7 * max(1, abs(scaled)) {
                return places
            }
        }
        return 6
    }

    /// Fallback for gateways that have not supplied priceTick: inspect
    /// the actual OHLC values, rather than assuming all contracts are integer.
    static func digits(tick: Double?, observations: [Double]) -> Int {
        if let places = tickDigits(tick) { return places }
        let finite = observations.filter(\.isFinite)
        guard !finite.isEmpty else { return 2 }
        for places in 0...6 {
            let scale = pow(10.0, Double(places))
            if finite.allSatisfy({ abs($0 * scale - ($0 * scale).rounded()) <= 1e-6 }) {
                return places
            }
        }
        return 6
    }

    /// Up to the instrument's necessary precision, not a fixed ".00".
    static func format(_ value: Double, digits: Int) -> String {
        guard value.isFinite else { return "--" }
        let places = min(max(digits, 0), 6)
        return value.formatted(
            .number.precision(.fractionLength(0...places))
        )
    }
}
