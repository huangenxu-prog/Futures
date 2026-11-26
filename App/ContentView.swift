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
    @AppStorage("qihui.appearance.mode.v1") private var appearanceMode = AppAppearanceMode.dark.rawValue
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
            .preferredColorScheme((AppAppearanceMode(rawValue: appearanceMode) ?? .dark).colorScheme)
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
            // Keep the last display snapshot during inactive/background transitions.
            // Cancellation stops networking; it must not erase visible prices.
            guard scenePhase == .active else { return }
            // The persistent server-side feed sends its most recent quote
            // snapshot immediately on SSE connection. Do not delay that fast
            // path with a separate cold HTTP/TqSdk query first.
            var retryDelay = 10.0
            while !Task.isCancelled {
                do {
                    try await MarketDataService.streamQuotes { live in
                        guard !Task.isCancelled, scenePhase == .active else { return }
                        retryDelay = 10
                        applyContracts(live)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    // Older gateway/offline tunnel: preserve working 10s polling fallback.
                    guard !Task.isCancelled, scenePhase == .active else { return }
                    if let fallback = try? await MarketDataService.mainContracts(),
                       !Task.isCancelled, scenePhase == .active {
                        applyContracts(fallback)
                    }
                    do { try await Task.sleep(for: .seconds(retryDelay + Double.random(in: 0...0.5))) } catch { return }
                    retryDelay = min(30, retryDelay * 2)
                }
            }
        }
    }
    @MainActor
    private func applyContracts(_ incoming: [String: MarketDataService.MainContract]) {
        // Preserve valid display quotes across partial snapshots. A new main
        // contract is authoritative; timestamps only compare the same contract.
        let merged = contracts.merging(incoming) { old, new in
            guard old.code == new.code else { return new }
            if old.last != nil && new.last == nil { return old }
            if let oldTime = old.time, let newTime = new.time, newTime < oldTime { return old }
            if old.time != nil && new.time == nil { return old }
            return new
        }
        let oldIDs = contracts.mapValues { $0.code + "/" + $0.month }
        let newIDs = merged.mapValues { $0.code + "/" + $0.month }
        if oldIDs != newIDs {
            let identities = merged.mapValues(\.identity)
            if let data = try? JSONEncoder().encode(identities) {
                UserDefaults.standard.set(data, forKey: Self.identityKey)
            }
        }
        contracts = merged
        // Only actual received rows may drive live chart updates.
        let accepted = incoming.filter { merged[$0.key] == $0.value }
        NotificationCenter.default.post(name: .qihuiLiveQuotes, object: accepted)
    }

}

extension Notification.Name {
    static let qihuiDetailVisibility = Notification.Name("qihuiDetailVisibility")
    static let qihuiLiveQuotes = Notification.Name("qihuiLiveQuotes")
}

