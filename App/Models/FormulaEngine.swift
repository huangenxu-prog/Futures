import Foundation

// Sandboxed formula language. Only numeric arrays and a fixed function table.
// No JavaScript, dynamic execution, network, file I/O or future references.
struct FormulaFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

struct FormulaBar: Sendable {
    let open, high, low, close: Double
    let volume: Double?
    let openInterest: Double?
    let closeInterest: Double?
    init(open: Double, high: Double, low: Double, close: Double, volume: Double?,
         openInterest: Double? = nil, closeInterest: Double? = nil) {
        self.open = open; self.high = high; self.low = low; self.close = close
        self.volume = volume; self.openInterest = openInterest; self.closeInterest = closeInterest
    }
}
enum FormulaPlatform: String, Codable, CaseIterable, Sendable {
    case native, tongdaxin, hexin, wenhua

    var title: String {
        switch self {
        case .native: return "期汇原生"
        case .tongdaxin: return "通达信"
        case .hexin: return "同花顺期货通"
        case .wenhua: return "文华财经"
        }
    }
}

struct FormulaDefinition: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name = "自定义指标"
    var source = "EMA20:EMA(CLOSE,20),COLORBLUE;\nEMA50:EMA(CLOSE,50),COLORYELLOW;"
    var overlay = true
    var enabled = false
    var composition: FormulaComposition? = nil
    var parameters: String? = nil
    var platform: FormulaPlatform? = nil
    func program() throws -> FormulaProgram {
        try FormulaProgram(source, platform: effectivePlatform, parameters: parameters ?? "")
    }
    var effectivePlatform: FormulaPlatform { platform ?? .native }
}

/// Only ASCII letters/underscore and Han ideographs are allowed to start
/// a variable. ASCII digits are allowed subsequently. No punctuation,
/// spaces, invisible controls or executable constructs are introduced.
enum FormulaIdentifier {
    static func isStart(_ c:Character) -> Bool {
        if c.isASCII { return c.isLetter || c == "_" }
        guard c.unicodeScalars.count == 1,let scalar = c.unicodeScalars.first else { return false }
        let v = scalar.value
        return (0x3400...0x4DBF).contains(v) || (0x4E00...0x9FFF).contains(v)
            || (0x20000...0x2FA1F).contains(v) || (0x30000...0x323AF).contains(v)
    }
    static func isPart(_ c:Character) -> Bool { isStart(c) || (c.isASCII && c.isNumber) }
    static func valid(_ name:String) -> Bool {
        guard let first = name.first,isStart(first),name.allSatisfy(isPart) else { return false }
        return name.uppercased() != "AND" && name.uppercased() != "OR"
    }
}

private enum FormulaToken: Equatable {
    case name(String), number(Double), symbol(String), text(String), end
}
private indirect enum FormulaExpr: Sendable {
    case constant(Double), variable(String), text(String), unary(String, FormulaExpr)
    case binary(String, FormulaExpr, FormulaExpr)
    case call(String, [FormulaExpr])
}
private struct FormulaStatement: Sendable {
    let name: String
    let expr: FormulaExpr
    let visible: Bool
    let color: String?
    let width: Double
    let histogram: Bool
    let drawing: Bool
    let fontSize: Double?
}

struct FormulaSegment: Sendable, Equatable {
    let startIndex: Int
    let endIndex: Int
    let startValue: Double
    let endValue: Double
}

enum FormulaDrawing: Sendable {
    case stick(starts: [Double?], width: Double, hollow: Bool)
    case signal(text: String)
    case segments([FormulaSegment])
}

struct FormulaOutput: Sendable {
    let name: String
    let values: [Double?]
    let color: String?
    let width: Double
    let histogram: Bool
    var drawing: FormulaDrawing? = nil
    var fontSize: Double? = nil
}

struct FormulaProgram: Sendable {
    private let statements: [FormulaStatement]

