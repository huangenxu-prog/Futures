import Foundation

enum CompactMarketQuantity {
    static func format(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "--" }
        if abs(value) >= 100_000_000 {
            return String(format: "%.2f亿", value / 100_000_000)
        }
        if abs(value) >= 10_000 {
            return String(format: "%.2f万", value / 10_000)
        }
        return value.formatted(.number.precision(.fractionLength(0)))
    }
}
