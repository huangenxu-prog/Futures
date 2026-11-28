import Foundation
import TradingChart

enum ChartIndicatorKind: String, Codable, CaseIterable, Hashable, Identifiable {
    case sma, emaFast, emaSlow, wma, boll, volume, macd, rsi, kdj, atr, sar, opi, chan, hunt, intraday
    var id: String { rawValue }
    static var available: [Self] { allCases.filter { $0 != .chan && $0 != .hunt } }

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
        case .hunt: return "猎杀"
        case .intraday: return "分时"
        }
    }
}

struct ChartDisplaySettings: Codable, Equatable {
    // Toolbar availability and chart drawing are independent.
    var enabled: Set<ChartIndicatorKind> = [.macd]
    var toolbarKinds: Set<ChartIndicatorKind> = [.boll,.macd,.volume]
    var toolbarAverages: Set<MovingAverageType> = [.sma,.ema,.wma]
    var activeAverages: Set<MovingAverageType> = [.ema]
    var toolbarFormulas: Set<UUID> = []
    var sma = 20
    var emaFast = 20
    var emaSlow = 50
    var wma = 20
    var averageColors: [String: String] = [:]
    var averageWidths: [String: Double] = [:]
    var averageLineTypes: [String: String] = [:]
    var additionalAverages: [AdditionalMovingAverage] = [AdditionalMovingAverage(type:.ema,period:20),AdditionalMovingAverage(type:.ema,period:50),AdditionalMovingAverage(type:.sma,period:20),AdditionalMovingAverage(type:.wma,period:20)]
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

    // New indicator schema; reset of previous indicator preferences was approved.
    private static let key = "qihui.chart.custom-indicator-settings.v2"

    init() {}

