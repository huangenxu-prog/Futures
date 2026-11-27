import Foundation
import TradingChart

/// Per-chart coordinator. All scheduling and publication occur on the main actor;
/// PineRuntime performs evaluation away from it. One active batch per coordinator.
@MainActor
final class PineChartCalculation {
    struct Definition: Equatable, Sendable {
        let id: UUID
        let name: String
        let source: String
        let overlay: Bool
    }
    struct Request: Equatable, Sendable {
        let scope: String
        let period: Int
        let bars: [MarketBar]
        let axis: [Int64: Int64]
        let definitions: [Definition]
    }
    struct Result {
        let indicators: [PineChartIndicator]
        let errors: [UUID: String]
    }
    private var pending: Request?
    private var latest: Request?
    private var worker: Task<Void, Never>?
    private var generation = 0
    private var publish: ((Result) -> Void)?

    func submit(_ request: Request, publish: @escaping (Result) -> Void) {
        self.publish = publish
        guard latest != request else { return }
        latest = request
        pending = request
        if worker != nil { return }
        worker = Task { [weak self] in await self?.drain() }
    }

    func reset() {
        generation += 1
        latest = nil
        pending = nil
        publish = nil
        // Keep an existing evaluation in flight until it returns; starting a
        // second worker would defeat the one-at-a-time guarantee.
    }

    private func drain() async {
        defer { worker = nil }
        while let request = pending {
            pending = nil
            let token = generation
            let result = await Self.calculate(request)
            guard token == generation else { continue }
            // Do not publish across a symbol/period/settings change. During
            // live quote bursts a slightly older snapshot is useful, then the
            // newest pending snapshot is calculated next.
            if let latest,
               latest.scope == request.scope,
               latest.period == request.period,
               latest.definitions == request.definitions,
               latest.axis == request.axis {
                publish?(result)
            }
        }
    }

    private static func calculate(_ request: Request) async -> Result {
        guard request.period > 0, !request.bars.isEmpty else {
            return Result(indicators: [], errors: [:])
        }
        let bars = Array(request.bars.suffix(10_000))
        let step = Int64(request.period) * 1000
        let input = bars.map { bar in
            let time = bar.time * 1000
            return PineRuntimeBar(open: bar.open, high: bar.high, low: bar.low,
                                  close: bar.close, volume: Double(bar.volume),
                                  openTime: time, closeTime: time + step - 1)
        }
        var mapping: [Int64: Date] = [:]
        for bar in bars {
            if let virtual = request.axis[bar.time] {
                mapping[bar.time * 1000] = Date(timeIntervalSince1970: Double(virtual))
            }
        }
        var indicators: [PineChartIndicator] = []
        var errors: [UUID: String] = [:]
        for definition in request.definitions {
            do {
                let plots = try await PineRuntime.evaluateBundled(source: definition.source, bars: input)
                indicators.append(PineChartIndicator.make(id: "pine:" + definition.id.uuidString,
                    name: definition.name, overlay: definition.overlay, plots: plots,
                    actualToChart: mapping))
            } catch {
                errors[definition.id] = error.localizedDescription
            }
        }
        return Result(indicators: indicators, errors: errors)
    }
}
