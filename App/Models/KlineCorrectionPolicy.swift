/// Pure rule for deciding whether the chart must replace its historical series.
enum KlineCorrectionPolicy {
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
