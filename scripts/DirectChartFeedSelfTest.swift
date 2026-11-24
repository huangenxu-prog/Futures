import Foundation

@main
struct DirectChartFeedSelfTest {
    @MainActor static func main() {
        let feed = DirectChartFeed<[Int]>()
        let a = UUID(), b = UUID()
        var deliveries: [[Int]] = []
        feed.publish(key: "CF/300", snapshot: [1, 2])
        feed.attach(key: "CF/300", owner: a, fallback: []) { _, incoming in deliveries.append(incoming) }
        precondition(deliveries == [[1, 2]])
        feed.publish(key: "CF/300", snapshot: [1, 3])
        precondition(deliveries == [[1, 2], [1, 3]])
        feed.publish(key: "CF/300", snapshot: [1, 3])
        precondition(deliveries.count == 2)
        feed.publish(key: "CF/900", snapshot: [4, 5])
        precondition(deliveries.count == 2)
        feed.attach(key: "CF/900", owner: b, fallback: []) { _, incoming in deliveries.append(incoming) }
        feed.detach(owner: a)
        feed.publish(key: "CF/900", snapshot: [4, 6])
        precondition(deliveries == [[1, 2], [1, 3], [4, 5], [4, 6]])
        feed.detach(owner: b)
        feed.publish(key: "CF/900", snapshot: [4, 7])
        precondition(deliveries.count == 4)
        let c = UUID()
        var tails: [[Int]] = []
        var full: [[Int]] = []
        feed.attach(key: "CF/900", owner: c, fallback: [], receiveTail: { tails.append($0) }) { _, incoming in full.append(incoming) }
        feed.publish(key: "CF/900", snapshot: [4, 8], tailOnly: true)
        feed.publish(key: "CF/900", snapshot: [4, 8], tailOnly: true)
        feed.publish(key: "CF/900", snapshot: [5, 8, 9])
        precondition(tails == [[4, 8]])
        precondition(full == [[4, 7], [5, 8, 9]])
        feed.detach(owner: c)
        print("Direct chart delivery, replay, dedupe, explicit tail path and lifecycle: OK")
    }
}
