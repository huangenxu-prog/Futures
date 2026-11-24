/// Pure rule for deciding whether the chart must replace its historical series.
enum KlineCorrectionPolicy {
    static func hasEarlierCorrection<Bar: Equatable>(
        previous: [Bar], incoming: [Bar]
    ) -> Bool {
        guard previous.count == incoming.count, previous.count > 1 else {
            return false
        }
        return zip(previous.dropLast(), incoming.dropLast()).contains { $0 != $1 }
    }
}
