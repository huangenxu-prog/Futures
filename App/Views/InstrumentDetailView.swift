import SwiftUI
import UIKit
import Combine

struct InstrumentDetailView: View {
    let instrument: FuturesInstrument
    let selectedContract: MarketDataService.ContractQuote?
    private let pages: [FuturesInstrument]
    @State private var period = "15分"
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mainContracts) private var contracts
    @Environment(\.futuresCatalog) private var catalog
    @Environment(\.scenePhase) private var phase
    @EnvironmentObject private var favorites: Favorites

    init(instrument: FuturesInstrument, selectedContract: MarketDataService.ContractQuote? = nil, sequence: [FuturesInstrument] = []) {
        self.instrument = instrument
        self.selectedContract = selectedContract
        var seen = Set<String>()
        let unique = sequence.filter { seen.insert($0.id).inserted }
        pages = seen.contains(instrument.id) ? unique : [instrument]
    }

    var body: some View {
        DetailPager(pages: pages, initial: instrument, period: period) { item, active, turnPage in
            AnyView(InstrumentDetailPage(instrument: item,
                selectedContract: item.id == instrument.id ? selectedContract : nil,
                period: $period, isActive: active, turnPage: turnPage, goBack: { dismiss() })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("detail.page." + item.id)
                .environment(\.mainContracts, contracts)
                .environment(\.futuresCatalog, catalog)
                .environment(\.scenePhase, phase)
                .environmentObject(favorites))
        }
        .id(instrument.id)
        .background(MarketPalette.surface.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { NotificationCenter.default.post(name: .qihuiDetailVisibility, object: true) }
        .onDisappear { NotificationCenter.default.post(name: .qihuiDetailVisibility, object: false) }
    }
}

private struct DetailPager: UIViewControllerRepresentable {
    let pages: [FuturesInstrument]
    let initial: FuturesInstrument
    // Invalidate hosted roots when the shared selection changes.
    let period: String
    let content: (FuturesInstrument, Bool, @escaping (Int) -> Void) -> AnyView

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .vertical)
        pager.view.clipsToBounds = true
        pager.view.accessibilityIdentifier = "detail.viewport"
        for scroll in pager.view.subviews.compactMap({ $0 as? UIScrollView }) {
            scroll.contentInsetAdjustmentBehavior = .never
            scroll.panGestureRecognizer.maximumNumberOfTouches = 1
            scroll.isDirectionalLockEnabled = true
            scroll.alwaysBounceVertical = pages.count > 1
        }
        let coordinator = context.coordinator
        coordinator.pager = pager
        pager.dataSource = pages.count > 1 ? coordinator : nil
        pager.delegate = coordinator
        pager.setViewControllers([coordinator.host(for: initial)], direction: .forward, animated: false)
        coordinator.keepNeighbors()
        return pager
    }

    func updateUIViewController(_ pager: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        context.coordinator.refresh()
    }

    @MainActor final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: DetailPager
        weak var pager: UIPageViewController?
        private var transitioning = false
        var activeID: String
        private var hosts: [String: UIHostingController<AnyView>] = [:]

        init(_ parent: DetailPager) {
            self.parent = parent
            activeID = parent.initial.id
        }

        func host(for item: FuturesInstrument) -> UIHostingController<AnyView> {
            if let existing = hosts[item.id] { return existing }
            let host = UIHostingController(rootView: root(for: item))
            host.safeAreaRegions = []
            host.view.backgroundColor = .clear
            host.view.accessibilityElementsHidden = item.id != activeID
            hosts[item.id] = host
            return host
        }

        private func root(for item: FuturesInstrument) -> AnyView {
            parent.content(item, item.id == activeID) { [weak self] offset in
                self?.turnPage(from: item.id, offset: offset)
            }
        }

        // The chart can own a vertical pan when its UIKit ancestor does not yet
        // advertise a scrollable extent. Use the chart's existing direction callback.
        private func turnPage(from id: String, offset: Int) {
            guard !transitioning, id == activeID, let pager, let visible = pager.viewControllers?.first,
                  let next = neighbor(of: visible, offset: offset) else { return }
            transitioning = true
            pager.setViewControllers([next], direction: offset > 0 ? .forward : .reverse, animated: true) { [weak self] _ in
                self?.finishTransition()
            }
        }

        private func finishTransition() {
            transitioning = false
            guard let visible = pager?.viewControllers?.first,
                  let id = hosts.first(where: { $0.value === visible })?.key else { return }
            activeID = id
            refresh()
            keepNeighbors()
        }

        func keepNeighbors() {
            guard let center = parent.pages.firstIndex(where: { $0.id == activeID }) else { return }
            let neighbors = parent.pages[max(0, center - 1)...min(parent.pages.count - 1, center + 1)]
            let ids = Set(neighbors.map(\.id))
            hosts = hosts.filter { ids.contains($0.key) }
            for item in neighbors { _ = host(for: item) }
        }

        func refresh() {
            for (id, host) in hosts {
                guard let item = parent.pages.first(where: { $0.id == id }) else { continue }
                host.rootView = root(for: item)
                host.view.accessibilityElementsHidden = id != activeID
            }
        }

        private func neighbor(of controller: UIViewController, offset: Int) -> UIViewController? {
            guard let id = hosts.first(where: { $0.value === controller })?.key,
                  let index = parent.pages.firstIndex(where: { $0.id == id }),
                  parent.pages.indices.contains(index + offset) else { return nil }
            return host(for: parent.pages[index + offset])
        }

        func pageViewController(_ pager: UIPageViewController, viewControllerBefore controller: UIViewController) -> UIViewController? {
            neighbor(of: controller, offset: -1)
        }

        func pageViewController(_ pager: UIPageViewController, viewControllerAfter controller: UIViewController) -> UIViewController? {
            neighbor(of: controller, offset: 1)
        }

        func pageViewController(_ pager: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
            transitioning = true
        }

        func pageViewController(_ pager: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            finishTransition()
        }
    }
}

