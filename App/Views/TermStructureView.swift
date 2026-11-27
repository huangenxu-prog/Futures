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
        var label: String { String(id.split(separator: ".").last ?? "") }
    }
    private var rows: [Row] {
        let date = historicalDay
        return contracts.map { q in
            if period == 0 {
                return Row(id:q.code, month:q.month, price: finite(q.last), ratio: q.ratio(basis:basis), volume:q.volume, interest:q.interest)
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
        let data = rows
        let base = data.first(where: { $0.id == symbol })?.price
        let width: CGFloat = 68
        NavigationStack {
            GeometryReader { geo in
                let col = max(55, (geo.size.width - width - 16) / 5)
                VStack(spacing: 8) {
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
                    if loading { ProgressView().controlSize(.small) }
                    if let error { Text(error).font(.caption2).foregroundStyle(MarketPalette.muted) }
                    if period != 0, let date = historicalDay {
                        Text(calendar.dateComponents([.year,.month,.day], from: date).year.map { _ in String(format: "%04d-%02d-%02d", calendar.component(.year,from:date),calendar.component(.month,from:date),calendar.component(.day,from:date)) } ?? "")
                            .font(.caption2).foregroundStyle(MarketPalette.muted)
                    }
                    chart(data).frame(height: 190).padding(.horizontal, 8)
                    ScrollView(.vertical) {
                        HStack(alignment: .top, spacing: 0) {
                            VStack(spacing: 0) {
                                cell("合约", width: width, color: MarketPalette.muted, leading: true).background(MarketPalette.raised)
                                ForEach(data) { row in
                                    cell(row.label, width:width, leading:true)
                                        .background(row.id == symbol ? MarketPalette.raised : MarketPalette.background)
                                    Divider().frame(height: 1)
                                }
                            }.frame(width: width).background(MarketPalette.background).zIndex(1)
                            ScrollView(.horizontal, showsIndicators: false) {
                                VStack(spacing: 0) {
                                    HStack(spacing:0) {
                                        ForEach(["最新","价差","涨跌幅","成交量","持仓量"], id: \.self) {
                                            cell($0,width:col,color:MarketPalette.muted)
                                        }
                                    }.background(MarketPalette.raised)
                                    ForEach(data) { row in
                                        let spread = base.flatMap { b in row.price.map { $0-b } }
                                        HStack(spacing:0) {
                                            cell(number(row.price),width:col,color:MarketPalette.movement(row.ratio))
                                            cell(number(spread,signed:true),width:col,color:MarketPalette.movement(spread))
                                            cell(row.ratio.map { String(format:"%+.2f%%",$0*100) } ?? "--",width:col,color:MarketPalette.movement(row.ratio))
                                            cell(CompactMarketQuantity.format(row.volume),width:col)
                                            cell(CompactMarketQuantity.format(row.interest),width:col)
                                        }.background(row.id == symbol ? MarketPalette.raised : MarketPalette.background)
                                        Divider().frame(height: 1)
                                    }
                                }.fixedSize(horizontal:true,vertical:false)
                            }.clipped()
                        }.padding(.horizontal,8)
                    }
                }
            }
            .background(MarketPalette.background)
            .navigationTitle(name + (contracts.first(where: { $0.code == symbol })?.month ?? " " + String(symbol.split(separator: ".").last ?? "")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.cancellationAction) { Button { dismiss() } label: { Image(systemName:"chevron.left") }.accessibilityLabel("返回") } }
            .task(id: "\(period)-\(scenePhase)") {
                guard scenePhase == .active else { return }
                await load(period)
            }
        }.tint(MarketPalette.accent)
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
            let left:CGFloat = 44, right = max(left+1,size.width-10), h = max(1,size.height-30)
            func x(_ i:Int)->CGFloat { left + (right-left)*CGFloat(i)/CGFloat(max(1,data.count-1)) }
            func y(_ p:Double)->CGFloat { 5 + CGFloat((top-p)/max(1,top-bottom))*h }
            for i in 0...4 {
                let p = bottom+(top-bottom)*Double(i)/4
                var grid=Path(); grid.move(to:CGPoint(x:left,y:y(p)));grid.addLine(to:CGPoint(x:right,y:y(p)))
                ctx.stroke(grid,with:.color(MarketPalette.divider),lineWidth:0.6)
                ctx.draw(Text(number(p)).font(.system(size:10)).foregroundStyle(MarketPalette.muted),at:CGPoint(x:left-4,y:y(p)),anchor:.trailing)
            }
            var line=Path()
            var started=false
            for (i,row) in data.enumerated() {
                let xx=x(i)
                if i % max(1,Int(ceil(Double(data.count)/12))) == 0 {
                    ctx.draw(Text(row.month).font(.system(size:9)).foregroundStyle(MarketPalette.muted),at:CGPoint(x:xx,y:size.height-10))
                }
                if row.id == symbol {
                    var marker=Path();marker.move(to:CGPoint(x:xx,y:3));marker.addLine(to:CGPoint(x:xx,y:h+5))
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
            loading=false
            while !Task.isCancelled {
                do { try await Task.sleep(for:.seconds(10)) } catch { return }
                if let result = try? await MarketDataService.listedContracts(for:product), !Task.isCancelled {
                    contracts=result.sorted { $0.month < $1.month };error=nil
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
}
