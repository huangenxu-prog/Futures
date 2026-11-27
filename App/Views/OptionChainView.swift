import SwiftUI

private func optionNumber(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "--" }
    return value.formatted(.number.precision(.fractionLength(0...2)))
}
private func optionDays(_ value: Double?) -> String {
    guard let value, value.isFinite, value > 0 else { return "--" }
    return String(max(0, Int(ceil((value - Date().timeIntervalSince1970) / 86400)))) + "天"
}

private struct OptionColumnOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct OptionChainView: View {
    let code: String
    let underlyingLast: Double?
    let underlyingName: String
    let productID: String
    @State private var activeCode: String
    @State private var months: [MarketDataService.ContractQuote] = []
    @State private var monthError = false
    @State private var loadID = UUID()
    init(code: String, underlyingLast: Double? = nil, underlyingName: String? = nil, productID: String? = nil) {
        self.code = code; self.underlyingLast = underlyingLast; self.underlyingName = underlyingName ?? code
        self.productID = productID ?? String(code.prefix(while: { !$0.isNumber }))
        _activeCode = State(initialValue: code)
    }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("qihui.change.basis.v1") private var basis = "settlement"
    @State private var rows: [MarketDataService.OptionQuote] = []
    @State private var last: Double?
    @State private var side = "PUT"
    @State private var selected: MarketDataService.OptionQuote?
    @State private var error: String?
    @State private var loading = false
    @State private var initialPosition = false
    @State private var anchor: Double?
    @State private var sort = 0
    @State private var descending = false
    @State private var columnOffset: CGFloat = 0
    private let headings = ["最新价","涨幅%","持仓量","成交量","日增仓","买一","卖一","买一量","卖一量","今开","最高","最低","昨结"]
    private var spot: Double? { last ?? (activeCode == code ? underlyingLast : nil) }
    private var name: String { underlyingName + monthLabel(activeCode) }
    private func monthLabel(_ symbol: String) -> String {
        if let month = months.first(where: { $0.code == symbol })?.month, month.count == 4 { return month }
        let digits = String(symbol.reversed().prefix(while: { $0.isNumber }).reversed())
        if digits.count == 3, let yearDigit = digits.first?.wholeNumberValue {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
            let year = cal.component(.year, from: Date())
            let decade = year / 10 * 10
            let possible = [decade - 10 + yearDigit, decade + yearDigit, decade + 10 + yearDigit]
            let nearest = possible.min { abs($0-year) < abs($1-year) } ?? year
            return String(format: "%02d", nearest % 100) + String(digits.suffix(2))
        }
        return digits
    }
    private func switchMonth(_ symbol: String) {
        guard symbol != activeCode else { return }
        loadID = UUID(); rows = []; last = nil; error = nil; loading = false
        initialPosition = false; anchor = nil; activeCode = symbol
    }
    private var nearest: Double? {
        guard let spot else { return nil }
        return rows.map(\.strike).min { abs($0-spot) < abs($1-spot) }
    }
    private var visible: [MarketDataService.OptionQuote] {
        rows.filter { $0.side == side }.sorted { a,b in
            if sort == 0 { return descending ? a.strike > b.strike : a.strike < b.strike }
            let x = values(a)[sort-1], y = values(b)[sort-1]
            guard let x else { return false }; guard let y else { return true }
            return x == y ? a.strike < b.strike : (descending ? x > y : x < y)
        }
    }
    private func values(_ q: MarketDataService.OptionQuote) -> [Double?] {
        let ref = basis == "open" ? q.opening : q.settlement
        let change = ref.flatMap { r in r > 0 ? q.last.map { ($0-r)/r*100 } : nil }
        let increase = q.previousInterest.flatMap { p in q.interest.map { $0-p } }
        return [q.last,change,q.interest,q.volume,increase,q.bid,q.ask,q.bidVolume,q.askVolume,q.opening,q.highest,q.lowest,q.settlement]
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("标的最新价").font(.caption).foregroundStyle(MarketPalette.muted)
                        Text(optionNumber(spot)).font(.title2.bold()).monospacedDigit()
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("剩余期限").font(.caption).foregroundStyle(MarketPalette.muted)
                        Text(optionDays(visible.first(where: { $0.expireEpoch != nil })?.expireEpoch)).font(.title2.bold()).foregroundStyle(MarketPalette.countdown)
                    }
                }.padding(.horizontal, 14)
                Picker("方向", selection: $side) { Text("沽 PUT").tag("PUT"); Text("购 CALL").tag("CALL") }.pickerStyle(.segmented).padding(.horizontal, 12)
                if loading && rows.isEmpty { Spacer(); ProgressView("获取期权行情"); Spacer() }
                else if rows.isEmpty { Spacer(); Text(error ?? "暂无挂牌期权"); Button("重试") { Task { await load() } }; Spacer() }
                else {
                    if let error { Text(error).font(.caption).foregroundStyle(MarketPalette.muted) }
                    GeometryReader { geometry in
                    let columnWidth = max(58, (geometry.size.width - 54) / 4)
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            Button("行权价") { changeSort(0) }
                                .font(.caption.weight(.semibold)).frame(width: 54, height: 32)
                                .background(MarketPalette.raised)
                            HStack(spacing: 0) {
                                ForEach(headings.indices, id: \.self) { j in
                                    Button(headings[j] + (sort == j+1 ? (descending ? "↓" : "↑") : "")) { changeSort(j+1) }
                                        .font(.caption).foregroundStyle(MarketPalette.muted).frame(width: columnWidth, height: 32)
                                }
                            }
                            .fixedSize(horizontal: true, vertical: false)
                            .offset(x: columnOffset)
                            .frame(width: max(0, geometry.size.width - 54), alignment: .leading)
                            .clipped()
                            .contentShape(Rectangle())
                        }
                        .frame(width: geometry.size.width, alignment: .leading)
                        .background(MarketPalette.background)
                        ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            HStack(alignment: .top, spacing: 0) {
                                VStack(spacing: 0) {
                                    ForEach(visible) { q in
                                        Button { selected = q } label: {
                                            Text(optionNumber(q.strike)).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                                                .foregroundStyle(q.strike == nearest ? MarketPalette.countdown : MarketPalette.ink)
                                                .frame(width: 54, height: 43).contentShape(Rectangle())
                                        }.buttonStyle(.plain).id(q.strike)
                                        Divider().frame(height: 1)
                                    }
                                }.frame(width: 54).clipped().background(MarketPalette.raised)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    VStack(spacing: 0) {
                                        ForEach(visible) { q in
                                            Button { selected = q } label: {
                                                HStack(spacing: 0) {
                                                    ForEach(headings.indices, id: \.self) { j in
                                                        let v = values(q)[j]
                                                        Text(optionNumber(v) + (j == 1 && v != nil ? "%" : ""))
                                                            .font(.system(size: 13)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                                                            .foregroundStyle(j == 1 || j == 4 ? MarketPalette.movement(v) : MarketPalette.ink)
                                                            .frame(width: columnWidth, height: 43)
                                                    }
                                                }.contentShape(Rectangle())
                                            }.buttonStyle(.plain)
                                            Divider().frame(height: 1)
                                        }
                                    }
                                    .background {
                                        GeometryReader { contentGeometry in
                                            Color.clear.preference(key: OptionColumnOffsetKey.self,
                                                value: contentGeometry.frame(in: .named("optionColumns")).minX)
                                        }
                                    }
                                }
                                .coordinateSpace(name: "optionColumns")
                                .onPreferenceChange(OptionColumnOffsetKey.self) { columnOffset = $0 }
                                .frame(width: max(0, geometry.size.width - 54)).clipped()
                            }.frame(width: geometry.size.width, alignment: .leading)
                        }.refreshable { await load() }
                        .onAppear {
                            if !initialPosition, let nearest { initialPosition = true; anchor = nearest; proxy.scrollTo(nearest, anchor: .center) }
                        }
                        .onChange(of: rows.count) { _, count in
                            if count > 0 && !initialPosition, let nearest { initialPosition = true; anchor = nearest; proxy.scrollTo(nearest, anchor: .center) }
                        }
                        .onChange(of: side) { _, _ in
                            if let target = anchor ?? nearest { proxy.scrollTo(target, anchor: .center) }
                        }
                    }
                    }
                    }
                }
            }.background(MarketPalette.background)
            .navigationTitle(name + " 期权").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if months.isEmpty {
                            Button(monthError ? "重新加载月份" : "加载月份") { Task { await loadMonths() } }
                        }
                        ForEach(months) { month in
                            Button {
                                switchMonth(month.code)
                            } label: {
                                if month.code == activeCode { Label(monthLabel(month.code), systemImage: "checkmark") }
                                else { Text(monthLabel(month.code)) }
                            }
                        }
                    } label: {
                        HStack(spacing: 3) { Text(monthLabel(activeCode)); Image(systemName: "chevron.down") }.font(.subheadline)
                    }
                }
            }
            .task(id: productID) { await loadMonths() }
            .navigationDestination(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                if let q = selected { OptionDetailView(underlying: activeCode, name: name, initial: q, initialSpot: spot) }
            }
            .task(id: "\(activeCode)-\(scenePhase)-\(selected?.code ?? "")") {
                guard scenePhase == .active, selected == nil else { return }
                repeat { await load(); do { try await Task.sleep(for: .seconds(20)) } catch { return } } while !Task.isCancelled
            }
        }.tint(MarketPalette.accent)
    }
    private func changeSort(_ column: Int) {
        if sort == column { descending.toggle() } else { sort = column; descending = column != 0 }
    }
    @MainActor private func loadMonths() async {
        do {
            let result = try await MarketDataService.listedContracts(for: productID)
            guard !Task.isCancelled else { return }
            months = result; monthError = false
        } catch { if !Task.isCancelled { monthError = true } }
    }
    @MainActor private func load() async {
        guard !loading else { return }
        let request = UUID(), symbol = activeCode
        loadID = request; loading = true
        defer { if loadID == request { loading = false } }
        do {
            let result = try await MarketDataService.options(for: symbol)
            guard !Task.isCancelled, loadID == request, activeCode == symbol else { return }
            rows = result; error = nil
            if let q = try? await MarketDataService.contractQuote(symbol: symbol), !Task.isCancelled, loadID == request, activeCode == symbol { last = q.last }
        } catch { if !Task.isCancelled, loadID == request, activeCode == symbol { self.error = "行情更新失败，请重试" } }
    }
}

