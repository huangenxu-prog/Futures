import Foundation

struct FuturesInstrument: Identifiable, Hashable {
    let id: String
    let name: String
    let exchange: String
    let lastPrice: Double
    let change: Double
    let changePercent: Double

    var isRising: Bool { change >= 0 }

    static let samples: [FuturesInstrument] = [
        .init(id: "SHFE.rb", name: "螺纹钢", exchange: "SHFE", lastPrice: 3286, change: 18, changePercent: 0.55),
        .init(id: "DCE.m", name: "豆粕", exchange: "DCE", lastPrice: 2864, change: -21, changePercent: -0.73),
        .init(id: "CZCE.MA", name: "甲醇", exchange: "CZCE", lastPrice: 2418, change: 12, changePercent: 0.50),
        .init(id: "GFEX.lc", name: "碳酸锂", exchange: "GFEX", lastPrice: 91300, change: -1250, changePercent: -1.35),
        .init(id: "DCE.p", name: "棕榈油", exchange: "DCE", lastPrice: 8642, change: 66, changePercent: 0.77),
        .init(id: "CZCE.SR", name: "白糖", exchange: "CZCE", lastPrice: 5892, change: -8, changePercent: -0.14)
    ]
}
