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
        var hi,lo,first,last: Int
    }
    static func analyze(_ bars: [FormulaBar]) -> Result {
        var merged: [Merged] = []
        var direction = 0
        for (i,b) in bars.enumerated() {
            let next = Merged(high:b.high,low:b.low,hi:i,lo:i,first:i,last:i)
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
                let confirmed = merged[i+2].first
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




/// Research rule: a sweep is only a candidate. Wait for a later strict
/// retest fractal that respects the sweep extreme. Report the confirmation
/// at its right-hand bar, never on the earlier fractal center.
enum HuntConfirmation {
    struct Result: Sendable {
        let signals: [HuntSignals.Signal?]
        let reverseN: [Int]
        let candidates: Int
        let confirmed: Int
        let invalidated: Int
        let expired: Int
    }
    private struct Pivot {
        let kind: Int
        let price: Double
    }
    static func calculate(_ bars: [FormulaBar], candidates: [HuntSignals.Signal?], maxWait: Int = 12) -> Result {
        precondition(bars.count == candidates.count)
        var pending: (index:Int,signal:HuntSignals.Signal)?
        var pivots: [Pivot] = []
        var signals = [HuntSignals.Signal?](repeating:nil,count:bars.count)
        var reversal = [Int](repeating:0,count:bars.count)
        var total = 0, confirmed = 0, invalidated = 0, expired = 0
        for i in bars.indices {
            var fractal = 0
            if i >= 2 {
                let a = bars[i-2], b = bars[i-1], c = bars[i]
                if b.high > a.high && b.high > c.high && b.low > a.low && b.low > c.low {
                    fractal = 1
                } else if b.high < a.high && b.high < c.high && b.low < a.low && b.low < c.low {
                    fractal = -1
                }
                if fractal != 0 {
                    let p = Pivot(kind:fractal,price:fractal > 0 ? b.high : b.low)
                    if let last = pivots.last, last.kind == p.kind {
                        if p.kind > 0 ? p.price > last.price : p.price < last.price {
                            pivots[pivots.count-1] = p
                        }
                    } else {
                        pivots.append(p)
                        if pivots.count > 4 { pivots.removeFirst() }
                    }
                }
            }
            // N proxy: latest two confirmed highs and lows both rising
            // or both falling. This is intentionally a research definition.
            if pivots.count == 4 {
                let a = pivots[0], b = pivots[1], c = pivots[2], d = pivots[3]
                if c.price > a.price && d.price > b.price { reversal[i] = 1 }
                else if c.price < a.price && d.price < b.price { reversal[i] = -1 }
            }
            if let active = pending {
                let s = active.signal, b = bars[i]
                let broken = s.side > 0 ? b.low < s.extreme : b.high > s.extreme
                if broken || reversal[i] == -s.side {
                    pending = nil; invalidated += 1
                } else if i-active.index > maxWait {
                    pending = nil; expired += 1
                } else if i-1 > active.index && fractal == -s.side {
                    let center = bars[i-1]
                    let respects = s.side > 0 ? center.low >= s.extreme && b.close > s.level
                                              : center.high <= s.extreme && b.close < s.level
                    if respects {
                        signals[i] = s; pending = nil; confirmed += 1
                    }
                }
            }
            if let candidate = candidates[i] {
                total += 1
                // A replacement candidate is a separate sweep, not a
                // retrospectively altered original signal.
                if pending != nil { invalidated += 1 }
                pending = (i,candidate)
            }
        }
        return Result(signals:signals,reverseN:reversal,candidates:total,
                      confirmed:confirmed,invalidated:invalidated,expired:expired)
    }
}

/// A historical research version of the multi-timeframe hunting rules.
/// Timestamp alignment uses conservative nominal close times; only known
/// completed higher-period prefixes enter the decision. It is not a
/// substitute for the final manually specified pen/entry-leg/N rules.
enum MultiPeriodHunt {
    struct Timed: Sendable {
        let time: Int64
        let bar: FormulaBar
    }
    struct ResearchResult: Sendable {
        let signals: [HuntSignals.Signal?]
        let covered: Int
        let candidates: Int
        let accepted: Int
        let confirmed: Int
        let invalidated: Int
        let expired: Int
        let exitsLong: [Bool]
        let exitsShort: [Bool]
    }

    private static func trend(_ pivots:[ChanStructure.Pivot]) -> Int {
        let highs = pivots.filter{$0.kind == .top}
        let lows = pivots.filter{$0.kind == .bottom}
        guard highs.count >= 2,lows.count >= 2 else { return 0 }
        let a = highs[highs.count-2].price,b = highs[highs.count-1].price
        let c = lows[lows.count-2].price,d = lows[lows.count-1].price
        if b > a && d > c { return 1 }
        if b < a && d < c { return -1 }
        return 0
    }

    private struct Qualification {
        var side = 0
        var zone: ChanStructure.Zone?
    }
    private static func departure(_ data:[Timed], count:Int) -> Qualification {
        guard count >= 12 else { return Qualification() }
        let bars = data.prefix(count).map(\.bar)
        let structure = ChanStructure.analyze(bars)
        guard let zone = structure.zones.last, let last = bars.last else { return Qualification() }
        let direction = trend(structure.pivots)
        // Latest overlapping three-stroke region; only a price still
        // outside that region in the structure's direction is eligible.
        // This is a coarse departure proxy, not the final entry-leg rule.
        if direction == 1 && last.close > zone.high { return Qualification(side:1,zone:zone) }
        if direction == -1 && last.close < zone.low { return Qualification(side:-1,zone:zone) }
        return Qualification(side:0,zone:zone)
    }

    static func calculate(five:[Timed],thirty:[Timed],hour:[Timed],fifteen:[Timed] = [],requireFifteen:Bool = false) -> ResearchResult {
        let bars = five.map(\.bar)
        let confirmation = HuntConfirmation.calculate(bars,candidates:HuntSignals.calculate(bars))
        let candidates = confirmation.signals
        var signals = [HuntSignals.Signal?](repeating:nil,count:five.count)
        var exitsLong = [Bool](repeating:false,count:five.count)
        var exitsShort = exitsLong
        var h = 0, m = 0, f = 0, hourTrend = 0, auxiliary = 0
        var qualification = Qualification()
        var covered = 0, examined = 0, accepted = 0
        var calendar = Calendar(identifier:.gregorian)
        calendar.timeZone = TimeZone(identifier:"Asia/Shanghai")!
        for i in five.indices {
            let close = five[i].time + 300
            let oldH = h, oldM = m, oldF = f
            while h < hour.count && hour[h].time+3600 <= close { h += 1 }
            while m < thirty.count && thirty[m].time+1800 <= close { m += 1 }
            while f < fifteen.count && fifteen[f].time+900 <= close { f += 1 }
            if h != oldH {
                hourTrend = trend(ChanStructure.analyze(hour.prefix(h).map(\.bar)).pivots)
            }
            if m != oldM { qualification = departure(thirty,count:m) }
            if f != oldF && requireFifteen {
                let pivots = ChanStructure.analyze(fifteen.prefix(f).map(\.bar)).fractals
                // Auxiliary confirmation proxy, not a claim of the exact
                // discretionary 15m rule: latest confirmed bottom/top.
                auxiliary = pivots.last.map { $0.kind == .bottom ? 1 : -1 } ?? 0
            }
            guard h >= 12,m >= 12, !requireFifteen || f >= 12 else { continue }
            covered += 1
            let closePrice = five[i].bar.close
            let reverse = confirmation.reverseN[i]
            exitsLong[i] = reverse == -1 || hourTrend == -1 || qualification.side != 1
                || (qualification.zone.map { closePrice <= $0.high } ?? false)
            exitsShort[i] = reverse == 1 || hourTrend == 1 || qualification.side != -1
                || (qualification.zone.map { closePrice >= $0.low } ?? false)
            guard let signal = candidates[i] else { continue }
            examined += 1
            // Friday signal and execution dates are filtered by Shanghai
            // civil date. Session/holiday trading-day rules remain separate.
            guard i+1 < five.count else { continue }
            let signalDay = calendar.component(.weekday,from:Date(timeIntervalSince1970:Double(close)))
            let entryDay = calendar.component(.weekday,from:Date(timeIntervalSince1970:Double(five[i+1].time)))
            guard signalDay != 6,entryDay != 6 else { continue }
            if signal.side == hourTrend && signal.side == qualification.side
                && (!requireFifteen || signal.side == auxiliary)
                && !(signal.side > 0 ? exitsLong[i] : exitsShort[i]) {
                signals[i] = signal
                accepted += 1
            }
        }
        return ResearchResult(signals:signals,covered:covered,candidates:examined,accepted:accepted,
                              confirmed:confirmation.confirmed,invalidated:confirmation.invalidated,
                              expired:confirmation.expired,exitsLong:exitsLong,exitsShort:exitsShort)
    }
}