private struct InstrumentDetailPage: View {
    @Environment(\.mainContracts) private var contracts
    @EnvironmentObject private var favorites: Favorites
    @State private var showOptions = false
    @State private var tradeContract: PaperContract?
    @State private var showContracts = false
    @State private var showChartIndicatorSettings = false
    private let instrument: FuturesInstrument
    private let isActive: Bool
    let turnPage: (Int) -> Void
    let goBack: () -> Void
    @Binding private var period: String
    @State private var selectedContract: MarketDataService.ContractQuote?

    init(instrument: FuturesInstrument, selectedContract: MarketDataService.ContractQuote?, period: Binding<String>, isActive: Bool, turnPage: @escaping (Int) -> Void, goBack: @escaping () -> Void) {
        self.instrument = instrument
        self.turnPage = turnPage
        self.goBack = goBack
        self.isActive = isActive
        _period = period
        _selectedContract = State(initialValue: selectedContract)
    }

    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("qihui.chart.period-order.v1") private var storedPeriodOrder = ""
    @State private var showPeriodOrder = false
    @State private var rawBars: [MarketBar] = []
    @State private var chartFeed = DirectChartFeed<[MarketBar]>()
    @State private var liveQuote: MarketDataService.MainContract?
    @State private var selectedCandleTime: Int64? = nil
    @State private var loadError: String? = nil
    @State private var loading = false
    @State private var currentPriceTick: Double?
    @State private var currentVolumeMultiple: Double?
    @AppStorage("qihui.chart.period-hidden.v1") private var hiddenPeriods = "3分,10分,120分"
    private var periods: [String] { QihuiPeriods.visible(storedPeriodOrder, hidden: hiddenPeriods) }
    private func periodLabel(_ item: String) -> String { QihuiPeriods.labels[item] ?? item }
    private var quote: MarketDataService.MainContract? { liveQuote ?? contracts[instrument.id] }
    private var chartSymbol: String { selectedContract?.code ?? quote?.code ?? instrument.id }
    private var chartKey: String { chartSymbol + "/" + period }
    @State private var displayedKey = ""
    @State private var lastStreamCandleKey: String?
    @State private var mostRecentStreamBar: MarketBar?
    @State private var lastCachedCandleAt: Date?

