import Foundation

struct FuturesInstrument: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let exchange: String
    static let catalog: [FuturesInstrument] = [
        .init(id: "SHFE.rb", name: "螺纹钢", exchange: "SHFE"),
        .init(id: "DCE.m", name: "豆粕", exchange: "DCE"),
        .init(id: "CZCE.MA", name: "甲醇", exchange: "CZCE"),
        .init(id: "GFEX.lc", name: "碳酸锂", exchange: "GFEX"),
        .init(id: "DCE.p", name: "棕榈油", exchange: "DCE"),
        .init(id: "CZCE.SR", name: "白糖", exchange: "CZCE"),
        .init(id: "SHFE.cu", name: "沪铜", exchange: "SHFE"),
        .init(id: "SHFE.au", name: "沪金", exchange: "SHFE"),
        .init(id: "INE.sc", name: "原油", exchange: "INE"),
        .init(id: "CZCE.TA", name: "PTA", exchange: "CZCE"),
        .init(id: "CZCE.SA", name: "纯碱", exchange: "CZCE"),
        .init(id: "DCE.jm", name: "焦煤", exchange: "DCE"),
        .init(id: "DCE.c", name: "玉米", exchange: "DCE"),
        .init(id: "CZCE.RM", name: "菜粕", exchange: "CZCE"),
        .init(id: "DCE.y", name: "豆油", exchange: "DCE"),
        .init(id: "CZCE.CF", name: "棉花", exchange: "CZCE")
    ]
}
