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
}
struct FormulaDefinition: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name = "自定义指标"
    var source = "EMA20:EMA(CLOSE,20),COLORBLUE;\nEMA50:EMA(CLOSE,50),COLORYELLOW;"
    var overlay = true
    var enabled = false
}

private enum FormulaToken: Equatable {
    case name(String), number(Double), symbol(String), end
}
private indirect enum FormulaExpr: Sendable {
    case constant(Double), variable(String), unary(String, FormulaExpr)
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
}

struct FormulaOutput: Sendable {
    let name: String
    let values: [Double?]
    let color: String?
    let width: Double
    let histogram: Bool
}

struct FormulaProgram: Sendable {
    private let statements: [FormulaStatement]

    init(_ source: String) throws {
        var parser = try FormulaParser(source)
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
        env["HL2"] = bars.map { ($0.high+$0.low)/2 }
        env["HLC3"] = bars.map { ($0.high+$0.low+$0.close)/3 }
        env["OHLC4"] = bars.map { ($0.open+$0.high+$0.low+$0.close)/4 }
        var results: [FormulaOutput] = []
        for statement in statements {
            guard env[statement.name] == nil else {
                throw FormulaFailure("变量重复定义：\(statement.name)")
            }
            let values = try Self.eval(statement.expr, env, n)
            env[statement.name] = values
            if statement.visible {
                results.append(FormulaOutput(name: statement.name, values: values,
                    color: statement.color, width: statement.width, histogram: statement.histogram))
            }
        }
        return results
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
            let fn = rawName == "EMA2" ? "WMA" : rawName
            let arity: [String:Int] = [
                "MA":2,"EMA":2,"SMA":3,"WMA":2,"HMA":2,"DEMA":2,"TEMA":2,"DMA":2,"WILDER":2,
                "HHV":2,"LLV":2,"SUM":2,"STD":2,
                "REF":2,"COUNT":2,"IF":3,"CROSS":2,"BARSLAST":1,"ABS":1,"MAX":2,"MIN":2
            ]
            guard let expected = arity[fn] else { throw FormulaFailure("暂不支持函数：\(fn)") }
            guard args.count == expected else { throw FormulaFailure("\(fn) 需要 \(expected) 个参数") }
            let x = try eval(args[0],env,n)
            if fn == "ABS" { return x.map { $0.map(abs) } }
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
            let p = try period(args[1],zero: fn == "REF")
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
            if fn == "REF" {
                return x.indices.map { i in i >= p ? x[i-p] : nil }
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
            if fn == "HHV" || fn == "LLV" {
                var queue: [Int] = [], head = 0, missing = 0
                return x.indices.map { i in
                    if x[i] == nil { missing += 1 }
                    if i >= p, x[i-p] == nil { missing -= 1 }
                    while head < queue.count, queue[head] <= i-p { head += 1 }
                    if let value = x[i] {
                        while queue.count > head {
                            guard let last = queue.last, let tail = x[last],
                                  fn == "HHV" ? tail <= value : tail >= value else { break }
                            queue.removeLast()
                        }
                        queue.append(i)
                    }
                    guard i >= p-1, missing == 0, head < queue.count else { return nil }
                    return x[queue[head]]
                }
            }
            // Rolling sum, count, weighted mean and variance in O(n).
            var sum = 0.0, squares = 0.0, weighted = 0.0, missing = 0
            return x.indices.map { i in
                let value = x[i].map { fn == "COUNT" ? ($0 != 0 ? 1.0 : 0.0) : $0 }
                if i >= p {
                    weighted -= sum
                    if let old = x[i-p].map({ fn == "COUNT" ? ($0 != 0 ? 1.0 : 0.0) : $0 }) {
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
    private var tokens: [FormulaToken]
    private var index = 0
    private var token: FormulaToken { tokens[index] }

    init(_ source: String) throws {
        guard source.utf8.count <= 8192 else { throw FormulaFailure("公式过长，上限8192字节") }
        let chars = Array(source.uppercased())
        var result: [FormulaToken] = [], i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c.isASCII && (c.isLetter || c == "_") {
                let start = i; i += 1
                while i < chars.count, chars[i].isASCII &&
                    (chars[i].isLetter || chars[i].isNumber || chars[i] == "_") { i += 1 }
                let word = String(chars[start..<i])
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
                if [":=",">=","<=","<>","!=","=="].contains(pair) {
                    result.append(.symbol(pair)); i += 2
                } else if "+-*/(),;:><=".contains(c) {
                    result.append(.symbol(String(c))); i += 1
                } else { throw FormulaFailure("不支持的字符：\(c)") }
            }
            guard result.count <= 512 else { throw FormulaFailure("公式表达式过于复杂") }
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
            let visible: Bool
            if accept(":") { visible = true }
            else if accept(":=") { visible = false }
            else { throw FormulaFailure("\(name) 后需要 : 或 :=") }
            let expr = try expression()
            var color: String?, width = 1.5, histogram = false
            while accept(",") {
                guard visible, case .name(let style) = take() else { throw FormulaFailure("绘图属性格式不正确") }
                let colors = ["COLORRED":"FF5B5B","COLORGREEN":"23C6C8","COLORBLUE":"4C8DFF",
                              "COLORYELLOW":"F5A623","COLORWHITE":"FFFFFF","COLORMAGENTA":"D77DFF",
                              "COLORCYAN":"23C6C8","COLORBLACK":"000000"]
                if let value = colors[style] { color = value }
                else if style.hasPrefix("LINETHICK"), let value = Double(style.dropFirst(9)),
                        (1...5).contains(value) { width = value }
                else if style == "COLORSTICK" || style == "STICK" { histogram = true }
                else { throw FormulaFailure("暂不支持绘图属性：\(style)") }
            }
            if token != .end { try expect(";") }
            statements.append(.init(name:name,expr:expr,visible:visible,color:color,width:width,histogram:histogram))
            guard statements.count <= 24, statements.filter(\.visible).count <= 8 else {
                throw FormulaFailure("最多24条语句、8条绘图输出")
            }
        }
        guard statements.contains(where: \.visible) else { throw FormulaFailure("至少需要一条使用冒号输出的公式") }
        return statements
    }

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
        while case .symbol(let op) = token, precedence(op) >= minimum {
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
        case .name(let name):
            guard accept("(") else { return .variable(name) }
            var args: [FormulaExpr] = []
            if !accept(")") {
                repeat { args.append(try expression(depth:depth+1)) } while accept(",")
                try expect(")")
            }
            return .call(name,args)
        default: throw FormulaFailure("缺少有效表达式，位置 \(index+1)")
        }
    }
}
