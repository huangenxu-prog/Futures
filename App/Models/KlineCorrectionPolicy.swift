/// Pure rule for deciding whether the chart must replace its historical series.
enum KlineCorrectionPolicy {
    /// A rolling server window can discard its oldest bars without changing
    /// the already displayed history. Only use an incremental append when
    /// the entire remaining overlap is identical and there is one new bar.
    static func isUnchangedRollingAppend<Bar: Equatable, Stamp: Comparable>(
        previous: [Bar], incoming: [Bar], time: (Bar) -> Stamp
    ) -> Bool {
        guard previous.count >= 2, incoming.count >= 2,
              let first = incoming.first, let last = incoming.last,
              let priorLast = previous.last, time(last) > time(priorLast),
              let offset = previous.firstIndex(where: { time($0) == time(first) }),
              offset > 0, previous.count - offset == incoming.count - 1 else {
            return false
        }
        return previous.dropFirst(offset).elementsEqual(incoming.dropLast())
    }

    static func hasEarlierCorrection<Bar: Equatable>(
        previous: [Bar], incoming: [Bar]
    ) -> Bool {
        guard !previous.isEmpty,
              incoming.count == previous.count || incoming.count == previous.count + 1 else {
            return false
        }
        // If a new candle arrives together with a correction to the former
        // open candle, that closed candle must also reach the chart model.
        return zip(previous, incoming.dropLast()).contains { $0 != $1 }
    }
}
