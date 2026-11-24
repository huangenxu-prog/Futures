import Foundation

/// Independent, deterministic numerical functions. A replacement of the
/// unfinished candle is a fresh calculation, never an extra time step.
enum FuturesIndicatorMath {
    struct OHLC {
        let high: Double
        let low: Double
        let close: Double
    }

    // Chinese-style KDJ: RSV over N bars, K/D recursive SMA with seed 50.
    // A flat range uses neutral RSV 50; J can exceed 0...100.
    static func kdj(_ bars: [OHLC], period: Int, kPeriod: Int, dPeriod: Int)
      -> (k: [Double?], d: [Double?], j: [Double?]) {
        var k = [Double?](repeating: nil, count: bars.count)
        var d = k, j = k
        guard period > 0, kPeriod > 0, dPeriod > 0, bars.count >= period else { return (k,d,j) }
        var previousK = 50.0, previousD = 50.0
        // Sliding monotonic queues keep the rolling extrema linear in N.
        var highs: [Int] = [], lows: [Int] = []
        var hiHead = 0, loHead = 0
        for i in bars.indices {
            while hiHead < highs.count, highs[hiHead] <= i-period { hiHead += 1 }
            while loHead < lows.count, lows[loHead] <= i-period { loHead += 1 }
            while highs.count > hiHead, bars[highs.last!].high <= bars[i].high { highs.removeLast() }
            while lows.count > loHead, bars[lows.last!].low >= bars[i].low { lows.removeLast() }
            highs.append(i); lows.append(i)
            guard i >= period-1 else { continue }
            let high = bars[highs[hiHead]].high, low = bars[lows[loHead]].low
            let rsv = high > low ? 100 * (bars[i].close-low)/(high-low) : 50
            previousK += (rsv-previousK)/Double(kPeriod)
            previousD += (previousK-previousD)/Double(dPeriod)
            k[i] = previousK; d[i] = previousD; j[i] = 3*previousK-2*previousD
        }
        return (k,d,j)
    }

    // Wilder ATR: first true range uses H-L, initial ATR is the mean of
    // the first N TRs; subsequent points use Wilder's recursive smoothing.
    static func atr(_ bars: [OHLC], period: Int) -> [Double?] {
        var output = [Double?](repeating: nil, count: bars.count)
        guard period > 0, bars.count >= period else { return output }
        var sum = 0.0, previous = 0.0
        for i in bars.indices {
            let b = bars[i]
            let tr = i == 0 ? b.high-b.low : max(b.high-b.low, abs(b.high-bars[i-1].close), abs(b.low-bars[i-1].close))
            if i < period {
                sum += tr
                if i == period-1 { previous = sum/Double(period); output[i] = previous }
            } else {
                previous += (tr-previous)/Double(period)
                output[i] = previous
            }
        }
        return output
    }

    // Wilder-style parabolic SAR. Start direction from the first two
    // closes, clamp to the prior two lows/highs, reset AF on reversal.
    static func sar(_ bars: [OHLC], step: Double, maximum: Double) -> [Double?] {
        var output = [Double?](repeating: nil, count: bars.count)
        guard bars.count >= 2, step > 0, maximum >= step else { return output }
        var rising = bars[1].close >= bars[0].close
        var value = rising ? min(bars[0].low,bars[1].low) : max(bars[0].high,bars[1].high)
        var extreme = rising ? max(bars[0].high,bars[1].high) : min(bars[0].low,bars[1].low)
        var af = step
        output[1] = value
        for i in 2..<bars.count {
            let b = bars[i]
            let projected = value + af*(extreme-value)
            if rising {
                let candidate = min(projected,bars[i-1].low,bars[i-2].low)
                if b.low < candidate {
                    value = max(extreme,b.high); rising = false; extreme = b.low; af = step
                } else {
                    value = candidate
                    if b.high > extreme { extreme = b.high; af = min(maximum,af+step) }
                }
            } else {
                let candidate = max(projected,bars[i-1].high,bars[i-2].high)
                if b.high > candidate {
                    value = min(extreme,b.low); rising = true; extreme = b.high; af = step
                } else {
                    value = candidate
                    if b.low < extreme { extreme = b.low; af = min(maximum,af+step) }
                }
            }
            output[i] = value
        }
        return output
    }
}
