import Foundation

private struct B: Equatable {
    let time: Int64
    let price: Int
}

private func assertPrices(_ actual: [B], _ expected: [B], _ label: String) {
    precondition(actual == expected, "\(label): \(actual) != \(expected)")
}

@main
struct KlineStartupMergeSelfTest {
    static func main() {
        // An authoritative server backfill corrects old stale phone history. A
        // concurrently delivered SSE quote for the still-forming last candle wins.
        let existing = [B(time: 100, price: 1), B(time: 200, price: 2),
                        B(time: 300, price: 3)]
        let server = [B(time: 100, price: 11), B(time: 200, price: 22),
                      B(time: 300, price: 30)]
        let recent = B(time: 300, price: 35)
        assertPrices(KlineStartupMerge.combine(
            server: server, existing: existing, live: recent, timestamp: { $0.time }),
            [B(time: 100, price: 11), B(time: 200, price: 22),
             B(time: 300, price: 35)], "live wins last candle")

        // A new server candle must supersede an obsolete stream candle.
        assertPrices(KlineStartupMerge.combine(
            server: server + [B(time: 400, price: 40)],
            existing: existing, live: recent, timestamp: { $0.time }),
            [B(time: 100, price: 11), B(time: 200, price: 22),
             B(time: 300, price: 30), B(time: 400, price: 40)],
            "server is newer")

        // A two-candle server startup must not discard existing historical pages.
        assertPrices(KlineStartupMerge.combine(
            server: [B(time: 300, price: 31)],
            existing: existing, live: nil, timestamp: { $0.time }),
            [B(time: 100, price: 1), B(time: 200, price: 2),
             B(time: 300, price: 31)], "short snapshot preserves history")

        let long = (1...650).map { B(time: Int64($0), price: $0) }
        let limited = KlineStartupMerge.combine(
            server: long, existing: [], live: nil, limit: 500,
            timestamp: { $0.time })
        precondition(limited.count == 500 && limited.first?.time == 151 &&
                     limited.last?.time == 650, "500-bar memory cap")

        // A 200-bar network page must not discard cached history or a live tick.
        let page = Array(long.suffix(KlineStartupMerge.initialCount))
        let prior = Array(long.suffix(500))
        let live = B(time: 650, price: 999)
        let warmed = KlineStartupMerge.combine(server: page, existing: prior,
                                               live: live, timestamp: { $0.time })
        precondition(KlineStartupMerge.initialCount == 200 && KlineStartupMerge.historyPageCount == 300)
        precondition(page.count == 200 && warmed.count == 500 && warmed.first?.time == 151 && warmed.last == live,
                     "first page preserves cached history and newest live bar")

        print("K-line parallel startup merge checks OK")
    }
}
