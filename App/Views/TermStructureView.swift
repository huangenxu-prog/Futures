import SwiftUI

struct TermStructureView: View {
    let symbol: String
    let name: String
    let product: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("qihui.change.basis.v1") private var basis = "settlement"
    @State private var period = 0
    @State private var contracts: [MarketDataService.ContractQuote] = []
    @State private var history: [String: [MarketBar]] = [:]
    @State private var dailyFallback: [String: MarketBar] = [:]
    @State private var fallbackAttempt: [String: Date] = [:]
    @State private var loading = false
    @State private var error: String?
    private let labels = ["实时", "1日前", "1周前", "2周前", "1月前", "3月前", "6月前"]
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return cal
    }
    private func targetDay(_ index: Int) -> Date {
        let now = calendar.startOfDay(for: Date())
        if index >= 4 {
            return calendar.date(byAdding: .month, value: -[1,3,6][index-4], to: now) ?? now
        }
        return calendar.date(byAdding: .day, value: -[0,1,7,14][index], to: now) ?? now
    }
    private func day(_ bar: MarketBar) -> Date {
        calendar.startOfDay(for: Date(timeIntervalSince1970: Double(bar.time)))
    }
    private var historicalDay: Date? {
        guard period != 0 else { return nil }
        let target = targetDay(period)
        return history.values.flatMap { $0 }.map(day).filter { $0 <= target }.max()
    }
    private struct Row: Identifiable {
        let id: String
        let month: String
        let price: Double?
        let ratio: Double?
        let volume: Double?
        let interest: Double?
        var fallbackDay: Date? = nil
        var label: String { String(id.split(separator: ".").last ?? "") }
    }
    private var rows: [Row] {
        let date = historicalDay
        return contracts.map { q in
            if period == 0 {
                if let price = finite(q.last) {
                    return Row(id:q.code, month:q.month, price:price, ratio:q.ratio(basis:basis), volume:q.volume, interest:q.interest)
                }
                if let bar = dailyFallback[q.code] {
                    let reference = basis == "open" ? bar.open : bar.preSettlement
                    let ratio = reference.flatMap { $0 > 0 ? bar.close / $0 - 1 : nil }
                    return Row(id:q.code, month:q.month, price:finite(bar.close), ratio:ratio, volume:Double(bar.volume), interest:bar.closeInterest, fallbackDay:day(bar))
                }
                return Row(id:q.code, month:q.month, price:nil, ratio:nil, volume:nil, interest:q.interest)
            }
            let bars = history[q.code] ?? []
            guard let date, let bar = bars.last(where: { day($0) == date }) else {
                return Row(id:q.code, month:q.month, price:nil, ratio:nil, volume:nil, interest:nil)
            }
            let reference = basis == "open" ? bar.open : bar.preSettlement
            let ratio = reference.flatMap { $0 > 0 ? bar.close / $0 - 1 : nil }
            return Row(id:q.code, month:q.month, price:finite(bar.close), ratio:ratio, volume:Double(bar.volume), interest:bar.closeInterest)
        }
    }
    private func finite(_ v: Double?) -> Double? {
        guard let v, v.isFinite, v > 0 else { return nil }
        return v
    }
    private func number(_ v: Double?, signed: Bool = false) -> String {
        guard let v, v.isFinite else { return "--" }
        return (signed && v > 0 ? "+" : "") + v.formatted(.number.precision(.fractionLength(0...2)))
    }
    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                structureContent(columnWidth: max(55, (geo.size.width - 84) / 5))
            }
            .background(MarketPalette.background)
            .navigationTitle(pageTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("返回")
                }
            }
            .task(id: "\(period)-\(scenePhase)") {
                guard scenePhase == .active else { return }
                await load(period)
            }
        }.tint(MarketPalette.accent)
    }
    private var pageTitle: String {
        let month = contracts.first(where: { $0.code == symbol })?.month
        return name + (month ?? " " + String(symbol.split(separator: ".").last ?? ""))
    }
    private func dateLabel(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
    private var datePickerBar: some View {
        HStack(spacing: 4) {
            ForEach(labels.indices, id: \.self) { i in
                Button(labels[i]) { period = i }
                    .font(.system(size: 11, weight: .medium)).lineLimit(1)
                    .frame(maxWidth: .infinity).frame(height: 30)
                    .foregroundStyle(period == i ? MarketPalette.accent : MarketPalette.muted)
                    .background(period == i ? MarketPalette.accent.opacity(0.12) : MarketPalette.raised)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        }.buttonStyle(.plain).padding(.horizontal, 8)
    }
    private func structureContent(columnWidth: CGFloat) -> some View {
        let data = rows
        let base = data.first(where: { $0.id == symbol })
        return VStack(spacing: 8) {
            datePickerBar
            if loading { ProgressView().controlSize(.small) }
            if let error { Text(error).font(.caption2).foregroundStyle(MarketPalette.muted) }
            if period != 0, let date = historicalDay {
                Text(dateLabel(date)).font(.caption2).foregroundStyle(MarketPalette.muted)
            }
            if period == 0, data.contains(where: { $0.fallbackDay != nil }) {
                Text("* 最近可用日线价，非实时成交价").font(.caption2).foregroundStyle(MarketPalette.muted)
            }
            if !data.contains(where: { $0.price != nil }) {
                Text(loading ? "正在获取行情" : "暂无有效价格，等待行情更新")
                    .font(.caption).foregroundStyle(MarketPalette.muted)
                    .frame(maxWidth:.infinity).frame(height:190)
            } else {
                chart(data).frame(height: 190).padding(.horizontal, 8)
            }
            structureTable(data, base: base, col: columnWidth)
        }
    }
    private func structureTable(_ data: [Row], base: Row?, col: CGFloat) -> some View {
        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {
                contractColumn(data)
                ScrollView(.horizontal, showsIndicators: false) {
                    dataColumn(data, base: base, col: col)
                }.clipped()
            }.padding(.horizontal, 8)
        }
    }
    private func rowBackground(_ row: Row) -> Color {
        row.id == symbol ? MarketPalette.raised : MarketPalette.background
    }
    private func contractColumn(_ data: [Row]) -> some View {
        VStack(spacing: 0) {
            cell("合约", width: 68, color: MarketPalette.muted, leading: true)
                .background(MarketPalette.raised)
            ForEach(data) { row in
                VStack(spacing: 0) {
                    cell(row.label, width: 68, leading: true).background(rowBackground(row))
                    Divider().frame(height: 1)
                }
            }
        }.frame(width: 68).background(MarketPalette.background).zIndex(1)
    }
    private func dataColumn(_ data: [Row], base: Row?, col: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(["最新", "价差", "涨跌幅", "成交量", "持仓量"], id: \.self) { title in
                    cell(title, width: col, color: MarketPalette.muted)
                }
            }.background(MarketPalette.raised)
            ForEach(data) { row in
                VStack(spacing: 0) {
                    quoteRow(row, base: base, col: col)
                    Divider().frame(height: 1)
                }
            }
        }.fixedSize(horizontal: true, vertical: false)
    }
    private func quoteRow(_ row: Row, base: Row?, col: CGFloat) -> some View {
        let spread: Double? = base.flatMap { b in
            guard b.fallbackDay == row.fallbackDay, let bp = b.price, let rp = row.price else { return nil }
            return rp - bp
        }
        let percent = row.ratio.map { String(format: "%+.2f%%", $0 * 100) } ?? "--"
        let movement = MarketPalette.movement(row.ratio)
        return HStack(spacing: 0) {
            cell(number(row.price) + (row.fallbackDay != nil ? "*" : ""), width: col, color: movement)
            cell(number(spread, signed: true), width: col, color: MarketPalette.movement(spread))
            cell(percent, width: col, color: movement)
            cell(CompactMarketQuantity.format(row.volume), width: col)
            cell(CompactMarketQuantity.format(row.interest), width: col)
        }.background(rowBackground(row))
    }
    private func cell(_ value:String,width:CGFloat,color:Color = MarketPalette.ink,leading:Bool = false) -> some View {
        Text(value).font(.system(size:13)).monospacedDigit().lineLimit(1)
            .foregroundStyle(color).frame(width:width,height:32,alignment:leading ? .leading : .trailing)
            .padding(.trailing,0).clipped()
    }
    private func chart(_ data:[Row]) -> some View {
        Canvas { ctx,size in
            let prices = data.compactMap(\.price)
            guard let low = prices.min(), let high = prices.max(), !data.isEmpty else { return }
            let span = max(high-low, max(abs(high)*0.02,1))
            let bottom = low-span*0.12, top = high+span*0.12
            let ticks = (0...4).map { bottom + (top-bottom)*Double($0)/4 }
            let labelWidths = ticks.map { price in
                ctx.resolve(Text(number(price)).font(.system(size:10)).monospacedDigit())
                    .measure(in: CGSize(width: size.width, height: 24)).width
            }
            let left: CGFloat = max(44, (labelWidths.max() ?? 0) + 12)
            let right = max(left+1,size.width-18)
            let h = max(1,size.height-36)
            func x(_ i:Int)->CGFloat { left + (right-left)*CGFloat(i)/CGFloat(max(1,data.count-1)) }
            func y(_ p:Double)->CGFloat { 10 + CGFloat((top-p)/max(1,top-bottom))*h }
            for i in 0...4 {
                let p = bottom+(top-bottom)*Double(i)/4
                var grid=Path(); grid.move(to:CGPoint(x:left,y:y(p)));grid.addLine(to:CGPoint(x:right,y:y(p)))
                ctx.stroke(grid,with:.color(MarketPalette.divider),lineWidth:0.6)
                ctx.draw(Text(number(p)).font(.system(size:10)).monospacedDigit().foregroundStyle(MarketPalette.muted),at:CGPoint(x:left-6,y:y(p)),anchor:.trailing)
            }
            var line=Path()
            var started=false
            for (i,row) in data.enumerated() {
                let xx=x(i)
                if i % max(1,Int(ceil(Double(data.count)/12))) == 0 {
                    ctx.draw(Text(row.month).font(.system(size:9)).foregroundStyle(MarketPalette.muted),at:CGPoint(x:xx,y:size.height-10))
                }
                if row.id == symbol {
                    var marker=Path();marker.move(to:CGPoint(x:xx,y:10));marker.addLine(to:CGPoint(x:xx,y:h+10))
                    ctx.stroke(marker,with:.color(MarketPalette.muted),style:StrokeStyle(lineWidth:1,dash:[3,3]))
                }
                guard let p=row.price else { started=false;continue }
                let point=CGPoint(x:xx,y:y(p))
                if started { line.addLine(to:point) } else { line.move(to:point);started=true }
                ctx.fill(Path(ellipseIn:CGRect(x:point.x-2.5,y:point.y-2.5,width:5,height:5)),with:.color(MarketPalette.up))
            }
            ctx.stroke(line,with:.color(MarketPalette.up),lineWidth:1.5)
        }
    }
    @MainActor private func load(_ selection:Int) async {
        loading = true; error = nil
        defer { if !Task.isCancelled { loading=false } }
        if contracts.isEmpty || selection == 0 {
            do {
                let result = try await MarketDataService.listedContracts(for:product)
                guard !Task.isCancelled else { return }
                contracts=result.sorted { $0.month < $1.month }
            } catch { if !Task.isCancelled { self.error="合约行情获取失败" };return }
        }
        if selection == 0 {
            await loadMissingDailyQuotes()
            guard !Task.isCancelled else { return }
            loading=false
            while !Task.isCancelled {
                do { try await Task.sleep(for:.seconds(10)) } catch { return }
                if let result = try? await MarketDataService.listedContracts(for:product), !Task.isCancelled {
                    contracts=result.sorted { $0.month < $1.month };error=nil
                    await loadMissingDailyQuotes()
                } else if !Task.isCancelled { error="行情更新失败" }
            }
        } else {
            // Query only one delivery month at a time; no new SSE subscription.
            // Cache six months of daily history for all date selections.
            let cutoff = Int64(calendar.startOfDay(for:Date()).timeIntervalSince1970)
            for q in contracts where history[q.code] == nil {
                guard !Task.isCancelled else { return }
                do {
                    let bars = try await MarketDataService.fetchOlder(symbol:q.code,period:86400,before:cutoff,count:180,depth:500)
                    guard !Task.isCancelled else { return }
                    history[q.code]=bars
                } catch { if !Task.isCancelled { self.error="部分历史行情未取得" } }
            }
            if historicalDay == nil && !Task.isCancelled { error="暂无对应日期历史行情" }
        }
    }
    @MainActor private func loadMissingDailyQuotes() async {
        // Missing prices commonly occur between trading sessions. Read genuine
        // daily bars through the existing HTTP snapshot API, one at a time.
        // Never subscribe to a new live K-line stream or use settlement as last.
        for q in contracts where finite(q.last) == nil {
            guard !Task.isCancelled else { return }
            if let attempted = fallbackAttempt[q.code],
               Date().timeIntervalSince(attempted) < (dailyFallback[q.code] == nil ? 60 : 300) { continue }
            fallbackAttempt[q.code] = Date()
            do {
                let bars = try await MarketDataService.fetch(symbol:q.code, period:86400, count:5, mergeCached:false)
                guard !Task.isCancelled else { return }
                if let bar = bars.last(where: { finite($0.close) != nil }) {
                    dailyFallback[q.code] = bar
                }
            } catch {
                if Task.isCancelled { return }
                // A failed request is not evidence that the contract has no trades.
            }
        }
    }

}
