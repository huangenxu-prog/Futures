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
        .init(id: "CZCE.SR", name: "白糖", exchange: "CZCE", lastPrice: 5892, change: -8, changePercent: -0.14),
        .init(id: "SHFE.cu", name: "沪铜", exchange: "SHFE", lastPrice: 78240, change: 530, changePercent: 0.68),
        .init(id: "SHFE.au", name: "沪金", exchange: "SHFE", lastPrice: 936.8, change: -4.2, changePercent: -0.45),
        .init(id: "INE.sc", name: "原油", exchange: "INE", lastPrice: 512.6, change: 8.4, changePercent: 1.67),
        .init(id: "CZCE.TA", name: "PTA", exchange: "CZCE", lastPrice: 4862, change: -36, changePercent: -0.73),
        .init(id: "CZCE.SA", name: "纯碱", exchange: "CZCE", lastPrice: 1428, change: 22, changePercent: 1.56),
        .init(id: "DCE.jm", name: "焦煤", exchange: "DCE", lastPrice: 1286.5, change: -18.5, changePercent: -1.42),
        .init(id: "DCE.c", name: "玉米", exchange: "DCE", lastPrice: 2288, change: 6, changePercent: 0.26),
        .init(id: "CZCE.RM", name: "菜粕", exchange: "CZCE", lastPrice: 2486, change: 31, changePercent: 1.26),
        .init(id: "DCE.y", name: "豆油", exchange: "DCE", lastPrice: 8124, change: -42, changePercent: -0.51),
        .init(id: "CZCE.CF", name: "棉花", exchange: "CZCE", lastPrice: 13860, change: 95, changePercent: 0.69)
    ]
}
