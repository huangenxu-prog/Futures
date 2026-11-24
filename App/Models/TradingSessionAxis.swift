import Foundation

/// Maps actual exchange bar timestamps to a contiguous synthetic timeline.
/// Chart gestures/indicators use uniformly spaced slots; labels and the
/// application continue to use actual exchange timestamps.
struct TradingSessionAxis: Sendable {
    private(set) var actualToVirtual: [Int64: Int64] = [:]
    private(set) var virtualToActual: [Int64: Int64] = [:]
    private(set) var virtualSlots: [Int64] = []
    private(set) var secondsPerBar: Int64 = 0

    var isEmpty: Bool { actualToVirtual.isEmpty }
    var firstActual: Int64? { actualToVirtual.keys.min() }

    mutating func register(_ timestamps: [Int64], period: Int) {
        guard period > 0 else { return }
        let step = Int64(period)
        if secondsPerBar != step {
            actualToVirtual.removeAll()
            virtualToActual.removeAll()
            virtualSlots.removeAll()
            secondsPerBar = step
        }
        // Most live frames replace only OHLCV at a known timestamp.
        // Do not rebuild or sort the axis when every slot already exists.
        let sorted = Array(Set(timestamps.filter { actualToVirtual[$0] == nil })).sorted()
        guard !sorted.isEmpty else { return }

        if actualToVirtual.isEmpty {
            let start: Int64 = (1_700_000_000 / step) * step
            for (index, real) in sorted.enumerated() {
                insert(real, virtual: start + Int64(index) * step)
            }
            refreshSlots()
            return
        }

        guard let firstExisting = actualToVirtual.keys.min(),
              let lastExisting = actualToVirtual.keys.max(),
              let firstVirtual = virtualSlots.first,
              let lastVirtual = virtualSlots.last else { return }

        // Historical pages are assigned earlier virtual slots without changing
        // existing coordinates. A live append uses the next adjacent slot.
        var before = firstVirtual
        for real in sorted.reversed() where real < firstExisting {
            before -= step
            insert(real, virtual: before)
        }
        var after = lastVirtual
        for real in sorted where real > lastExisting {
            after += step
            insert(real, virtual: after)
        }

        // Do not silently misplace backfilled bars between two known slots.
        // Ordinarily TqSdk sends a continuous page, so this only handles
        // exceptional gaps in a previously incomplete response.
        if sorted.contains(where: { actualToVirtual[$0] == nil }) {
            let all = Array(Set(Array(actualToVirtual.keys) + sorted)).sorted()
            let start = firstVirtual - Int64(all.count - actualToVirtual.count) * step
            actualToVirtual.removeAll()
            virtualToActual.removeAll()
            for (index, real) in all.enumerated() {
                insert(real, virtual: start + Int64(index) * step)
            }
        }

        refreshSlots()
    }

    func chartTime(for actual: Int64) -> Date? {
        actualToVirtual[actual].map { Date(timeIntervalSince1970: Double($0)) }
    }

    func actualTime(for chartTime: Date) -> Int64? {
        virtualToActual[Int64(chartTime.timeIntervalSince1970.rounded())]
    }

    func nearestActual(for chartTime: Date) -> Int64? {
        guard !virtualSlots.isEmpty else { return nil }
        let target = Int64(chartTime.timeIntervalSince1970.rounded())
        var low = 0
        var high = virtualSlots.count
        while low < high {
            let middle = (low + high) / 2
            if virtualSlots[middle] < target { low = middle + 1 }
            else { high = middle }
        }
        if low == 0 { return virtualToActual[virtualSlots[0]] }
        if low == virtualSlots.count { return virtualToActual[virtualSlots[low - 1]] }
        let left = virtualSlots[low - 1]
        let right = virtualSlots[low]
        return virtualToActual[target - left <= right - target ? left : right]
    }

    private mutating func insert(_ actual: Int64, virtual: Int64) {
        guard actualToVirtual[actual] == nil else { return }
        actualToVirtual[actual] = virtual
        virtualToActual[virtual] = actual
    }

    private mutating func refreshSlots() {
        virtualSlots = virtualToActual.keys.sorted()
    }
}
