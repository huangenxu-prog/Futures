import Foundation

@main
struct SessionAxisSelfTest {
    static func main() {
        let period = 900
        // Bar timestamps cross lunch, an overnight session, and a weekend.
        let actual: [Int64] = [
            1_795_240_800, 1_795_241_700, 1_795_249_800,
            1_795_250_700, 1_795_509_900
        ]
        var axis = TradingSessionAxis()
        axis.register(actual, period: period)
        let positions = actual.compactMap { axis.chartTime(for: $0)?.timeIntervalSince1970 }
        precondition(positions.count == actual.count)
        for index in 1..<positions.count {
            precondition(Int64(positions[index] - positions[index - 1]) == Int64(period),
                         "Non-trading hours must not occupy X-axis slots")
        }
        for real in actual {
            guard let slot = axis.chartTime(for: real) else { fatalError("missing slot") }
            precondition(axis.actualTime(for: slot) == real,
                         "Crosshair must retain the original exchange timestamp")
        }

        let old = axis.chartTime(for: actual.first!)!
        let latest = axis.chartTime(for: actual.last!)!
        // Live quote updates existing candle without moving it.
        axis.register([actual.last!], period: period)
        precondition(axis.chartTime(for: actual.last!) == latest)

        // New candle immediately follows even across a trading break.
        let future = actual.last! + 86_400
        axis.register([future], period: period)
        precondition(axis.chartTime(for: future)!.timeIntervalSince(latest) == Double(period))

        // Loading an earlier page must not move the chart's existing bars.
        let older: [Int64] = [actual.first! - 180_000, actual.first! - 179_100]
        axis.register(older, period: period)
        precondition(axis.chartTime(for: actual.first!) == old,
                     "History prepend must preserve scroll anchor")
        precondition(axis.chartTime(for: older.last!)!.timeIntervalSince(old) == -Double(period))
        precondition(axis.nearestActual(for: old) == actual.first!)
        print("Trading-session axis checks passed")
    }
}
