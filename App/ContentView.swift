import SwiftUI

private struct MainContractsKey: EnvironmentKey {
    static let defaultValue: [String: MarketDataService.MainContract] = [:]
}

private struct FuturesCatalogKey: EnvironmentKey {
    static let defaultValue: [FuturesInstrument] = FuturesInstrument.catalog
}

extension EnvironmentValues {
    var futuresCatalog: [FuturesInstrument] {
        get { self[FuturesCatalogKey.self] }
        set { self[FuturesCatalogKey.self] = newValue }
    }
}

extension EnvironmentValues {
    var mainContracts: [String: MarketDataService.MainContract] {
        get { self[MainContractsKey.self] }
        set { self[MainContractsKey.self] = newValue }
    }
}

struct ContentView: View {
    @StateObject private var favorites = Favorites()
    @Environment(\.scenePhase) private var scenePhase
    @State private var contracts = savedIdentities()
    @State private var catalog = savedCatalog()
    private static let catalogKey = "qihui.futures.catalog.cache.v1"

    private static func savedCatalog() -> [FuturesInstrument] {
        guard let data = UserDefaults.standard.data(forKey: catalogKey),
              let items = try? JSONDecoder().decode([FuturesInstrument].self, from: data),
              !items.isEmpty else { return FuturesInstrument.catalog }
        return items
    }

    private static let identityKey = "main-contract-identities"

    private static func savedIdentities() -> [String: MarketDataService.MainContract] {
        guard let data = UserDefaults.standard.data(forKey: identityKey) else { return [:] }
        return (try? JSONDecoder().decode([String: MarketDataService.MainContract].self, from: data)) ?? [:]
    }
    var body: some View {
        // Read-only professional market terminal. No account or order screens.
        LightMarketView()
            .preferredColorScheme(.light)
            .environment(\.mainContracts, contracts)
            .environment(\.futuresCatalog, catalog)
            .environmentObject(favorites)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            if let loaded = try? await MarketDataService.catalogProducts() {
                catalog = loaded
                if let data = try? JSONEncoder().encode(loaded) {
                    UserDefaults.standard.set(data, forKey: Self.catalogKey)
                }
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else {
                contracts = contracts.mapValues(\.identity)
                return
            }
            // Fetch one snapshot immediately, then receive individual market
            // updates as soon as TqSdk pushes them to the gateway.
            while !Task.isCancelled {
                do {
                    let initial = try await MarketDataService.mainContracts()
                    try Task.checkCancellation()
                    applyContracts(initial)
                    try await MarketDataService.streamQuotes { live in
                        applyContracts(live)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    // Older gateway/offline tunnel: preserve working 10s polling fallback.
                    if let fallback = try? await MarketDataService.mainContracts() {
                        applyContracts(fallback)
                    } else {
                        contracts = contracts.mapValues(\.identity)
                    }
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                }
            }
        }
    }
    @MainActor
    private func applyContracts(_ incoming: [String: MarketDataService.MainContract]) {
        let oldIDs = contracts.mapValues { $0.code + "/" + $0.month }
        let newIDs = incoming.mapValues { $0.code + "/" + $0.month }
        if oldIDs != newIDs {
            let identities = incoming.mapValues(\.identity)
            if let data = try? JSONEncoder().encode(identities) {
                UserDefaults.standard.set(data, forKey: Self.identityKey)
            }
        }
        contracts = incoming
    }

}

extension Notification.Name {
    static let qihuiDetailVisibility = Notification.Name("qihuiDetailVisibility")
}

