import SwiftUI

struct StrategyCenterView: View {
    let instruments: [FuturesInstrument]
    let favoriteIDs: [String]
    let mainCodes: [String:String]
    var body: some View {
        StrategyBacktestView(instruments: instruments, favoriteIDs: favoriteIDs,
                             mainCodes: mainCodes, formulas: ChartDisplaySettings.load().formulas)
    }
}
