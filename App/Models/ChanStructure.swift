import Foundation

// A documented, deterministic first implementation of Chan-style structure.
// Containment is merged in the established direction; the initial direction
// is unknown until the first non-contained pair. The last raw bar is not
// treated as closed by the chart adapter.
enum ChanStructure {
    enum Kind: Int, Sendable { case top = 1, bottom = -1 }
    struct Pivot: Equatable, Sendable {
        let kind: Kind
        let index: Int
        let mergedIndex: Int
        let price: Double
        let confirmedAt: Int
    }
    struct Zone: Equatable, Sendable {
        let startIndex: Int
        let endIndex: Int
        let low: Double
        let high: Double
    }
    struct Result: Sendable {
        let fractals: [Pivot]
        let pivots: [Pivot]
        let zones: [Zone]
    }
    private struct Merged {
        var high,low: Double
        var hi,lo,last: Int
    }
    static func analyze(_ bars: [FormulaBar]) -> Result {
        var merged: [Merged] = []
        var direction = 0
        for (i,b) in bars.enumerated() {
            let next = Merged(high:b.high,low:b.low,hi:i,lo:i,last:i)
            guard var last = merged.last else { merged.append(next); continue }
            let contained = (last.high >= next.high && last.low <= next.low) ||
                            (next.high >= last.high && next.low <= last.low)
            if contained {
                if direction == 0 {
                    // No established direction: retain an envelope, then
                    // start directional containment after a clear separation.
                    if next.high > last.high { last.high = next.high; last.hi = i }
                    if next.low < last.low { last.low = next.low; last.lo = i }
                } else if direction > 0 {
                    if next.high >= last.high { last.high = next.high; last.hi = i }
                    if next.low >= last.low { last.low = next.low; last.lo = i }
                } else {
                    if next.high <= last.high { last.high = next.high; last.hi = i }
                    if next.low <= last.low { last.low = next.low; last.lo = i }
                }
                last.last = i
                merged[merged.count-1] = last
            } else {
                direction = next.high > last.high && next.low > last.low ? 1 : -1
                merged.append(next)
            }
        }
        var fractals: [Pivot] = []
        // A right-hand merged bar must itself be finalized by the following
        // non-contained bar. This is deliberately conservative.
        if merged.count >= 4 {
            for i in 1..<(merged.count-2) {
                let a = merged[i-1], b = merged[i], c = merged[i+1]
                let top = b.high > a.high && b.high > c.high && b.low > a.low && b.low > c.low
                let bottom = b.high < a.high && b.high < c.high && b.low < a.low && b.low < c.low
                let confirmed = merged[i+2].last
                if top || bottom {
                    fractals.append(Pivot(kind:top ? .top : .bottom,index:top ? b.hi : b.lo,
                                          mergedIndex:i,price:top ? b.high : b.low,confirmedAt:confirmed))
                }
            }
        }
        var pivots: [Pivot] = []
        for p in fractals {
            guard let last = pivots.last else { pivots.append(p); continue }
            if p.kind == last.kind {
                let moreExtreme = p.kind == .top ? p.price > last.price : p.price < last.price
                if moreExtreme { pivots[pivots.count-1] = p }
            } else if p.mergedIndex-last.mergedIndex >= 4 {
                let valid = p.kind == .top ? p.price > last.price : p.price < last.price
                if valid { pivots.append(p) }
            }
        }
        // The newest endpoint may still be replaced by a more extreme
        // same-kind fractal. Do not draw it as a finalized stroke.
        let stable = Array(pivots.dropLast())
        var zones: [Zone] = []
        var i = 0
        while i+3 < stable.count {
            let ranges = (i..<i+3).map { j in
                min(stable[j].price,stable[j+1].price)...max(stable[j].price,stable[j+1].price)
            }
            let low = ranges.map(\.lowerBound).max()!
            let high = ranges.map(\.upperBound).min()!
            if low < high {
                var end = i+3
                while end+1 < stable.count {
                    let a = min(stable[end].price,stable[end+1].price)
                    let b = max(stable[end].price,stable[end+1].price)
                    guard a < high && b > low else { break }
                    end += 1
                }
                zones.append(Zone(startIndex:stable[i].index,endIndex:stable[end].index,low:low,high:high))
                i = end
            } else { i += 1 }
        }
        return Result(fractals:fractals,pivots:stable,zones:zones)
    }
}

/// Causal single-period sweep/reclaim building block, not a complete
/// multi-timeframe strategy. Uses previously confirmed strict raw fractals.
/// HH+HL allows long sweeps; LH+LL allows short sweeps. A wick alone does
/// not suffice: the same candle must close back across the level.
enum HuntSignals {
    struct Signal: Sendable, Equatable {
        let side: Int
        let level: Double
        let extreme: Double
    }
    static func calculate(_ bars:[FormulaBar]) -> [Signal?] {
        var high: Double?, priorHigh: Double?, low: Double?, priorLow: Double?
        var usedHigh: Double?, usedLow: Double?
        var result = [Signal?](repeating:nil,count:bars.count)
        for i in bars.indices {
            // Fractal center i-2 is confirmed by i-1, strictly before the
            // candle being tested. No historical rewriting of signals.
            if i >= 3 {
                let a = bars[i-3], b = bars[i-2], c = bars[i-1]
                if b.high > a.high && b.high > c.high && b.low > a.low && b.low > c.low {
                    priorHigh = high; high = b.high; usedHigh = nil
                }
                if b.high < a.high && b.high < c.high && b.low < a.low && b.low < c.low {
                    priorLow = low; low = b.low; usedLow = nil
                }
            }
            guard let h = high, let ph = priorHigh, let l = low, let pl = priorLow else { continue }
            let b = bars[i]
            if h > ph && l > pl && usedLow != l && b.low < l && b.close > l {
                result[i] = Signal(side:1,level:l,extreme:b.low); usedLow = l
            } else if h < ph && l < pl && usedHigh != h && b.high > h && b.close < h {
                result[i] = Signal(side:-1,level:h,extreme:b.high); usedHigh = h
            }
        }
        return result
    }
}
