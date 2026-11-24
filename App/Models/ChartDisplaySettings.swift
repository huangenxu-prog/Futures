import Foundation
import TradingChart

enum ChartIndicatorKind: String, Codable, CaseIterable, Hashable, Identifiable {
    case sma, emaFast, emaSlow, wma, boll, volume, macd, rsi, kdj, atr, sar, opi, chan, hunt
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
        case .kdj: return "KDJ"
        case .atr: return "ATR"
        case .sar: return "SAR"
        case .opi: return "OPI"
        case .chan: return "缠论"
        case .hunt: return "猎杀候选"
        }
    }
}

enum MovingAverageType: String, Codable, CaseIterable, Identifiable {
    case sma = "SMA"
    case ema = "EMA"
    case wma = "WMA"
    var id: String { rawValue }
}

struct AdditionalMovingAverage: Codable, Equatable, Identifiable {
    var id = UUID()
    var type: MovingAverageType = .ema
    var period: Int = 100
    var enabled = true
}

struct ChartDisplaySettings: Codable, Equatable {
    // Keep the original four moving averages and their saved visibility intact.
    var enabled: Set<ChartIndicatorKind> = [.emaFast, .emaSlow, .macd]
    var sma = 20
    var emaFast = 20
    var emaSlow = 50
    var wma = 20
    var additionalAverages: [AdditionalMovingAverage] = []
    var formulas: [FormulaDefinition] = []
    var bollPeriod = 20
    var bollMultiplier = 2.0
    var volumeMA = 20
    var macdFast = 12
    var macdSlow = 26
    var macdSignal = 9
    var rsi = 14
    var kdjPeriod = 9
    var kdjK = 3
    var kdjD = 3
    var atrPeriod = 14
    var sarStep = 0.02
    var sarMaximum = 0.2

    // Preserve the existing key so upgrades retain the old parameters.
    private static let key = "qihui.chart.custom-indicator-settings.v1"

    init() {}

