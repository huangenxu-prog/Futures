#if DEBUG
import SwiftUI

/// A three-row market with offline chart history for the simulator UI suite.
struct DetailPagerFixture: View {
    @StateObject private var favorites = Favorites()
    private static let catalog = FuturesInstrument.catalog.filter { ["DCE.m", "CZCE.SR", "SHFE.au"].contains($0.id) }
    private let quotes: [String: MarketDataService.MainContract]

    init() {
        let bars = (0..<240).map { i in
            let price = 3000 + Double(i % 37)
            return MarketBar(time: 1_735_700_400 + Int64(i * 900), open: price, high: price + 4,
                             low: price - 2, close: price + 2, preSettlement: nil, volume: Int64(100 + i))
        }
        quotes = Dictionary(uniqueKeysWithValues: Self.catalog.map { item in
            let code = item.id + "2701"
            MarketDataService.cache(bars, symbol: code, period: 900)
            return (item.id, MarketDataService.MainContract(code: code, month: "2701",
                last: 3000, settlement: 2990, bid: 2999, ask: 3001, volume: 100, interest: nil,
                previousInterest: nil, bidVolume: nil, askVolume: nil, time: nil))
        })
    }

    var body: some View {
        LightMarketView()
            .environment(\.futuresCatalog, Self.catalog)
            .environment(\.mainContracts, quotes)
            .environmentObject(favorites)
            .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("-test-light") ? .light : .dark)
    }
}
#endif