private struct OptionDetailView: View {
    let underlying: String
    let name: String
    let initial: MarketDataService.OptionQuote
    let initialSpot: Double?
    @Environment(\.scenePhase) private var scenePhase
    @State private var quote: MarketDataService.OptionQuote?
    @State private var spot: Double?
    @State private var underlyingBars: [MarketBar] = []
    @State private var optionBars: [MarketBar] = []
    @State private var period = 1800
    @State private var selectedTime: Int64?
    @State private var error: String?
    @State private var trading = false
    private var q: MarketDataService.OptionQuote { quote ?? initial }
    private var put: Bool { q.side == "PUT" }
    private var label: String { (put ? "沽" : "购") + optionNumber(q.strike) }
    private var underlyingPrice: Double? { spot ?? initialSpot }
    private var intrinsic: Double? { underlyingPrice.map { max(0, put ? q.strike-$0 : $0-q.strike) } }
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                HStack {
                    metric("期权最新", optionNumber(q.last), color: MarketPalette.movement(q.settlement.flatMap { s in q.last.map { $0-s } }))
                    metric("标的价格", optionNumber(underlyingPrice))
                    metric("剩余期限", optionDays(q.expireEpoch), color: MarketPalette.countdown)
                }
                Divider()
                chartSection(name + " · 标的走势", bars: underlyingBars)
                Divider()
                chartSection(label + " · 期权走势", bars: optionBars)
                HStack {
                    ForEach([60,300,900,1800,3600,86400], id: \.self) { p in
                        Button(p == 86400 ? "日线" : "\(p/60)分") { period = p }
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(period == p ? MarketPalette.accent : MarketPalette.muted)
                            .frame(maxWidth: .infinity)
                    }
                }
                if let error { Text(error).font(.caption).foregroundStyle(MarketPalette.muted) }
                Divider()
                HStack { metric("行权价", optionNumber(q.strike)); metric("买一", optionNumber(q.bid)); metric("卖一", optionNumber(q.ask)) }
                HStack {
                    metric("内在价值", optionNumber(intrinsic))
                    metric("时间价值", optionNumber(intrinsic.flatMap { v in q.last.map { $0-v } }))
                    metric("到期盈亏平衡价", optionNumber(q.last.map { put ? q.strike-$0 : q.strike+$0 }))
                }
                Text("按最新权利金估算，未计手续费").font(.caption2).foregroundStyle(MarketPalette.muted)
            }.padding(12)
        }.background(MarketPalette.background)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button { trading = true } label: {
                Text("快捷交易").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
            }.buttonStyle(.borderedProminent)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(MarketPalette.background)
        }
        .navigationTitle(name + " " + label).navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $trading) {
            QuickTradeSheet(contract: q.paperContract(underlying: underlying, name: name))
                .presentationDetents([.height(460), .large]).presentationDragIndicator(.visible)
        }
        .task(id: "\(period)-\(scenePhase)") {
            guard scenePhase == .active else { return }
            underlyingBars = []; optionBars = []; selectedTime = nil; error = nil
            let p = period
            repeat {
                async let u = try? MarketDataService.fetch(symbol: underlying, period: p, count: 200, mergeCached: false)
                async let o = try? MarketDataService.fetch(symbol: initial.code, period: p, count: 200, mergeCached: false)
                let (ub, ob) = await (u, o)
                guard !Task.isCancelled, period == p else { return }
                if let ub, !ub.isEmpty { underlyingBars = ub }
                if let ob, !ob.isEmpty { optionBars = ob }
                error = ub == nil || ob == nil ? "部分K线暂不可用，请核对行情网关" : nil
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            } while !Task.isCancelled
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            repeat {
                if let updated = try? await MarketDataService.optionQuote(symbol: initial.code, underlying: underlying), !Task.isCancelled { quote = updated }
                if let updated = try? await MarketDataService.contractQuote(symbol: underlying), !Task.isCancelled { spot = updated.last }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            } while !Task.isCancelled
        }
    }
    private func metric(_ title: String, _ value: String, color: Color = MarketPalette.ink) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(MarketPalette.muted)
            Text(value).font(.system(size: 19, weight: .semibold)).monospacedDigit().foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.6)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func chartSection(_ title: String, bars: [MarketBar]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            if bars.isEmpty {
                Text("暂无K线 · 正在请求行情").font(.caption).foregroundStyle(MarketPalette.muted).frame(maxWidth: .infinity).frame(height: 155)
            } else {
            OptionCandles(bars: bars, axis: Array(Set(underlyingBars.map(\.time) + optionBars.map(\.time))).sorted().suffix(52).map { $0 }, selectedTime: $selectedTime)
                .frame(height: 155)
            }
            if let selectedTime, let bar = bars.first(where: { $0.time == selectedTime }) {
                Text("收 " + optionNumber(bar.close) + "  高 " + optionNumber(bar.high) + "  低 " + optionNumber(bar.low)).font(.caption2)
            }
        }
    }
}

