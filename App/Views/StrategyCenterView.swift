import SwiftUI

struct StrategyCenterView: View {
    @Environment(\.qihuiInPageStack) private var inPageStack
    let instruments: [FuturesInstrument]
    let favoriteIDs: [String]
    let mainCodes: [String:String]
    var body: some View {
        StrategyBacktestView(instruments: instruments, favoriteIDs: favoriteIDs,
                             mainCodes: mainCodes, formulas: ChartDisplaySettings.load().formulas)
            .environment(\.qihuiInPageStack,inPageStack)
    }
}