    // The original saved JSON lacks additionalAverages. Decode it optionally
    // instead of discarding the user's saved settings on upgrade.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Set<ChartIndicatorKind>.self, forKey: .enabled) ?? enabled
        sma = try c.decodeIfPresent(Int.self, forKey: .sma) ?? sma
        emaFast = try c.decodeIfPresent(Int.self, forKey: .emaFast) ?? emaFast
        emaSlow = try c.decodeIfPresent(Int.self, forKey: .emaSlow) ?? emaSlow
        wma = try c.decodeIfPresent(Int.self, forKey: .wma) ?? wma
        additionalAverages = try c.decodeIfPresent([AdditionalMovingAverage].self, forKey: .additionalAverages) ?? []
        formulas = try c.decodeIfPresent([FormulaDefinition].self, forKey: .formulas) ?? []
        bollPeriod = try c.decodeIfPresent(Int.self, forKey: .bollPeriod) ?? bollPeriod
        bollMultiplier = try c.decodeIfPresent(Double.self, forKey: .bollMultiplier) ?? bollMultiplier
        volumeMA = try c.decodeIfPresent(Int.self, forKey: .volumeMA) ?? volumeMA
        macdFast = try c.decodeIfPresent(Int.self, forKey: .macdFast) ?? macdFast
        macdSlow = try c.decodeIfPresent(Int.self, forKey: .macdSlow) ?? macdSlow
        macdSignal = try c.decodeIfPresent(Int.self, forKey: .macdSignal) ?? macdSignal
        rsi = try c.decodeIfPresent(Int.self, forKey: .rsi) ?? rsi
        kdjPeriod = try c.decodeIfPresent(Int.self, forKey: .kdjPeriod) ?? kdjPeriod
        kdjK = try c.decodeIfPresent(Int.self, forKey: .kdjK) ?? kdjK
        kdjD = try c.decodeIfPresent(Int.self, forKey: .kdjD) ?? kdjD
        atrPeriod = try c.decodeIfPresent(Int.self, forKey: .atrPeriod) ?? atrPeriod
        sarStep = try c.decodeIfPresent(Double.self, forKey: .sarStep) ?? sarStep
        sarMaximum = try c.decodeIfPresent(Double.self, forKey: .sarMaximum) ?? sarMaximum
    }

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

    private var enabledAverageKeys: [String] {
        var keys: [String] = []
        if enabled.contains(.sma) { keys.append("SMA:\(sma)") }
        if enabled.contains(.emaFast) { keys.append("EMA:\(emaFast)") }
        if enabled.contains(.emaSlow) { keys.append("EMA:\(emaSlow)") }
        if enabled.contains(.wma) { keys.append("WMA:\(wma)") }
        keys += additionalAverages.filter(\.enabled).map { "\($0.type.rawValue):\($0.period)" }
        return keys
    }

    var hasDuplicateAverages: Bool {
        let keys = enabledAverageKeys
        return Set(keys).count != keys.count
    }

    var isValid: Bool {
        let periods = [sma, emaFast, emaSlow, wma, bollPeriod, volumeMA,
                       macdFast, macdSlow, macdSignal, rsi, kdjPeriod, kdjK, kdjD, atrPeriod]
        return periods.allSatisfy { (2...500).contains($0) }
            && additionalAverages.allSatisfy { (2...500).contains($0.period) }
            && Set(additionalAverages.map(\.id)).count == additionalAverages.count
            && formulas.count <= 12 && Set(formulas.map(\.id)).count == formulas.count
            && !hasDuplicateAverages
            && macdFast < macdSlow
            && sarStep.isFinite && sarMaximum.isFinite && sarStep > 0 && sarStep <= sarMaximum && sarMaximum <= 1
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

    mutating func toggleAverage(id: UUID) {
        guard let index = additionalAverages.firstIndex(where: { $0.id == id }) else { return }
        additionalAverages[index].enabled.toggle()
    }

    mutating func addAverage() {
        let used = Set(enabledAverageKeys)
        let suggested = [10, 30, 60, 100, 120, 200]
        guard let period = (suggested + Array(2...500)).first(where: { !used.contains("EMA:\($0)") }) else { return }
        additionalAverages.append(AdditionalMovingAverage(type: .ema, period: period))
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
        case .kdj: return "KDJ"
        case .atr: return "ATR"
        case .sar: return "SAR"
        case .opi: return "OPI"
        case .chan: return "缠论"
        case .hunt: return "猎杀候选"
        }
    }

    // A line's colour depends only on its type and period; toggling another
    // indicator does not silently change the line's colour.
    private static func averageColor(type: MovingAverageType, period: Int) -> ChartColor {
        if type == .ema && period == 20 {
            return ChartColor(hex: "366EB8")!
        }
        if type == .ema && period == 50 {
            return ChartColor(hex: "F18B31")!
        }
        let colors = ["8952BA", "159A92", "C06077", "A47A31",
                      "416DB0", "C75743", "588047", "8158B1",
                      "297F93", "B85D97", "6D7899", "B07B45"]
        let offset: Int
        switch type {
        case .sma: offset = 0
        case .ema: offset = 4
        case .wma: offset = 8
        }
        return ChartColor(hex: colors[(period * 7 + offset) % colors.count])!
    }

    private static func movingAverage(type: MovingAverageType, period: Int) -> any ChartIndicator {
        let style = IndicatorLineStyle(color: averageColor(type: type, period: period), width: 1.7)
        switch type {
        case .sma: return SMA(period: period, style: style)
        case .ema: return EMA(period: period, style: style)
        case .wma: return WMA(period: period, style: style)
        }
    }

    func indicators() -> [any ChartIndicator] {
        var result: [any ChartIndicator] = []
        for kind in ChartIndicatorKind.allCases where enabled.contains(kind) {
            switch kind {
            case .sma: result.append(Self.movingAverage(type: .sma, period: sma))
            case .emaFast: result.append(Self.movingAverage(type: .ema, period: emaFast))
            case .emaSlow: result.append(Self.movingAverage(type: .ema, period: emaSlow))
            case .wma: result.append(Self.movingAverage(type: .wma, period: wma))
            case .boll: result.append(BollingerBands(period: bollPeriod, multiplier: bollMultiplier))
            case .volume: result.append(Volume(movingAveragePeriod: volumeMA))
            case .macd: result.append(MACD(fast: macdFast, slow: macdSlow, signal: macdSignal))
            case .rsi: result.append(RSI(period: rsi))
            case .kdj: result.append(QihuiKDJ(period: kdjPeriod, kPeriod: kdjK, dPeriod: kdjD))
            case .atr: result.append(QihuiATR(period: atrPeriod))
            case .sar: result.append(QihuiSAR(step: sarStep, maximum: sarMaximum))
            case .opi: result.append(QihuiOpenInterest())
            case .chan: result.append(QihuiChanStructure())
            case .hunt: result.append(QihuiHuntPreview())
            }
        }
        for average in additionalAverages where average.enabled {
            result.append(Self.movingAverage(type: average.type, period: average.period))
        }
        for formula in formulas where formula.enabled {
            if let program = try? FormulaProgram(formula.source) {
                result.append(QihuiFormulaIndicator(definition:formula,program:program))
            }
        }
        return result
    }
}
