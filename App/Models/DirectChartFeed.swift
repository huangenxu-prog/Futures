import Foundation

/// The active chart owns one synchronous subscriber. Snapshot replay covers
/// the race between the first HTTP/SSE response and the view's appearance.
/// All reads/writes occur on the main actor, like TradingChartModel itself.
final class DirectChartFeed<Snapshot: Equatable> {
    private var key: String?
    private var latest: Snapshot?
    private var owner: UUID?
    private var subscribedKey: String?
    private var receive: ((Snapshot?, Snapshot) -> Void)?

    @MainActor
    func publish(key: String, snapshot: Snapshot) {
        let previous = self.key == key ? latest : nil
        if previous == snapshot { return }
        self.key = key
        latest = snapshot
        if subscribedKey == key { receive?(previous, snapshot) }
    }

    @MainActor
    func attach(key: String, owner: UUID, fallback: Snapshot,
                receive: @escaping (Snapshot?, Snapshot) -> Void) {
        self.owner = owner
        subscribedKey = key
        self.receive = receive
        // The new view may appear before the first network frame.
        let initial = self.key == key ? (latest ?? fallback) : fallback
        self.key = key
        latest = initial
        receive(nil, initial)
    }

    @MainActor
    func detach(owner: UUID) {
        guard self.owner == owner else { return }
        self.owner = nil
        subscribedKey = nil
        receive = nil
    }
}