    init(_ source: String, platform: FormulaPlatform = .native, parameters: String = "") throws {
        var definitions = ""
        if platform != .native {
            guard parameters.utf8.count <= 1024 else { throw FormulaFailure("参数表过长") }
            for entry in parameters.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "，" }) {
                let pair = entry.split(separator: "=", omittingEmptySubsequences: false)
                guard pair.count == 2, FormulaIdentifier.valid(String(pair[0])),
                      !pair[1].isEmpty, pair[1].allSatisfy({ $0.isASCII && ($0.isNumber || ".-+".contains($0)) }),
                      Double(pair[1])?.isFinite == true else { throw FormulaFailure("参数请按 名称=数值 填写，例如 N=9 M1=3") }
                definitions += "\(pair[0]):=\(pair[1]);"
            }
        }
        var parser = try FormulaParser(definitions + source, platform: platform)
        statements = try parser.parse()
        // Validate even an empty chart: functions and variables cannot be
        // deferred until live data happens to arrive.
        _ = try evaluate([])
    }

    func evaluate(_ bars: [FormulaBar]) throws -> [FormulaOutput] {
        guard bars.count <= 20_000 else { throw FormulaFailure("K线数量超出公式计算上限") }
        let n = bars.count
        var env: [String: [Double?]] = [
            "OPEN": bars.map { $0.open }, "HIGH": bars.map { $0.high },
            "LOW": bars.map { $0.low }, "CLOSE": bars.map { $0.close },
            "VOL": bars.map { $0.volume }
        ]
        env["O"] = env["OPEN"]; env["H"] = env["HIGH"]
        env["L"] = env["LOW"]; env["C"] = env["CLOSE"]; env["V"] = env["VOL"]
        env["VOLUME"] = env["VOL"]
        env["DRAWNULL"] = Array(repeating: nil, count: n)
        env["OPEN_OI"] = bars.map { $0.openInterest }
        env["OPI"] = bars.map { $0.closeInterest }
        env["OI"] = env["OPI"]; env["CLOSE_OI"] = env["OPI"]
        env["OI_CHANGE"] = bars.map { bar in
            guard let opening = bar.openInterest, let closing = bar.closeInterest else { return nil }
            return closing - opening
        }
        env["HL2"] = bars.map { ($0.high+$0.low)/2 }
        env["HLC3"] = bars.map { ($0.high+$0.low+$0.close)/3 }
        env["OHLC4"] = bars.map { ($0.open+$0.high+$0.low+$0.close)/4 }
        var results: [FormulaOutput] = []
        var constants: [String: Double] = [:]
        for statement in statements {
            let expr = Self.substitute(statement.expr, constants)
            if statement.drawing {
                let resolved = FormulaStatement(name:statement.name,expr:expr,visible:statement.visible,color:statement.color,width:statement.width,histogram:statement.histogram,drawing:true,fontSize:statement.fontSize)
                results.append(try Self.draw(resolved, env, n))
                continue
            }
            guard env[statement.name] == nil else {
                throw FormulaFailure("变量重复定义：\(statement.name)")
            }
            let values = try Self.eval(expr, env, n)
            if case .constant(let value) = expr { constants[statement.name] = value }
            env[statement.name] = values
            if statement.visible {
                results.append(FormulaOutput(name: statement.name, values: values,
                    color: statement.color, width: statement.width, histogram: statement.histogram))
            }
        }
        return results
    }

    private static func substitute(_ expr: FormulaExpr, _ constants: [String:Double]) -> FormulaExpr {
        switch expr {
        case .variable(let name): return constants[name].map { .constant($0) } ?? expr
        case .unary(let op,let v): return .unary(op,substitute(v,constants))
        case .binary(let op,let a,let b): return .binary(op,substitute(a,constants),substitute(b,constants))
        case .call(let name,let args): return .call(name,args.map { substitute($0,constants) })
        default: return expr
        }
    }

    private static func draw(_ statement: FormulaStatement, _ env: [String:[Double?]], _ n: Int) throws -> FormulaOutput {
        guard case .call(let name, let args) = statement.expr else { throw FormulaFailure("无效绘图语句") }
        let required = name == "STICKLINE" || name == "DRAWLINE" ? 5 : 3
        guard args.count == required else { throw FormulaFailure("\(name) 需要 \(required) 个参数") }
        let condition = try eval(args[0],env,n)
        let first = try eval(args[1],env,n)
        if name == "DRAWLINE" {
            let endCondition = try eval(args[2],env,n)
            let endValue = try eval(args[3],env,n)
            guard case .constant(let extend) = args[4], extend == 0 else {
                throw FormulaFailure("DRAWLINE 当前仅支持 EXTEND=0（不延长）")
            }
            // Pair the latest valid start with the first strictly later end.
            // A completed segment is historical annotation: it appears only
            // when its end is known, not as a signal at the earlier start.
            var start: (index:Int,value:Double)?
            var segments: [FormulaSegment] = []
            var values = [Double?](repeating:nil,count:n)
            for i in 0..<n {
                if let c = endCondition[i], c != 0, let value = endValue[i],
                   let pending = start, pending.index < i {
                    segments.append(FormulaSegment(startIndex:pending.index,endIndex:i,
                        startValue:pending.value,endValue:value))
                    values[i] = value
                    start = nil
                }
                if let c = condition[i], c != 0, let value = first[i] {
                    start = (i,value)
                }
            }
            return FormulaOutput(name:name,values:values,color:statement.color,width:statement.width,
                                 histogram:false,drawing:.segments(segments))
        }
        if name == "STICKLINE" {
            let second = try eval(args[2],env,n)
            guard case .constant(let width) = args[3], (0...10).contains(width),
                  case .constant(let empty) = args[4], empty == 0 || empty == 1 else {
                throw FormulaFailure("STICKLINE 宽度为0～10，空心参数为0或1")
            }
            var ends = [Double?](repeating:nil,count:n)
            var starts = ends
            for i in 0..<n {
                if let c = condition[i], c != 0, let a = first[i], let b = second[i],
                   a.isFinite, b.isFinite { starts[i] = a; ends[i] = b }
            }
            return FormulaOutput(name:name,values:ends,color:statement.color,width:width,histogram:false,
                                 drawing:.stick(starts:starts,width:width,hollow:empty == 1))
        }
        let label: String
        if name == "DRAWICON" {
            let icons: [Int:String] = [1:"↑",2:"↓",3:"●",4:"×"]
            guard case .constant(let code) = args[2], code >= 1, code <= 4,
                  code.rounded() == code, let icon = icons[Int(code)] else {
                throw FormulaFailure("DRAWICON 暂支持编号1～4（↑、↓、●、×）")
            }
            label = icon
        } else {
            guard case .text(let text) = args[2], !text.isEmpty, text.count <= 32 else {
                throw FormulaFailure("DRAWTEXT 文字需为引号内1～32个字符")
            }
            label = text
        }
        let values: [Double?] = zip(condition,first).map { c,v in
            guard let c, c != 0, let v, v.isFinite else { return nil }
            return v
        }
        return FormulaOutput(name:name,values:values,color:statement.color,width:statement.width,
                             histogram:false,drawing:.signal(text:label),fontSize:statement.fontSize)
    }

    private static func dynamicExtreme(_ x: [Double?], periods: [Double?], highest: Bool) -> [Double?] {
        guard !x.isEmpty else { return [] }
        func combine(_ a: Double?, _ b: Double?) -> Double? {
            guard let a, let b else { return nil }; return highest ? max(a,b) : min(a,b)
        }
        var table = [x], logs = Array(repeating:0,count:x.count+1)
        if x.count >= 2 { for i in 2...x.count { logs[i] = logs[i/2]+1 } }
        var span = 2
        while span <= x.count {
            let prev = table[table.count-1], half = span/2
            table.append((0...(x.count-span)).map { combine(prev[$0],prev[$0+half]) })
            span *= 2
        }
        return x.indices.map { i in
            guard let p = periods[i], p.isFinite, p.rounded() == p, p >= 1, p <= Double(i+1) else { return nil }
            let length = Int(p), level = logs[length], width = 1 << level
            return combine(table[level][i-length+1],table[level][i-width+1])
        }
    }

    private static func finite(_ x: Double) -> Double? { x.isFinite ? x : nil }

    private static func exponential(_ x: [Double?], alpha: Double) -> [Double?] {
        var previous: Double?
        return x.map { v in
            guard let v else { previous = nil; return nil }
            previous = finite(previous.map { $0 + alpha*(v-$0) } ?? v)
            return previous
        }
    }

    // Weighted rolling sum: each existing sample loses one unit of
    // weight when the window advances, then the newest gains weight N.
    private static func weightedAverage(_ x: [Double?], period p: Int) -> [Double?] {
        var sum = 0.0, weighted = 0.0, missing = 0
        let denominator = Double(p)*Double(p+1)/2
        return x.indices.map { i in
            if i >= p {
                weighted -= sum
                if let old = x[i-p] { sum -= old } else { missing -= 1 }
            }
            if let value = x[i] {
                sum += value
                weighted += Double(min(i+1,p))*value
            } else { missing += 1 }
            guard i >= p-1, missing == 0 else { return nil }
            return finite(weighted/denominator)
        }
    }

    private static func period(_ expr: FormulaExpr, zero: Bool = false) throws -> Int {
        guard case .constant(let value) = expr, value.isFinite,
              value.rounded() == value, value >= (zero ? 0 : 1), value <= 500 else {
            throw FormulaFailure("周期参数必须为\(zero ? "0" : "1")～500的整数常量")
        }
        return Int(value)
    }

    private static func eval(_ expr: FormulaExpr, _ env: [String:[Double?]], _ n: Int) throws -> [Double?] {
        switch expr {
        case .constant(let x): return Array(repeating: x, count: n)
        case .text: throw FormulaFailure("文字只能用于 DRAWTEXT")
        case .variable(let name):
            guard let value = env[name] else { throw FormulaFailure("未知变量：\(name)") }
            return value
        case .unary(let op, let operand):
            return try eval(operand,env,n).map { v in
                guard let v else { return nil }
                return op == "-" ? finite(-v) : v
            }
        case .binary(let op, let lhs, let rhs):
            let a = try eval(lhs,env,n), b = try eval(rhs,env,n)
            return zip(a,b).map { x,y in
                guard let x, let y else { return nil }
                switch op {
                case "+": return finite(x+y)
                case "-": return finite(x-y)
                case "*": return finite(x*y)
                case "/": return y == 0 ? nil : finite(x/y)
                case ">": return x > y ? 1 : 0
                case "<": return x < y ? 1 : 0
                case ">=": return x >= y ? 1 : 0
                case "<=": return x <= y ? 1 : 0
                case "=", "==": return x == y ? 1 : 0
                case "!=", "<>": return x != y ? 1 : 0
                case "AND": return x != 0 && y != 0 ? 1 : 0
                case "OR": return x != 0 || y != 0 ? 1 : 0
                default: return nil
                }
            }
        case .call(let rawName, let args):
            let aliases = ["EMA2":"WMA","CROSSUP":"CROSS","IFN":"IF"]
            if rawName == "CROSSDOWN", args.count == 2 { return try eval(.call("CROSS",[args[1],args[0]]),env,n) }
            let fn = aliases[rawName] ?? rawName
            let arity: [String:Int] = [
                "MA":2,"EMA":2,"SMA":3,"WMA":2,"HMA":2,"DEMA":2,"TEMA":2,"DMA":2,"WILDER":2,
                "HHV":2,"LLV":2,"SUM":2,"STD":2,
                "#WHEMA":2,"#WHSMA":3,"#WHSUM":2,"#WHCOUNT":2,"#WHMA":2,"#WHEVERY":2,
                "#WHHHV":2,"#WHLLV":2,"#TDXSUM":2,"BETWEEN":3,"BARSSINCE":1,
                "STDP":2,"VAR":2,"VARP":2,"#SAMPLESTD":2,"BARSLASTCOUNT":1,
                "REF":2,"COUNT":2,"IF":3,"CROSS":2,"BARSLAST":1,"ABS":1,"MAX":2,"MIN":2,
                "SQRT":1,"POW":2,"EXP":1,"LN":1,"LOG":1,"SIGN":1,
                "FLOOR":1,"CEILING":1,"INTPART":1,"SIN":1,"COS":1,"TAN":1,
                "RANGE":3,"VALUEWHEN":2,"FILTER":2,"HHVBARS":2,"LLVBARS":2,"EXIST":2,"EVERY":2,"NOT":1,"BARSCOUNT":1
            ]
            guard let expected = arity[fn] else { throw FormulaFailure("暂不支持函数：\(fn)") }
            guard args.count == expected else { throw FormulaFailure("\(fn) 需要 \(expected) 个参数") }
            let x = try eval(args[0],env,n)
            if fn == "RANGE" || fn == "BETWEEN" {
                let low = try eval(args[1],env,n), high = try eval(args[2],env,n)
                return x.indices.map { i in
                    guard let v = x[i], let a = low[i], let b = high[i] else { return nil }
                    if fn == "BETWEEN" { return min(a,b) <= v && v <= max(a,b) ? 1 : 0 }
                    return v > a && v < b ? 1 : 0
                }
            }
            if ["SQRT","EXP","LN","LOG","SIGN","FLOOR","CEILING","INTPART","SIN","COS","TAN"].contains(fn) {
                return x.map { value in
                    guard let v = value else { return nil }
                    switch fn {
                    case "SQRT": return v >= 0 ? finite(sqrt(v)) : nil
                    case "EXP": return finite(exp(v))
                    case "LN": return v > 0 ? finite(log(v)) : nil
                    case "LOG": return v > 0 ? finite(log10(v)) : nil
                    case "SIGN": return v > 0 ? 1 : (v < 0 ? -1 : 0)
                    case "FLOOR": return finite(floor(v))
                    case "CEILING": return finite(ceil(v))
                    case "INTPART": return finite(v.rounded(.towardZero))
                    case "SIN": return finite(sin(v))
                    case "COS": return finite(cos(v))
                    case "TAN": return finite(tan(v))
                    default: return nil
                    }
                }
            }
            if fn == "POW" {
                let y = try eval(args[1],env,n)
                return zip(x,y).map { a,b in
                    guard let a, let b else { return nil }
                    return finite(pow(a,b))
                }
            }
            if fn == "ABS" { return x.map { $0.map(abs) } }
            if fn == "NOT" { return x.map { $0.map { $0 == 0 ? 1.0 : 0.0 } } }
            if fn == "#WHEMA" || fn == "#WHSMA" {
                let p = try period(args[1])
                let m = fn == "#WHSMA" ? try period(args[2]) : 1
                guard m <= p else { throw FormulaFailure("SMA 权重超过周期") }
                var previous: Double?, count = 0
                return x.map { value in
                    guard let value else { previous = nil; count = 0; return nil }
                    count = min(p,count+1)
                    let alpha = fn == "#WHEMA" ? 2.0/Double(count+1) : Double(m)/Double(count)
                    previous = finite(previous.map { $0 + alpha*(value-$0) } ?? value)
                    return previous
                }
            }
            if fn == "#WHHHV" || fn == "#WHLLV" {
                let lengths = try eval(args[1],env,n)
                if case .constant = args[1] { _ = try period(args[1],zero:true) }
                let available = lengths.enumerated().map { i, length -> Double? in
                    guard let length, length >= 0, length.rounded() == length else { return nil }
                    return length == 0 ? Double(i+1) : min(length,Double(i+1))
                }
                return dynamicExtreme(x,periods:available,highest:fn == "#WHHHV")
            }
            if ["#WHSUM","#WHCOUNT","#WHMA","#WHEVERY","#TDXSUM"].contains(fn) {
                let lengths = try eval(args[1],env,n)
                if fn == "#TDXSUM" { _ = try period(args[1],zero:true) }
                else if case .constant = args[1] { _ = try period(args[1],zero:true) }
                var totals = [0.0], valid = [0]
                let countTrue = fn == "#WHCOUNT" || fn == "#WHEVERY"
                for value in x {
                    let term = value.map { countTrue ? ($0 == 0 ? 0.0 : 1.0) : $0 } ?? 0
                    totals.append(totals[totals.count-1] + term)
                    valid.append(valid[valid.count-1] + (value == nil ? 0 : 1))
                }
                return x.indices.map { i in
                    guard let length = lengths[i], length >= 0, length.rounded() == length else { return nil }
                    if fn == "#WHMA" || fn == "#WHEVERY" {
                        if length == 0 || length > Double(i+1) { return fn == "#WHEVERY" ? 0 : nil }
                    }
                    let end = i+1
                    let start = length == 0 ? 0 : end-Int(min(Double(end),length))
                    let observations = valid[end]-valid[start]
                    guard observations > 0, x[i] != nil else { return nil }
                    let total = totals[end]-totals[start]
                    if fn == "#WHMA" { return observations == end-start ? finite(total/length) : nil }
                    if fn == "#WHEVERY" { return total == length ? 1 : 0 }
                    return finite(total)
                }
            }
            if fn == "BARSSINCE" {
                var first: Int?
                return x.enumerated().map { i, value in
                    guard let value else { return nil }
                    if first == nil && value != 0 { first = i }
                    return first.map { Double(i-$0) }
                }
            }
            if fn == "BARSLASTCOUNT" {
                var run = 0
                return x.map { value in
                    guard let value else { run = 0; return nil }
                    run = value == 0 ? 0 : run + 1
                    return Double(run)
                }
            }
            if fn == "BARSCOUNT" {
                var count = 0
                return x.map { v in
                    guard v != nil else { return nil }
                    count += 1
                    return Double(count)
                }
            }
            if fn == "VALUEWHEN" {
                let values = try eval(args[1],env,n)
                var previous: Double?
                return x.indices.map { i in
                    guard let condition = x[i] else { return nil }
                    if condition != 0 { previous = values[i] }
                    return previous
                }
            }
            if fn == "REF" {
                // Literal offsets fail at validation if invalid. Dynamic
                // offsets may only reference present or earlier bars.
                if case .constant(let offset) = args[1] {
                    guard offset.rounded() == offset, (0...20_000).contains(offset) else {
                        throw FormulaFailure("REF 偏移必须是0～20000的整数")
                    }
                } else if case .unary("-",.constant) = args[1] {
                    throw FormulaFailure("REF 不支持未来引用")
                }
                let offsets = try eval(args[1],env,n)
                return x.indices.map { i in
                    guard let offset = offsets[i], offset.isFinite, offset.rounded() == offset,
                          offset >= 0, offset <= Double(i) else { return nil }
                    return x[i-Int(offset)]
                }
            }
            if fn == "FILTER" {
                let p = try period(args[1],zero:true)
                var last: Int?
                return x.indices.map { i in
                    guard let v = x[i] else { return nil }
                    guard v != 0 else { return 0 }
                    if let last, i-last <= p { return 0 }
                    last = i
                    return 1
                }
            }
            if fn == "BARSLAST" {
                var last: Int?
                return x.enumerated().map { i,v in
                    guard let v else { return nil }
                    if v != 0 { last = i }
                    return last.map { Double(i-$0) }
                }
            }
            if ["IF","CROSS","MAX","MIN"].contains(fn) {
                let y = try eval(args[1],env,n)
                if fn == "IF" {
                    let z = try eval(args[2],env,n)
                    return x.indices.map { i in x[i].flatMap { $0 != 0 ? y[i] : z[i] } }
                }
                if fn == "CROSS" {
                    return x.indices.map { i in
                        guard i > 0, let a = x[i], let b = y[i],
                              let pa = x[i-1], let pb = y[i-1] else { return nil }
                        return a > b && pa <= pb ? 1 : 0
                    }
                }
                return zip(x,y).map { a,b in
                    guard let a, let b else { return nil }
                    return fn == "MAX" ? max(a,b) : min(a,b)
                }
            }
            if fn == "DMA" {
                // Accept an arbitrary alpha series in [0,1]. Invalid or
                // missing samples yield missing output and reset the seed.
                let alpha = try eval(args[1],env,n)
                var previous: Double?
                return zip(x,alpha).map { v,a in
                    guard let v, let a, a.isFinite, (0...1).contains(a) else {
                        previous = nil; return nil
                    }
                    previous = finite(previous.map { $0 + a*(v-$0) } ?? v)
                    return previous
                }
            }
            if (fn == "HHV" || fn == "LLV"), case .constant = args[1] {} else if fn == "HHV" || fn == "LLV" {
                let periods = try eval(args[1],env,n)
                // Sparse table: O(n log n) construction, O(1) per variable window.
                return Self.dynamicExtreme(x,periods:periods,highest:fn == "HHV")
            }
            let p = try period(args[1],zero: fn == "REF")
            if ["#SAMPLESTD","STDP","VAR","VARP"].contains(fn) {
                let sample = fn == "#SAMPLESTD" || fn == "VAR"
                let divisor = Double(sample ? p-1 : p)
                // Center on a nearby observation and periodically rebuild to bound drift.
                var anchor = 0.0, sum = 0.0, squares = 0.0, valid = 0
                return x.indices.map { i in
                    if i % p == 0 {
                        anchor = x[i] ?? 0
                        sum = 0; squares = 0; valid = 0
                        for j in max(0,i-p+1)..<i {
                            if let value = x[j] {
                                let delta = value-anchor
                                sum += delta; squares += delta*delta; valid += 1
                            }
                        }
                    } else if i >= p, let old = x[i-p] {
                        let delta = old-anchor
                        sum -= delta; squares -= delta*delta; valid -= 1
                    }
                    if let value = x[i] {
                        let delta = value-anchor
                        sum += delta; squares += delta*delta; valid += 1
                    }
                    guard valid == p, divisor > 0 else { return nil }
                    let variance = max(0,squares-sum*sum/Double(p))/divisor
                    return finite(fn == "VAR" || fn == "VARP" ? variance : sqrt(variance))
                }
            }
            if fn == "HMA" {
                let half = max(1,p/2)
                let root = max(1,Int(sqrt(Double(p))))
                let short = weightedAverage(x,period:half)
                let long = weightedAverage(x,period:p)
                let difference: [Double?] = zip(short,long).map { a,b in
                    guard let a, let b else { return nil }
                    return finite(2*a-b)
                }
                return weightedAverage(difference,period:root)
            }
            if fn == "WMA" {
                return weightedAverage(x,period:p)
            }
            if fn == "DEMA" || fn == "TEMA" {
                let e1 = exponential(x,alpha:2/Double(p+1))
                let e2 = exponential(e1,alpha:2/Double(p+1))
                if fn == "DEMA" {
                    return zip(e1,e2).map { a,b in
                        guard let a, let b else { return nil }
                        return finite(2*a-b)
                    }
                }
                let e3 = exponential(e2,alpha:2/Double(p+1))
                return e1.indices.map { i in
                    guard let a = e1[i], let b = e2[i], let c = e3[i] else { return nil }
                    return finite(3*a-3*b+c)
                }
            }
            if fn == "WILDER" {
                var count = 0, sum = 0.0
                var previous: Double?
                return x.map { v in
                    guard let v else { count = 0; sum = 0; previous = nil; return nil }
                    if let old = previous {
                        previous = finite(old+(v-old)/Double(p))
                    } else {
                        count += 1; sum += v
                        if count == p { previous = finite(sum/Double(p)) }
                    }
                    return previous
                }
            }
            if fn == "EMA" || fn == "SMA" {
                var alpha = 2.0 / Double(p+1)
                if fn == "SMA" {
                    let m = try period(args[2])
                    guard m <= p else { throw FormulaFailure("SMA 的权重 M 不能大于 N") }
                    alpha = Double(m) / Double(p)
                }
                // Formula convention: first defined value initializes the recurrence.
                // This is distinct from the bundled TA-Lib EMA initialization.
                return exponential(x,alpha:alpha)
            }
            if ["HHV","LLV","HHVBARS","LLVBARS"].contains(fn) {
                let highest = fn == "HHV" || fn == "HHVBARS"
                let distance = fn == "HHVBARS" || fn == "LLVBARS"
                var queue: [Int] = [], head = 0, missing = 0
                return x.indices.map { i in
                    if x[i] == nil { missing += 1 }
                    if i >= p, x[i-p] == nil { missing -= 1 }
                    while head < queue.count, queue[head] <= i-p { head += 1 }
                    if let value = x[i] {
                        while queue.count > head {
                            guard let last = queue.last, let tail = x[last],
                                  highest ? tail <= value : tail >= value else { break }
                            queue.removeLast()
                        }
                        queue.append(i)
                    }
                    guard i >= p-1, missing == 0, head < queue.count else { return nil }
                    return distance ? Double(i-queue[head]) : x[queue[head]]
                }
            }
            // Rolling sum, count, weighted mean and variance in O(n).
            let booleanWindow = ["COUNT","EXIST","EVERY"].contains(fn)
            var sum = 0.0, squares = 0.0, weighted = 0.0, missing = 0
            return x.indices.map { i in
                let value = x[i].map { booleanWindow ? ($0 != 0 ? 1.0 : 0.0) : $0 }
                if i >= p {
                    weighted -= sum
                    if let old = x[i-p].map({ booleanWindow ? ($0 != 0 ? 1.0 : 0.0) : $0 }) {
                        sum -= old; squares -= old*old
                    } else { missing -= 1 }
                }
                if let value {
                    sum += value; squares += value*value
                    weighted += Double(min(i+1,p))*value
                } else { missing += 1 }
                guard i >= p-1, missing == 0 else { return nil }
                switch fn {
                case "MA": return finite(sum/Double(p))
                case "SUM", "COUNT": return finite(sum)
                case "EXIST": return sum > 0 ? 1 : 0
                case "EVERY": return sum == Double(p) ? 1 : 0
                case "WMA": return finite(weighted/(Double(p)*Double(p+1)/2))
                case "STD":
                    let mean = sum/Double(p)
                    return finite(sqrt(max(0,squares/Double(p)-mean*mean)))
                default: return nil
                }
            }
        }
    }
}

