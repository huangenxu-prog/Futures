import Foundation

enum MovingAverageType: String, Codable, CaseIterable, Identifiable, Sendable {
    // Keep the historical raw value SMA for old saved simple averages.
    case sma = "SMA"
    case ema = "EMA"
    case wma = "WMA"
    case ema2 = "EMA2"
    case hma = "HMA"
    case dema = "DEMA"
    case tema = "TEMA"
    case smoothSMA = "SMA_WEIGHTED"
    case dma = "DMA"
    case wilder = "WILDER"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .sma: return "MA"
        case .smoothSMA: return "SMA"
        default: return rawValue
        }
    }
}

struct AdditionalMovingAverage: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var type: MovingAverageType = .ema
    var period: Int = 100
    var enabled = true
    // Optional fields preserve all old saved settings.
    var name: String? = nil
    var weight: Int? = nil
    var alpha: Double? = nil

    var smoothingWeight: Int {
        get { weight ?? 1 }
        set { weight = newValue }
    }
    var dynamicAlpha: Double {
        get { alpha ?? 0.2 }
        set { alpha = newValue }
    }
    private var alphaLiteral: String {
        String(format:"%.12f",locale:Locale(identifier:"en_US_POSIX"),dynamicAlpha)
    }
    var isValid: Bool {
        if type == .dma { return dynamicAlpha.isFinite && (0...1).contains(dynamicAlpha) }
        guard (2...500).contains(period) else { return false }
        return type != .smoothSMA || (1...period).contains(smoothingWeight)
    }
    var key: String {
        switch type {
        case .sma: return "SMA:\(period)"
        case .ema2: return "WMA:\(period)"
        case .smoothSMA: return "SMA_WEIGHTED:\(period):\(smoothingWeight)"
        case .dma: return "DMA:\(alphaLiteral)"
        default: return "\(type.rawValue):\(period)"
        }
    }
    var label: String {
        if let name, !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { return name }
        switch type {
        case .dma: return "DMA(\(String(format:"%.4g",dynamicAlpha)))"
        case .smoothSMA: return "SMA(\(period),\(smoothingWeight))"
        default: return "\(type.title)\(period)"
        }
    }
    /// The native MA/EMA/WMA retain their original initialization convention.
    /// New choices reuse the tested formula engine and the close price.
    func expression() throws -> String {
        guard isValid else { throw FormulaFailure("均线参数无效") }
        switch type {
        case .dma: return "DMA(C,\(alphaLiteral))"
        case .smoothSMA: return "SMA(C,\(period),\(smoothingWeight))"
        default: return "\(type.title)(C,\(period))"
        }
    }
}
