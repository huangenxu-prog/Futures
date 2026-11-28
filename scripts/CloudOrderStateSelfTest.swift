import Foundation
@main struct CloudOrderStateSelfTest {
    static func main() {
        let cases: [(String?, String, Int, Int, Bool?, CloudOrderState)] = [
            ("ALIVE", "ALIVE", 1, 1, nil, .alive),
            ("PARTIAL", "ALIVE", 3, 1, false, .partial),
            ("FILLED", "FINISHED", 1, 0, true, .filled),
            ("CANCELED", "FINISHED", 1, 1, true, .canceled),
            ("PARTIAL_CANCELED", "FINISHED", 3, 1, true, .partialCanceled),
            ("REJECTED", "FINISHED", 1, 1, true, .rejected),
            ("FINISHED", "FINISHED", 1, 1, true, .finished),
            ("UNKNOWN", "ALIVE", 1, 1, nil, .unknown),
            ("NEW_STATE", "ALIVE", 1, 1, nil, .unknown),
            (nil, "FINISHED", 1, 1, nil, .finished),
            (nil, "FINISHED", 1, 0, nil, .filled),
            (nil, "ALIVE", 3, 1, nil, .partial),
            ("ALIVE", "ALIVE", 1, 1, true, .finished),
            ("FILLED", "FINISHED", 1, 1, true, .unknown),
            ("ALIVE", "ALIVE", 1, -1, nil, .unknown)
        ]
        for (display, status, quantity, remaining, dead, expected) in cases {
            precondition(CloudOrderState.resolve(display: display, status: status, quantity: quantity, remaining: remaining, isDead: dead) == expected)
        }
        for state in [CloudOrderState.alive, .partial, .filled, .canceled, .partialCanceled, .rejected, .finished, .unknown] {
            precondition(state.label.count == 2)
            precondition(!(state.isWorking && state.isTerminal))
        }
        print("Cloud order state checks OK")
    }
}