    @AppStorage("qihui.change.basis.v1") private var changeBasis = "settlement"
    private var displayedChange: Double? { selectedContract == nil ? quote?.change(basis: changeBasis) : selectedContract?.change(basis: changeBasis) }
    private var changeColor: Color { MarketPalette.movement(displayedChange) }
    private var changeText: String { (selectedContract == nil ? quote?.changePercent(basis: changeBasis) : selectedContract?.changePercent(basis: changeBasis)) ?? "--" }
    private var currentLast: Double? {
        (displayedKey == chartKey ? rawBars.last?.close : nil) ?? (selectedContract == nil ? quote?.last : selectedContract?.last)
    }
    private var periodSeconds: Int { QihuiPeriods.seconds[period] ?? 900 }
    var body: some View {
        VStack(spacing: 3) {
                topBar
                priceSummary
                marketStatistics
                periodRow
                if let timestamp = selectedCandleTime,
                   let candle = rawBars.first(where: { $0.time == timestamp }) {
                    selectedCandleInfo(candle)
                        .padding(.horizontal, 8)
                        .frame(height: 15)
                }
                if loading && rawBars.isEmpty {
                    Spacer()
                    ProgressView("正在获取行情")
                    Spacer()
                } else if let loadError, rawBars.isEmpty {
                    Spacer()
                    Text(loadError).font(.caption).foregroundStyle(.orange)
                    Spacer()
                } else if !rawBars.isEmpty && displayedKey == chartKey {
                    ProfessionalChartHost(
                        symbol: chartSymbol, period: periodSeconds, bars: rawBars,
                        feed: chartFeed, feedKey: chartKey,
                        priceTick: selectedContract?.priceTick ?? currentPriceTick,
                        contractMultiplier: selectedContract?.volumeMultiple ?? currentVolumeMultiple,
                        previousSettlement: selectedContract == nil ? quote?.settlement : selectedContract?.settlement,
                        showingIndicatorSettings: $showChartIndicatorSettings,
                        selectedCandleTime: $selectedCandleTime,
                        onVerticalSwipe: turnPage, isInteractive: isActive
                    )
                    .id(chartKey)
                    .frame(maxHeight: .infinity)
                } else {
                    Spacer()
                }
        }
        .padding(.horizontal, 3)
        .background(MarketPalette.surface)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: chartSymbol + (isActive ? "/active" : "/preview")) {
            guard isActive else { return }
            // Contract metadata, not displayed price magnitude, determines
            // precision. The main-contract snapshot does not include priceTick,
            // so request it from the existing listed-contract endpoint.
            let symbol = chartSymbol
            currentPriceTick = selectedContract?.priceTick
            currentVolumeMultiple = selectedContract?.volumeMultiple
            if (currentPriceTick ?? 0) <= 0 || (currentVolumeMultiple ?? 0) <= 0 {
                if let listed = try? await MarketDataService.listedContracts(for: instrument.id) {
                    guard !Task.isCancelled, chartSymbol == symbol else { return }
                    if let contract = listed.first(where: { $0.code == symbol }) {
                        if let tick = contract.priceTick,tick > 0 { currentPriceTick = tick }
                        if let multiple = contract.volumeMultiple,multiple > 0 { currentVolumeMultiple = multiple }
                    }
                }
            }
        }
        .task(id: chartKey + (scenePhase == .active ? "/foreground" : "/paused") + (isActive ? "/live" : "/preview")) {
            guard scenePhase == .active else { return }
            let symbol = chartSymbol
            let seconds = periodSeconds
            let key = chartKey
            if displayedKey != key {
                let cached = await Task.detached(priority: .utility) {
                    MarketDataService.cached(symbol: symbol, period: seconds)
                }.value
                guard !Task.isCancelled, chartKey == key else { return }
                prepareCachedCandles(symbol: symbol, period: seconds, prepared: cached ?? [])
            }
            if !isActive {
                // Adjacent pages own their own rendered chart, but no live stream.
                // Their single HTTP history request is cancelled on activation.
                if rawBars.isEmpty, let fetched = try? await MarketDataService.fetch(symbol: symbol, period: seconds, count: KlineStartupMerge.initialCount, mergeCached: false),
                   !Task.isCancelled, chartKey == key, !fetched.isEmpty {
                    rawBars = fetched
                    chartFeed.publish(key: key, snapshot: fetched)
                    MarketDataService.cache(fetched, symbol: symbol, period: seconds)
                    loading = false
                }
                return
            }
            // The SSE handshake already contains an authoritative history page.
            // Only hydrate by HTTP if it is incomplete or the stream fails.
            // Never put that request in the live update's critical path.
            var hydration: Task<Void, Never>?
            defer { hydration?.cancel() }
            var retryDelay = 1.0
            while !Task.isCancelled {
                do {
                    try await MarketDataService.streamCandles(symbol: symbol, period: seconds) { event in
                        guard !Task.isCancelled, chartSymbol == symbol, periodSeconds == seconds else { return }
                        retryDelay = 1
                        applyLiveCandle(event)
                        if event.bars != nil, rawBars.count < KlineStartupMerge.initialCount,
                           hydration == nil {
                            hydration = Task { @MainActor in await loadCandles(reset: false) }
                        }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    if hydration == nil, rawBars.count < KlineStartupMerge.initialCount {
                        hydration = Task { @MainActor in await loadCandles(reset: false) }
                    }
                    do { try await Task.sleep(for: .seconds(retryDelay + Double.random(in: 0...0.5))) } catch { return }
                    retryDelay = min(30, retryDelay * 2)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .qihuiLiveQuotes)) { notification in
            guard scenePhase == .active,
                  let updates = notification.object as? [String: MarketDataService.MainContract],
                  let incoming = updates[instrument.id], incoming != liveQuote else { return }
            // A navigation destination may have captured an older environment
            // dictionary. Consume the actual shared live feed directly.
            liveQuote = incoming
        }
        .sheet(item: $tradeContract) { contract in
            QuickTradeSheet(contract: contract)
                .presentationDetents([.height(350), .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showOptions) {
            OptionChainView(code: chartSymbol, underlyingLast: currentLast,underlyingName:instrument.name)
        }
        .sheet(isPresented: $showContracts) {
            ContractListView(instrument: instrument, currentCode: chartSymbol) { contract in
                if contract.code != chartSymbol {
                    selectedContract = contract
                    currentPriceTick = contract.priceTick
                    currentVolumeMultiple = contract.volumeMultiple
                    prepareCachedCandles(symbol: contract.code, period: periodSeconds)
                }
                showContracts = false
            }
        }
        .sheet(isPresented: $showPeriodOrder) {
            PeriodOrderView(order: periods, label: periodLabel) { updated in
                storedPeriodOrder = updated.joined(separator: ",")
                hiddenPeriods = QihuiPeriods.all.filter { !updated.contains($0) }.joined(separator: ",")
                if !updated.contains(period) { period = updated.first ?? "15分" }
            }
        }
        .onChange(of: isActive) { _, active in
            if !active { selectedCandleTime = nil }
        }
    }
    @MainActor
    private func prepareCachedCandles(symbol: String, period: Int, prepared: [MarketBar]? = nil) {
        displayedKey = chartKey
        lastStreamCandleKey = nil
        mostRecentStreamBar = nil
        lastCachedCandleAt = nil
        rawBars = prepared ?? MarketDataService.cached(symbol: symbol, period: period) ?? []
        chartFeed.publish(key: chartKey, snapshot: rawBars)
        selectedCandleTime = nil
        loadError = nil
        loading = rawBars.isEmpty
    }

    @MainActor private func loadCandles(reset: Bool) async {
        let requestedPeriod = periodSeconds
        let symbol = chartSymbol
        if reset { prepareCachedCandles(symbol: symbol, period: requestedPeriod) }
        let requestedKey = chartKey
        loadError = nil
        loading = rawBars.isEmpty
        defer { if !Task.isCancelled { loading = false } }
        do {
            let bars = try await MarketDataService.fetch(symbol: symbol, period: requestedPeriod, count: KlineStartupMerge.initialCount, mergeCached: false)
            try Task.checkCancellation()
            guard symbol == chartSymbol, requestedPeriod == periodSeconds,
                  displayedKey == requestedKey else { return }
            // SSE may have delivered newer ticks while HTTP was in flight.
            // History wins over an older phone cache, but a newer live bar
            // must not be rolled back by the later HTTP completion.
            let hasLive = lastStreamCandleKey == requestedKey
            let merged = KlineStartupMerge.combine(
                server: hasLive ? rawBars : bars,
                existing: hasLive ? bars : rawBars,
                live: hasLive ? mostRecentStreamBar : nil,
                timestamp: { $0.time })
            guard !merged.isEmpty else { return }
            if rawBars != merged { rawBars = merged }
            chartFeed.publish(key: requestedKey, snapshot: rawBars)
            MarketDataService.cache(merged, symbol: symbol, period: requestedPeriod)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            if rawBars.isEmpty {
                loadError = error.localizedDescription
            }
        }
    }
    @MainActor
    private func applyLiveCandle(_ event: MarketDataService.CandlePush) {
        guard event.symbol == chartSymbol, displayedKey == chartKey else { return }
        let applyStarted = ProcessInfo.processInfo.systemUptime
        let updated: [MarketBar]
        var tailOnly = false
        if let full = event.bars, !full.isEmpty {
            // The new gateway sends only two live bars at startup. Merge
            // by exchange K-line time so a short frame cannot replace the
            // phone's existing MA120 history with just two candles.
            var byTime: [Int64: MarketBar] = [:]
            for bar in rawBars { byTime[bar.time] = bar }
            for bar in full { byTime[bar.time] = bar }
            updated = Array(byTime.values.sorted { $0.time < $1.time }.suffix(500))
        } else if let bar = event.bar, let last = rawBars.last {
            var next = rawBars
            if bar.time == last.time {
                next[next.count - 1] = bar
                tailOnly = true
            } else if bar.time > last.time {
                next.append(bar)
                if next.count > 500 { next.removeFirst(next.count - 500) }
                tailOnly = true
            } else if let index = next.lastIndex(where: { $0.time == bar.time }) {
                next[index] = bar
            } else {
                return
            }
            updated = next
        } else {
            return
        }

        if rawBars != updated { rawBars = updated }
        KlineDiagnostics.record(event, period: periodSeconds, newest: updated.last, started: applyStarted)
        // The original TradingChart incremental API consumes each genuine
        // tail update immediately. Only snapshots/history use reconciliation.
        chartFeed.publish(key: chartKey, snapshot: updated, tailOnly: tailOnly)
        lastStreamCandleKey = chartKey
        // Retain the freshest authoritative bar while the parallel history
        // request is pending; never let a late HTTP result roll it back.
        if let newest = event.bar ?? event.bars?.max(by: { $0.time < $1.time }),
           mostRecentStreamBar == nil || newest.time >= mostRecentStreamBar!.time {
            mostRecentStreamBar = newest
        }
        // Save the first authoritative live frame and occasionally refresh it.
        // Throttling prevents thousands of writes per trading session.
        let now = Date()
        if lastCachedCandleAt == nil ||
           now.timeIntervalSince(lastCachedCandleAt!) >= 30 {
            MarketDataService.cache(updated, symbol: chartSymbol, period: periodSeconds)
            lastCachedCandleAt = now
        }
        loadError = nil
        loading = false
    }

    private var topBar: some View {
        HStack(spacing: 6) {
            Button { goBack() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 28, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("detail.back")
            Button { showContracts = true } label: {
                HStack(spacing: 6) {
                    Text(instrument.name + (selectedContract?.month ?? quote?.month ?? ""))
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                        .layoutPriority(1)
                    Text(selectedContract?.code ?? quote?.code ?? (instrument.id + " 主连"))
                        .font(.system(size: 11))
                        .foregroundStyle(MarketPalette.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(minHeight: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("切换合约月份")
            .accessibilityIdentifier("detail.contract." + instrument.id)
            Spacer(minLength: 2)
            headerAction("期权") { showOptions = true }
            headerAction("下单") { openTrade() }
            Button { favorites.toggle(instrument.id) } label: {
                Image(systemName: favorites.ids.contains(instrument.id) ? "star.fill" : "star")
                    .font(.system(size: 12))
                    .foregroundStyle(favorites.ids.contains(instrument.id) ? MarketPalette.accent : MarketPalette.muted)
                    .frame(width: 23, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(favorites.ids.contains(instrument.id) ? "移出自选" : "加入自选")
        }
        .foregroundStyle(MarketPalette.ink)
        .padding(.horizontal, 7)
        .frame(height: 34)
    }

    private func headerAction(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(MarketPalette.ink)
                .fixedSize()
                .frame(minWidth: 44, minHeight: 25)
                .overlay {
                    Capsule().strokeBorder(MarketPalette.muted.opacity(0.65), lineWidth: 1)
                }
                .frame(minHeight: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(selectedContract == nil && quote == nil)
    }

    private var priceSummary: some View {
        HStack(alignment: .center, spacing: 7) {
            Text(currentLast?.formatted() ?? "--")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .foregroundStyle(changeColor)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .layoutPriority(1)
            VStack(alignment: .leading, spacing: 3) {
                Text(changeText)
                Text(displayedChange.map { ($0 > 0 ? "+" : "") + $0.formatted() } ?? "--")
            }
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(changeColor)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            Spacer(minLength: 4)
            VStack(spacing: 4) {
                bookQuote("卖1", price: contractQuote(quote?.ask, selectedContract?.ask),
                          quantity: selectedContract == nil ? quote?.askVolume : selectedContract?.askVolume)
                bookQuote("买1", price: contractQuote(quote?.bid, selectedContract?.bid),
                          quantity: selectedContract == nil ? quote?.bidVolume : selectedContract?.bidVolume)
            }
            .frame(width: 132)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 45)
    }

    private var marketStatistics: some View {
        HStack(spacing: 4) {
            smallQuote("成交", CompactMarketQuantity.format(selectedContract == nil ? quote?.volume : selectedContract?.volume), MarketPalette.ink)
            Spacer(minLength: 3)
            smallQuote("持仓", CompactMarketQuantity.format(selectedContract == nil ? quote?.interest : selectedContract?.interest), MarketPalette.ink)
            Spacer(minLength: 3)
            smallQuote("增仓", selectedContract == nil ? (quote?.interestChange?.formatted() ?? "--") : "--", MarketPalette.ink)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
    }

    private var periodRow: some View {
        HStack(spacing: 3) {
            ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
            ForEach(periods, id: \.self) { item in
                Button { period = item } label: {
                    Text(periodLabel(item))
                        .font(.system(size: 13, weight: period == item ? .semibold : .medium))
                        .foregroundStyle(period == item ? Color.white : MarketPalette.muted)
                        .frame(minWidth: 44)
                        .frame(height: 29)
                        .background(period == item ? MarketPalette.accent : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(period == item ? .isSelected : [])
            }
            }
            }
            if isActive {
                CandleCountdownView(barStart: displayedKey == chartKey ? rawBars.last?.time : nil,
                                    period: periodSeconds, running: scenePhase == .active)
            }
            actions
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .overlay(alignment: .top) { quoteSeparator }
        .overlay(alignment: .bottom) { quoteSeparator }
    }

    private func timeLabel(_ timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = (period == "日线" || period == "周线") ? "MM/dd" : "MM/dd HH:mm"
        return formatter.string(from: date)
    }
    private func selectedCandleInfo(_ candle: MarketBar) -> some View {
        HStack(spacing: 5) {
            Text(timeLabel(candle.time)).foregroundStyle(MarketPalette.muted)
            Text("开" + candle.open.formatted())
            Text("高" + candle.high.formatted())
            Text("低" + candle.low.formatted())
            Text("收" + candle.close.formatted())
        }
        .font(.system(size: 10, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(MarketPalette.ink.opacity(0.88))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openTrade() {
        let snapshot = selectedContract == nil ? quote : nil
        let chartLast = displayedKey == chartKey ? rawBars.last?.close : nil
        tradeContract = PaperContract(
            symbol:chartSymbol,name:instrument.name,
            tick:selectedContract?.priceTick ?? currentPriceTick,
            multiplier:selectedContract?.volumeMultiple ?? currentVolumeMultiple,
            last:selectedContract?.last ?? snapshot?.last ?? chartLast,
            bid:selectedContract?.bid ?? snapshot?.bid,
            ask:selectedContract?.ask ?? snapshot?.ask)
    }

    private var actions: some View {
        Menu {
            Button("周期排序") { showPeriodOrder = true }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(MarketPalette.ink)
                .frame(width: 32, height: 29)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("合约菜单")
    }

    private func contractQuote(_ mainValue: Double?, _ otherValue: Double?) -> String {
        (selectedContract == nil ? mainValue : otherValue)?.formatted() ?? "--"
    }

    private var quoteSeparator: some View {
        Rectangle().fill(MarketPalette.divider).frame(height: 0.5)
    }

    private func smallQuote(_ label: String, _ value: String, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(MarketPalette.muted)
            Text(value).foregroundStyle(tint)
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.65)
    }

    private func bookQuote(_ label: String, price: String, quantity: Double?) -> some View {
        let size = quantity.flatMap { value in
            value.isFinite && value >= 0
                ? value.formatted(.number.precision(.fractionLength(0))) : nil
        } ?? "--"
        return HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(MarketPalette.muted)
                .fixedSize()
            Text(price)
                .foregroundStyle(MarketPalette.ink)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(size + (size == "--" ? "" : "手"))
                .foregroundStyle(MarketPalette.muted)
                .frame(width: 43, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .accessibilityElement(children: .combine)
    }

}


/// Only a confirmed bar timestamp anchors the timer. Do not invent a new
/// candle during exchange breaks or show calendar-day/week countdowns.
private struct CandleCountdownView: View {
    let barStart: Int64?
    let period: Int
    let running: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(label(at: context.date))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(MarketPalette.countdown)
                .frame(minWidth: 48)
                .lineLimit(1)
                .accessibilityLabel("当前K线剩余时间")
        }
    }

    private func label(at date: Date) -> String {
        guard running, period > 0, period < 86400, let barStart else { return "--:--" }
        let remaining = Double(barStart) + Double(period) - date.timeIntervalSince1970
        guard remaining > 0, remaining <= Double(period) else { return "--:--" }
        let seconds = Int(remaining.rounded(.up))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

enum QihuiPeriods {
    static let all = ["1分","3分","5分","10分","15分","30分","60分","120分","日线","周线"]
    static let defaults = ["1分","5分","15分","30分","60分","日线","周线"]
    static let labels = ["1分":"1m","3分":"3m","5分":"5m","10分":"10m","15分":"15m","30分":"30m","60分":"1h","120分":"2h","日线":"日","周线":"周"]
    static let seconds = ["1分":60,"3分":180,"5分":300,"10分":600,"15分":900,"30分":1800,"60分":3600,"120分":7200,"日线":86400,"周线":604800]
    static func visible(_ stored: String, hidden: String) -> [String] {
        var result: [String] = []
        let excluded = Set(hidden.split(separator: ",").map(String.init))
        for item in stored.split(separator: ",").map(String.init) + defaults + all {
            if all.contains(item), !excluded.contains(item), !result.contains(item) { result.append(item) }
        }
        return result.isEmpty ? defaults : result
    }
}

struct PeriodOrderView: View {
    @Environment(\.dismiss) private var dismiss
    @State var order: [String]
    let label: (String) -> String
    let onSave: ([String]) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(order, id: \.self) { item in
                    HStack {
                        Text(label(item))
                        Spacer()
                        Button { if order.count > 1 { order.removeAll { $0 == item } } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).disabled(order.count <= 1)
                    }
                }
                .onMove { source, destination in
                    order.move(fromOffsets: source, toOffset: destination)
                }
                Section("未显示周期") {
                    ForEach(QihuiPeriods.all.filter { !order.contains($0) }, id: \.self) { item in
                        Button { order.append(item) } label: { Label(label(item), systemImage: "plus.circle") }
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("周期排序")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { onSave(order); dismiss() }
                }
            }
        }
    }
}