private struct FormulaParser {
    private let platform: FormulaPlatform
    private var tokens: [FormulaToken]
    private var index = 0
    private var token: FormulaToken { tokens[index] }

    init(_ source: String, platform: FormulaPlatform) throws {
        self.platform = platform
        guard source.utf8.count <= 32768 else { throw FormulaFailure("公式过长，上限32768字节") }
        let chars = Array(source)
        var result: [FormulaToken] = [], i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c == "/", i+1 < chars.count, chars[i+1] == "/" {
                i += 2; while i < chars.count, !chars[i].isNewline { i += 1 }; continue
            }
            if c == "{" {
                i += 1; while i < chars.count, chars[i] != "}" { i += 1 }
                guard i < chars.count else { throw FormulaFailure("注释未闭合") }; i += 1; continue
            }
            if c == "'" || c == "\"" {
                let quote = c
                i += 1
                let start = i
                while i < chars.count, chars[i] != quote {
                    guard !chars[i].isNewline else { throw FormulaFailure("文字不能跨行") }
                    i += 1
                }
                guard i < chars.count else { throw FormulaFailure("文字引号未闭合") }
                result.append(.text(String(chars[start..<i])))
                i += 1
            } else if FormulaIdentifier.isStart(c) {
                let start = i; i += 1
                while i < chars.count, FormulaIdentifier.isPart(chars[i]) { i += 1 }
                let word = String(chars[start..<i]).uppercased()
                result.append(word == "AND" || word == "OR" ? .symbol(word) : .name(word))
            } else if c.isASCII && (c.isNumber || c == ".") {
                let start = i; i += 1
                while i < chars.count, chars[i].isASCII && (chars[i].isNumber || chars[i] == ".") { i += 1 }
                guard let value = Double(String(chars[start..<i])), value.isFinite else {
                    throw FormulaFailure("无效数字")
                }
                result.append(.number(value))
            } else {
                let pair = i+1 < chars.count ? String(chars[i...i+1]) : ""
                if pair == "&&" || pair == "||" { result.append(.symbol(pair == "&&" ? "AND" : "OR")); i += 2
                } else if c == ":" {
                    var j = i+1; while j < chars.count, chars[j].isWhitespace { j += 1 }
                    if j < chars.count, chars[j] == "=" { result.append(.symbol(":=")); i = j+1 }
                    else { result.append(.symbol(":")); i += 1 }
                } else if [">=","<=","<>","!=","=="].contains(pair) {
                    result.append(.symbol(pair)); i += 2
                } else if "+-*/(),;:><=".contains(c) {
                    result.append(.symbol(String(c))); i += 1
                } else { throw FormulaFailure("不支持的字符：\(c)") }
            }
            guard result.count <= 4096 else { throw FormulaFailure("公式表达式过于复杂") }
        }
        tokens = result + [.end]
    }

    private mutating func take() -> FormulaToken {
        let t = token
        if t != .end { index += 1 }
        return t
    }
    private mutating func accept(_ s: String) -> Bool {
        guard token == .symbol(s) else { return false }
        index += 1; return true
    }
    private mutating func expect(_ s: String) throws {
        guard accept(s) else { throw FormulaFailure("缺少符号 \(s)，位置 \(index+1)") }
    }

    mutating func parse() throws -> [FormulaStatement] {
        var statements: [FormulaStatement] = []
        while token != .end {
            guard case .name(let name) = take() else { throw FormulaFailure("每条公式必须以变量名开头") }
            let drawingNames = ["STICKLINE","DRAWICON","DRAWTEXT","DRAWLINE"]
            let drawing = (drawingNames.contains(name) || (platform == .wenhua && name == "STICK")) && token == .symbol("(")
            var outputName = name
            var color: String?
            var visible: Bool
            let expr: FormulaExpr
            if drawing {
                // Rewind the function name so the ordinary expression parser
                // handles nested arguments, including quoted label text.
                index -= 1
                let call = try expression()
                guard case .call(let fn, var args) = call else { throw FormulaFailure("绘图函数必须独立成句") }
                if platform != .native && (fn == "DRAWICON" || fn == "DRAWLINE") {
                    throw FormulaFailure("当前平台尚未适配 " + fn)
                }
                if platform == .wenhua && (fn == "STICK" || fn == "STICKLINE") {
                    let colorIndex = fn == "STICK" ? 4 : 3
                    guard args.count == colorIndex + 2,
                          case .variable(let paint) = args[colorIndex],
                          let rgb = Self.platformColors[paint] else { throw FormulaFailure(fn + " 需要文华颜色常量和空心参数") }
                    color = rgb
                    args.remove(at:colorIndex)
                    if fn == "STICKLINE" { args.insert(.constant(10),at:3) }
                    else {
                        guard case .constant(let width) = args[3], (0...3).contains(width) else {
                            throw FormulaFailure("文华 STICK 支持宽度 0～3")
                        }
                        args[3] = .constant(width * (10.0/3))
                    }
                    if case .constant(let flag) = args[4] { args[4] = .constant(flag == 0 ? 0 : 1) }
                    expr = .call("STICKLINE",args)
                } else if platform == .tongdaxin && fn == "STICKLINE" {
                    guard args.count == 5, case .constant(let width) = args[3],
                          (0...4).contains(width) else { throw FormulaFailure("通达信 STICKLINE 支持固定宽度 0～4") }
                    args[3] = .constant(width * 2.5)
                    expr = .call(fn,args)
                } else { expr = call }
                visible = true
            } else {
                if accept(":") { visible = true }
                else if accept(":=") { visible = false }
                else if platform != .native {
                    index -= 1
                    outputName = "#\(statements.count + 1)"
                    visible = true
                } else { throw FormulaFailure("\(name) 后需要 : 或 :=") }
                expr = try expression()
            }
            var width = 1.5, histogram = false
            var fontSize: Double? = nil
            while accept(",") {
                guard case .name(let style) = take() else { throw FormulaFailure("绘图属性格式不正确") }
                let colors = ["COLORRED":"FF5B5B","COLORGREEN":"23C6C8","COLORBLUE":"4C8DFF",
                              "COLORYELLOW":"F5A623","COLORWHITE":"FFFFFF","COLORMAGENTA":"D77DFF",
                              "COLORCYAN":"23C6C8","COLORBLACK":"000000"]
                if let value = (platform == .native ? colors : Self.platformColors)[style] { color = value }
                else if style.hasPrefix("COLOR"), style.count == 11, UInt32(style.dropFirst(5),radix:16) != nil {
                    let hex = String(style.dropFirst(5))
                    color = platform == .tongdaxin ? String(hex.suffix(2)) + String(hex.dropFirst(2).prefix(2)) + String(hex.prefix(2)) : hex
                }
                else if style == "NODRAW" { visible = false }
                else if style.hasPrefix("FONTSIZE"), let size = Double(style.dropFirst(8)), (6...40).contains(size) { fontSize = size }
                else if style.hasPrefix("LINETHICK"), let value = Double(style.dropFirst(9)),
                        (1...5).contains(value) { width = value }
                else if style == "COLORSTICK" || style == "STICK" { histogram = true }
                else { throw FormulaFailure("暂不支持绘图属性：\(style)") }
            }
            if token != .end { try expect(";") }
            if drawing && histogram { throw FormulaFailure("绘图函数不能再加柱状图属性") }
            if platform != .native {
                if drawing && !visible { throw FormulaFailure("绘图调用不支持 NODRAW") }
                if fontSize != nil && name != "DRAWTEXT" { throw FormulaFailure("FONTSIZE 仅适用于文字") }
                if width != 1.5 && (drawing || histogram) { throw FormulaFailure("此绘图类型不支持 LINETHICK") }
                if !visible && histogram { throw FormulaFailure("柱状图需要用 : 定义输出") }
            }
            statements.append(.init(name:outputName,expr:expr,visible:visible,color:color,width:width,histogram:histogram,drawing:drawing,fontSize:fontSize))
            guard statements.count <= 96, statements.filter(\.visible).count <= 48 else {
                throw FormulaFailure("最多96条语句、48条绘图输出")
            }
        }
        guard statements.contains(where: \.visible) else { throw FormulaFailure("至少需要一条绘图输出") }
        return statements
    }

    private static let commonFunctions: Set<String> = [
        "MA","EMA","SMA","HHV","LLV","SUM","REF","COUNT","IF","CROSS","BARSLAST",
        "ABS","MAX","MIN","FILTER","NOT","EXIST","EVERY","VALUEWHEN","DRAWTEXT","STICKLINE"
    ]
    private static let platformFunctions: [FormulaPlatform:Set<String>] = [
        .tongdaxin:["WMA","DMA","EXPMA","STD","STDP","VAR","VARP","BARSLASTCOUNT","BARSSINCE",
                    "BARSCOUNT","HHVBARS","LLVBARS","IFN","IFF","BETWEEN","SQRT","POW","EXP",
                    "LN","LOG","SIGN","FLOOR","CEILING","INTPART","SIN","COS","TAN"],
        .wenhua:["EMA2","WMA","DMA","STD","STDP","VAR","VARP","BARSLASTCOUNT","BARSSINCE",
                 "IFELSE","CROSSUP","CROSSDOWN","BETWEEN","STICK","SQRT","POW","ABS"],
        .hexin:["CROSSUP","CROSSDOWN","SQRT","POW","RANGE"]
    ]

    private static let platformColors = ["COLORRED":"FF0000","COLORGREEN":"00FF00","COLORBLUE":"0000FF",
        "COLORYELLOW":"FFFF00","COLORWHITE":"FFFFFF","COLORMAGENTA":"FF00FF","COLORCYAN":"00FFFF","COLORBLACK":"000000"]

    private func precedence(_ op: String) -> Int {
        switch op {
        case "OR": return 1
        case "AND": return 2
        case ">", "<", ">=", "<=", "=", "==", "!=", "<>": return 3
        case "+","-": return 4
        case "*","/": return 5
        default: return 0
        }
    }
    private mutating func expression(_ minimum: Int = 1, depth: Int = 0) throws -> FormulaExpr {
        guard depth < 64 else { throw FormulaFailure("表达式嵌套过深") }
        var lhs = try atom(depth:depth+1)
        var chainLength = 0
        while case .symbol(let op) = token, precedence(op) >= minimum {
            chainLength += 1
            guard chainLength <= 96 || platform == .native else { throw FormulaFailure("单个表达式过长，请拆成中间变量") }
            _ = take()
            let rhs = try expression(precedence(op)+1,depth:depth+1)
            lhs = .binary(op,lhs,rhs)
        }
        return lhs
    }
    private mutating func atom(depth: Int) throws -> FormulaExpr {
        guard depth < 64 else { throw FormulaFailure("表达式嵌套过深") }
        if accept("-") { return .unary("-",try atom(depth:depth+1)) }
        if accept("+") { return try atom(depth:depth+1) }
        if accept("(") {
            let expr = try expression(depth:depth+1)
            try expect(")")
            return expr
        }
        switch take() {
        case .number(let value): return .constant(value)
        case .text(let value): return .text(value)
        case .name(let name):
            guard accept("(") else {
                if platform == .wenhua && ["ISUP","ISDOWN","ISEQUAL"].contains(name) {
                    let op = name == "ISUP" ? ">" : name == "ISDOWN" ? "<" : "="
                    return .binary(op,.variable("C"),.variable("O"))
                }
                return .variable(name)
            }
            var args: [FormulaExpr] = []
            if !accept(")") {
                repeat { args.append(try expression(depth:depth+1)) } while accept(",")
                try expect(")")
            }
            if platform != .native {
                guard Self.commonFunctions.contains(name) || Self.platformFunctions[platform]?.contains(name) == true else {
                    throw FormulaFailure(platform.title + " 暂不支持函数：" + name)
                }
                if platform == .wenhua {
                    if ["EMA","SMA","SUM","COUNT","HHV","LLV","MA","EVERY"].contains(name) {
                        return .call("#WH"+name,args)
                    }
                    if ["HHVBARS","LLVBARS"].contains(name) { throw FormulaFailure("文华极值位置的起算规则尚未适配：" + name) }
                }
                if platform == .tongdaxin && name == "SUM" { return .call("#TDXSUM",args) }
                if name == "STD" { return .call("#SAMPLESTD",args) }
                if name == "EXPMA" && platform == .tongdaxin { return .call("EMA",args) }
                if platform == .wenhua && name == "IFELSE" || platform == .tongdaxin && name == "IFF" {
                    return .call("IF",args)
                }
            }
            if platform == .tongdaxin && name == "IFN" && args.count == 3 {
                return .call("IF", [args[0], args[2], args[1]])
            }
            return .call(name,args)
        default: throw FormulaFailure("缺少有效表达式，位置 \(index+1)")
        }
    }
}
