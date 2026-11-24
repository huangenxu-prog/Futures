import Foundation

enum CompositionSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case close, open, high, low, hl2, hlc3, ohlc4, weightedClose, volume, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .close: return "收盘价 C"
        case .open: return "开盘价 O"
        case .high: return "最高价 H"
        case .low: return "最低价 L"
        case .hl2: return "高低均价 HL2"
        case .hlc3: return "典型价格 HLC3"
        case .ohlc4: return "四价平均 OHLC4"
        case .weightedClose: return "收盘加权 (3C+H+L+O)/6"
        case .volume: return "成交量 VOL"
        case .custom: return "自定义表达式"
        }
    }
    func expression(custom: String) -> String {
        switch self {
        case .close: return "C"
        case .open: return "O"
        case .high: return "H"
        case .low: return "L"
        case .hl2: return "HL2"
        case .hlc3: return "HLC3"
        case .ohlc4: return "OHLC4"
        case .weightedClose: return "(3*C+H+L+O)/6"
        case .volume: return "VOL"
        case .custom: return custom
        }
    }
}

enum CompositionFunction: String, Codable, CaseIterable, Identifiable, Sendable {
    case ma = "MA", ema = "EMA", sma = "SMA", wma = "WMA", ema2 = "EMA2"
    case hma = "HMA", dema = "DEMA", tema = "TEMA", dma = "DMA", wilder = "WILDER"
    case hhv = "HHV", llv = "LLV", sum = "SUM", std = "STD", ref = "REF", abs = "ABS"
    var id: String { rawValue }
}

enum CompositionColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic = "", blue = "COLORBLUE", yellow = "COLORYELLOW", red = "COLORRED"
    case green = "COLORGREEN", cyan = "COLORCYAN", purple = "COLORMAGENTA", white = "COLORWHITE", black = "COLORBLACK"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "自动"
        case .blue: return "蓝色"
        case .yellow: return "黄色"
        case .red: return "红色"
        case .green: return "绿色"
        case .cyan: return "青色"
        case .purple: return "紫色"
        case .white: return "白色"
        case .black: return "黑色"
        }
    }
}

struct CompositionLayer: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var function: CompositionFunction = .ema
    var period = 20
    var weight = 1
    var alpha = "0.5"

    func wrapping(_ input: String) throws -> String {
        let name = function.rawValue
        if function == .abs { return "\(name)(\(input))" }
        if function == .dma {
            return "\(name)(\(input),\(try FormulaComposition.expression(alpha)))"
        }
        guard ((function == .ref ? 0 : 1)...500).contains(period) else {
            throw FormulaFailure("\(name) 周期超出范围")
        }
        if function == .sma {
            guard (1...period).contains(weight) else { throw FormulaFailure("SMA 权重 M 必须为 1～N") }
            return "\(name)(\(input),\(period),\(weight))"
        }
        return "\(name)(\(input),\(period))"
    }
}

struct CompositionLine: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var source: CompositionSource = .close
    var custom = "(3*C+H+L+O)/6"
    var layers = [CompositionLayer()]
    var color: CompositionColor = .automatic
    var width = 2
    var histogram = false

    func statement(index: Int) throws -> String {
        guard layers.count <= 6, (1...5).contains(width) else {
            throw FormulaFailure("每条曲线最多6层，线宽1～5")
        }
        var value = try FormulaComposition.expression(source.expression(custom: custom))
        for layer in layers { value = try layer.wrapping(value) }
        var styles: [String] = []
        if color != .automatic { styles.append(color.rawValue) }
        if histogram { styles.append("COLORSTICK") }
        else { styles.append("LINETHICK\(width)") }
        return "LINE\(index):\(value),\(styles.joined(separator: ","));"
    }
}

struct FormulaComposition: Codable, Equatable, Sendable {
    var lines = [CompositionLine()]

    // Ensure a field represents exactly one expression, not injected
    // statements or drawing properties. Nested function commas are allowed.
    static func expression(_ raw: String) throws -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.utf8.count <= 512, !s.contains(";"), !s.contains(":") else {
            throw FormulaFailure("请输入单个有效表达式，不能包含赋值或分号")
        }
        var depth = 0
        for c in s {
            if c == "(" { depth += 1 }
            if c == ")" { depth -= 1 }
            if depth < 0 || (c == "," && depth == 0) {
                throw FormulaFailure("表达式括号或逗号不匹配")
            }
        }
        guard depth == 0 else { throw FormulaFailure("表达式括号不匹配") }
        return "(\(s))"
    }

    func source() throws -> String {
        guard (1...8).contains(lines.count) else { throw FormulaFailure("每个组合指标需要1～8条输出") }
        var statements: [String] = []
        for (i,line) in lines.enumerated() {
            statements.append(try line.statement(index:i+1))
        }
        return statements.joined(separator:"\n")
    }

    func validatedSource() throws -> String {
        let text = try source()
        _ = try FormulaProgram(text)
        return text
    }
}
