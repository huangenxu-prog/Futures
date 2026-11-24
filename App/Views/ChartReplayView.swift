#if DEBUG
import SwiftUI

/// Simulator-only deterministic replay. No network, no synthetic prices in
/// production, identical data/indicators/viewport in the two renderer runs.
private final class ChartReplayProbe {
    var samples: [[String: Double]] = []
}

struct ChartReplayView: View {
    @State private var feed = DirectChartFeed<[MarketBar]>()
    @State private var probe = ChartReplayProbe()
    @State private var settings = false
    @State private var selected: Int64?
    private let key = "REPLAY/300"
    private let bars: [MarketBar] = (0..<500).map { i in
        let p = 15400.0 + Double(i % 9) * 5
        return MarketBar(time: 1795499400 - Int64(499-i)*300, open: p, high: p+20,
                         low: p-20, close: p+5, preSettlement: nil, volume: 500)
    }
    var body: some View {
        ProfessionalChartHost(symbol: "REPLAY", period: 300, bars: bars, feed: feed,
                              feedKey: key, priceTick: 5, showingIndicatorSettings: $settings,
                              selectedCandleTime: $selected, isReplay: true,
                              onReplayApplied: { bar, ms in
            probe.samples.append(["close": bar.close, "volume": Double(bar.volume), "model_ms": ms])
        })
        .preferredColorScheme(.dark)
        .task {
            do {
                try await Task.sleep(for: .seconds(2))
                var next = bars
                let last = bars.last!
                for i in 1...24 {
                    let close = last.open + Double(i % 2 == 0 ? 15 : -15)
                    next[next.count-1] = MarketBar(time: last.time, open: last.open,
                        high: last.high, low: last.low, close: close, preSettlement: nil,
                        volume: last.volume + Int64(i))
                    feed.publish(key: key, snapshot: next)
                    try await Task.sleep(for: .milliseconds(350))
                }
                let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("chart-replay.json")
                try JSONSerialization.data(withJSONObject: probe.samples).write(to: url, options: .atomic)
            } catch { }
        }
    }
}
#endif