private struct OptionCandles: View {
    let bars: [MarketBar]
    let axis: [Int64]
    @Binding var selectedTime: Int64?
    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let plotted = bars.filter { axis.contains($0.time) }
                guard let lo = plotted.map(\.low).min(), let hi = plotted.map(\.high).max(), !axis.isEmpty else { return }
                let span = max(hi-lo, 0.000001), width = max(1,size.width-42), height = size.height-12
                let step = width / CGFloat(axis.count)
                func y(_ p: Double) -> CGFloat { 6 + CGFloat((hi-p)/span)*max(1,height-12) }
                for j in 0...3 {
                    let v = hi-span*Double(j)/3, yy = y(v)
                    var line = Path(); line.move(to: CGPoint(x:0,y:yy)); line.addLine(to: CGPoint(x:width,y:yy))
                    ctx.stroke(line, with: .color(MarketPalette.divider), style: StrokeStyle(lineWidth:0.6,dash:[3,3]))
                    ctx.draw(Text(optionNumber(v)).font(.system(size:9)).foregroundStyle(MarketPalette.muted), at: CGPoint(x:width+3,y:yy), anchor:.leading)
                }
                for (index,t) in axis.enumerated() {
                    guard let b = plotted.first(where: { $0.time == t }) else { continue }
                    let x = (CGFloat(index)+0.5)*step, color = b.close >= b.open ? MarketPalette.up : MarketPalette.down
                    var wick = Path(); wick.move(to: CGPoint(x:x,y:y(b.high))); wick.addLine(to: CGPoint(x:x,y:y(b.low)))
                    ctx.stroke(wick, with:.color(color),lineWidth:0.8)
                    let rect = CGRect(x:x-step*0.3,y:min(y(b.open),y(b.close)),width:max(1,step*0.6),height:max(1,abs(y(b.open)-y(b.close))))
                    if b.close >= b.open { ctx.stroke(Path(rect),with:.color(color),lineWidth:1) } else { ctx.fill(Path(rect),with:.color(color)) }
                }
                if let selectedTime, let index = axis.firstIndex(of:selectedTime) {
                    let x = (CGFloat(index)+0.5)*step
                    var line = Path(); line.move(to:CGPoint(x:x,y:0)); line.addLine(to:CGPoint(x:x,y:height))
                    ctx.stroke(line,with:.color(MarketPalette.muted),style:StrokeStyle(lineWidth:1,dash:[3,3]))
                }
            }.contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard !axis.isEmpty else { return }
                let ratio = value.location.x / max(1,geo.size.width-42)
                selectedTime = axis[min(axis.count-1,max(0,Int(ratio*CGFloat(axis.count))))]
            })
        }
    }
}
