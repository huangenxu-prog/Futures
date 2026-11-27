import Foundation

struct PineFormulaDefinition: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name = "TradingView 指标"
    var source = "//@version=6\nindicator(\"EMA\", overlay=true)\nplot(ta.ema(close,20), \"EMA\")"
    var overlay = true
    var enabled = false
}
