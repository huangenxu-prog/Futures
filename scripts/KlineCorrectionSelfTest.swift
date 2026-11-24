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
        print("Earlier-candle correction policy: OK")
    }
}
