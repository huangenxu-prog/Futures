import Foundation

@main
struct KlineCorrectionSelfTest {
    static func main() {
        let history = [10, 20, 30, 40]
        precondition(!KlineCorrectionPolicy.hasEarlierCorrection(
            previous: history, incoming: history))
        precondition(!KlineCorrectionPolicy.hasEarlierCorrection(
            previous: history, incoming: [10, 20, 30, 41]))
        precondition(KlineCorrectionPolicy.hasEarlierCorrection(
            previous: history, incoming: [10, 20, 29, 40]))
        precondition(!KlineCorrectionPolicy.hasEarlierCorrection(
            previous: history, incoming: [20, 30, 40]))
        precondition(!KlineCorrectionPolicy.hasEarlierCorrection(
            previous: [10], incoming: [11]))
        precondition(!KlineCorrectionPolicy.hasEarlierCorrection(
            previous: history, incoming: [10, 20, 30, 40, 50]))
        precondition(KlineCorrectionPolicy.hasEarlierCorrection(
            previous: history, incoming: [10, 20, 30, 41, 50]))
        struct Bar: Equatable { let time: Int; let price: Int }
        let prior = (1...4).map { Bar(time: $0, price: $0) }
        let next = (2...5).map { Bar(time: $0, price: $0) }
        precondition(KlineCorrectionPolicy.isUnchangedRollingAppend(previous: prior, incoming: next, time: { $0.time }))
        var corrected = next
        corrected[2] = Bar(time: 4, price: 99)
        precondition(!KlineCorrectionPolicy.isUnchangedRollingAppend(previous: prior, incoming: corrected, time: { $0.time }))
        precondition(!KlineCorrectionPolicy.isUnchangedRollingAppend(previous: prior, incoming: Array(next.dropLast()), time: { $0.time }))
        precondition(!KlineCorrectionPolicy.isUnchangedRollingAppend(previous: prior, incoming: [Bar(time: 4, price: 4), Bar(time: 6, price: 6), Bar(time: 7, price: 7)], time: { $0.time }))
        print("Earlier-candle correction and rolling append policy: OK")
    }
}