    // Decode new-schema preferences, allowing missing optional fields.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try c.decodeIfPresent(Set<ChartIndicatorKind>.self, forKey: .enabled) ?? enabled).subtracting([.chan, .hunt])
        toolbarKinds = try c.decodeIfPresent(Set<ChartIndicatorKind>.self,forKey:.toolbarKinds) ?? toolbarKinds
        toolbarAverages = try c.decodeIfPresent(Set<MovingAverageType>.self,forKey:.toolbarAverages) ?? toolbarAverages
        activeAverages = try c.decodeIfPresent(Set<MovingAverageType>.self,forKey:.activeAverages) ?? activeAverages
        toolbarFormulas = try c.decodeIfPresent(Set<UUID>.self,forKey:.toolbarFormulas) ?? []
        sma = try c.decodeIfPresent(Int.self, forKey: .sma) ?? sma
        emaFast = try c.decodeIfPresent(Int.self, forKey: .emaFast) ?? emaFast
        emaSlow = try c.decodeIfPresent(Int.self, forKey: .emaSlow) ?? emaSlow
        wma = try c.decodeIfPresent(Int.self, forKey: .wma) ?? wma
        averageColors = try c.decodeIfPresent([String: String].self, forKey: .averageColors) ?? [:]
        averageWidths = try c.decodeIfPresent([String: Double].self, forKey: .averageWidths) ?? [:]
        averageLineTypes = try c.decodeIfPresent([String: String].self, forKey: .averageLineTypes) ?? [:]
        additionalAverages = try c.decodeIfPresent([AdditionalMovingAverage].self, forKey: .additionalAverages) ?? additionalAverages
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
        keys += additionalAverages.filter(\.enabled).map(\.key)
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
            && additionalAverages.allSatisfy(\.isValid)
            && Set(additionalAverages.map(\.id)).count == additionalAverages.count
            && formulas.count <= 12 && Set(formulas.map(\.id)).count == formulas.count
            && !hasDuplicateAverages
            && macdFast < macdSlow
            && sarStep.isFinite && sarMaximum.isFinite && sarStep > 0 && sarStep <= sarMaximum && sarMaximum <= 1
            && bollMultiplier.isFinite && bollMultiplier >= 0.1 && bollMultiplier <= 10
    }

    static let mainKinds: [ChartIndicatorKind] = [.boll,.sar]
    static let subKinds: [ChartIndicatorKind] = [.macd,.rsi,.kdj,.atr,.volume,.opi,.intraday]
    mutating func setToolbarKind(_ kind:ChartIndicatorKind,_ visible:Bool) {
        if visible { toolbarKinds.insert(kind) } else { toolbarKinds.remove(kind); enabled.remove(kind) }
    }
    mutating func setToolbarAverage(_ type:MovingAverageType,_ visible:Bool) {
        if visible { toolbarAverages.insert(type) } else { toolbarAverages.remove(type); activeAverages.remove(type) }
    }
    mutating func toggleAverageGroup(_ type:MovingAverageType) {
        guard toolbarAverages.contains(type) else { return }
        if activeAverages.contains(type) { activeAverages.remove(type) } else { activeAverages.insert(type) }
    }
    mutating func setToolbarFormula(_ id:UUID,_ visible:Bool) {
        if visible { toolbarFormulas.insert(id) } else { toolbarFormulas.remove(id); if let i=formulas.firstIndex(where:{$0.id==id}) { formulas[i].enabled=false } }
    }
    func toggle(_ kind: ChartIndicatorKind) -> Self {
        var changed = self
        guard toolbarKinds.contains(kind) else { return changed }
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
        case .hunt: return "猎杀"
        case .intraday: return "分时"
        }
    }

    // A line's colour depends only on its type and period; toggling another
    // indicator does not silently change the line's colour.
    static func averageColor(type: MovingAverageType, period: Int) -> ChartColor {
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
        case .wma, .ema2: offset = 8
        case .hma: offset = 1
        case .dema: offset = 2
        case .tema: offset = 3
        case .smoothSMA: offset = 5
        case .dma: offset = 6
        case .wilder: offset = 7
        }
        return ChartColor(hex: colors[(period * 7 + offset) % colors.count])!
    }

    func averageStyle(key: String, type: MovingAverageType, period: Int) -> IndicatorLineStyle {
        let color = averageColors[key].flatMap { ChartColor(hex: $0) } ?? Self.averageColor(type: type, period: period)
        let width = averageWidths[key].flatMap { $0.isFinite && (0.5...4).contains($0) ? $0 : nil } ?? 1.7
        let dash: [Double] = averageLineTypes[key] == "dash" ? [5,3] : averageLineTypes[key] == "dot" ? [1,3] : []
        return IndicatorLineStyle(color: color, width: width, dash: dash)
    }
    private static func movingAverage(type: MovingAverageType, period: Int, style: IndicatorLineStyle) -> any ChartIndicator {
        switch type {
        case .sma: return SMA(period: period, style: style)
        case .ema: return EMA(period: period, style: style)
        case .wma: return WMA(period: period, style: style)
        default:
            // The legacy fixed slots only use the three native types.
            // Extended rows are routed through the overload below.
            return SMA(period: period, style: style)
        }
    }

    private func movingAverage(_ average: AdditionalMovingAverage) -> (any ChartIndicator)? {
        switch average.type {
        case .sma,.ema,.wma:
            return Self.movingAverage(type:average.type,period:average.period,style:averageStyle(key:average.id.uuidString,type:average.type,period:average.period))
        default:
            guard let expression = try? average.expression(),
                  let program = try? FormulaProgram("A:"+expression+";") else { return nil }
            let style = averageStyle(key:average.id.uuidString,type:average.type,period:average.type == .dma ? 20 : average.period)
            return QihuiExtendedMovingAverage(average:average,program:program,style:style)
        }
    }

    func indicators(darkAppearance: Bool = true) -> [any ChartIndicator] {
        var result: [any ChartIndicator] = []
        for kind in ChartIndicatorKind.available where enabled.contains(kind) && toolbarKinds.contains(kind) {
            switch kind {
            case .sma: result.append(Self.movingAverage(type: .sma, period: sma, style: averageStyle(key: ChartIndicatorKind.sma.rawValue, type: .sma, period: sma)))
            case .emaFast: result.append(Self.movingAverage(type: .ema, period: emaFast, style: averageStyle(key: ChartIndicatorKind.emaFast.rawValue, type: .ema, period: emaFast)))
            case .emaSlow: result.append(Self.movingAverage(type: .ema, period: emaSlow, style: averageStyle(key: ChartIndicatorKind.emaSlow.rawValue, type: .ema, period: emaSlow)))
            case .wma: result.append(Self.movingAverage(type: .wma, period: wma, style: averageStyle(key: ChartIndicatorKind.wma.rawValue, type: .wma, period: wma)))
            case .boll: result.append(BollingerBands(period: bollPeriod, multiplier: bollMultiplier))
            case .volume: result.append(Volume(movingAveragePeriod: volumeMA))
            case .macd:
                let diff = IndicatorLineStyle(color: ChartColor(hex: darkAppearance ? "FFFFFF" : "242D3B")!)
                let dea = IndicatorLineStyle(color: ChartColor(hex: darkAppearance ? "FFD34E" : "996000")!)
                result.append(MACD(fast: macdFast, slow: macdSlow, signal: macdSignal,
                                   macdStyle: diff, signalStyle: dea))
            case .rsi: result.append(RSI(period: rsi))
            case .kdj: result.append(QihuiKDJ(period: kdjPeriod, kPeriod: kdjK, dPeriod: kdjD))
            case .atr: result.append(QihuiATR(period: atrPeriod))
            case .sar: result.append(QihuiSAR(step: sarStep, maximum: sarMaximum))
            case .opi: result.append(QihuiOpenInterest())
            case .chan: break
            case .hunt: break
            case .intraday: break // Independent minute-series pane, not a main-period indicator.
            }
        }
        for average in additionalAverages where average.enabled && toolbarAverages.contains(average.type) && activeAverages.contains(average.type) {
            if let indicator = movingAverage(average) { result.append(indicator) }
        }
        for formula in formulas where formula.enabled && toolbarFormulas.contains(formula.id) {
            if let program = try? FormulaProgram(formula.source) {
                result.append(QihuiFormulaIndicator(definition:formula,program:program))
            }
        }
        return result
    }
}
