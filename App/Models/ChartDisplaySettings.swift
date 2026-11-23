import Foundation
import TradingChart

enum ChartIndicatorKind: String, Codable, CaseIterable, Hashable, Identifiable {
    case sma, emaFast, emaSlow, wma, boll, volume, macd, rsi
    var id: String { rawValue }

    var title: String {
        switch self {
        case .sma: return "SMA"
        case .emaFast: return "EMA 1"
        case .emaSlow: return "EMA 2"
        case .wma: return "WMA"
        case .boll: return "BOLL"
        case .volume: return "VOL"
        case .macd: return "MACD"
        case .rsi: return "RSI"
        }
    }
}

struct ChartDisplaySettings: Codable, Equatable {
    var enabled: Set<ChartIndicatorKind> = [.emaFast, .emaSlow, .volume, .macd]
    var sma = 20
    var emaFast = 20
    var emaSlow = 50
    var wma = 20
    var bollPeriod = 20
    var bollMultiplier = 2.0
    var volumeMA = 20
    var macdFast = 12
    var macdSlow = 26
    var macdSignal = 9
    var rsi = 14

    private static let key = "qihui.chart.custom-indicator-settings.v1"

    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.isValid else { return Self() }
        return value
    }

    func save() {
        guard isValid, let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    var isValid: Bool {
        let periods = [sma, emaFast, emaSlow, wma, bollPeriod, volumeMA,
                       macdFast, macdSlow, macdSignal, rsi]
        return periods.allSatisfy { (2...500).contains($0) }
            && macdFast < macdSlow
            && bollMultiplier.isFinite && bollMultiplier >= 0.1 && bollMultiplier <= 10
    }

    func toggle(_ kind: ChartIndicatorKind) -> Self {
        var changed = self
        if changed.enabled.contains(kind) {
            changed.enabled.remove(kind)
        } else {
            changed.enabled.insert(kind)
        }
        return changed
    }

    func label(for kind: ChartIndicatorKind) -> String {
        switch kind {
        case .sma: return "MA\(sma)"
        case .emaFast: return "EMA\(emaFast)"
        case .emaSlow: return "EMA\(emaSlow)"
        case .wma: return "WMA\(wma)"
        case .boll: return "BOLL"
        case .volume: return "VOL"
        case .macd: return "MACD"
        case .rsi: return "RSI"
        }
    }

    func indicators() -> [any ChartIndicator] {
        ChartIndicatorKind.allCases.compactMap { kind -> (any ChartIndicator)? in
            guard enabled.contains(kind) else { return nil }
            switch kind {
            case .sma: return SMA(period: sma)
            case .emaFast: return EMA(period: emaFast)
            case .emaSlow: return EMA(period: emaSlow)
            case .wma: return WMA(period: wma)
            case .boll: return BollingerBands(period: bollPeriod, multiplier: bollMultiplier)
            case .volume: return Volume(movingAveragePeriod: volumeMA)
            case .macd: return MACD(fast: macdFast, slow: macdSlow, signal: macdSignal)
            case .rsi: return RSI(period: rsi)
            }
        }
    }
}
