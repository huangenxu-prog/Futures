import SwiftUI

struct QuickTradeSheet:View {
    let contract:PaperContract
    var body:some View {
        TradingCenterView(initialContract:contract, quickOnly: true)
    }
}

struct PaperContractPicker:View {
    @Environment(\.dismiss) private var dismiss
    let instruments:[FuturesInstrument]
    let favoriteIDs:[String]
    let mainCodes:[String:String]
    let onPick:(PaperContract)->Void
    @State private var search = ""
    private var matching:[FuturesInstrument] {
        let filtered = instruments.filter{search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search)}
        return filtered.sorted{ a,b in
            let ai = favoriteIDs.firstIndex(of:a.id) ?? Int.max
            let bi = favoriteIDs.firstIndex(of:b.id) ?? Int.max
            return ai == bi ? a.name.localizedCompare(b.name) == .orderedAscending : ai < bi
        }
    }
    var body:some View{
        NavigationStack{
            List{
                ForEach(matching){item in
                    NavigationLink {
                        PaperContractList(instrument:item,mainCode:mainCodes[item.id],onPick:onPick)
                    } label:{
                        HStack {
                            Text(item.name)
                            Spacer()
                            if let main = mainCodes[item.id] {Text(main).font(.caption).foregroundStyle(MarketPalette.muted)}
                        }
                    }
                }
            }
            .searchable(text:$search,prompt:"搜索品种")
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("选择交易合约")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar{ToolbarItem(placement:.cancellationAction){Button("取消"){dismiss()}}}
        }
    }
}
private struct PaperContractList:View {
    let instrument:FuturesInstrument
    let mainCode:String?
    let onPick:(PaperContract)->Void
    @State private var quotes:[MarketDataService.ContractQuote] = []
    @State private var loading = true
    @State private var error:String?
    var body:some View{
        List{
            if loading{ProgressView("读取挂牌合约")}
            if let error{Text(error).font(.caption);Button("重试"){Task{await load()}}}
            ForEach(quotes.sorted { a,b in
                if a.code == mainCode {return b.code != mainCode}
                if b.code == mainCode {return false}
                return a.code < b.code
            }){q in
                let contract = PaperContract(symbol:q.code,name:instrument.name,tick:q.priceTick,multiplier:q.volumeMultiple,last:q.last,bid:q.bid,ask:q.ask)
                Button{onPick(contract)}label:{
                    HStack{
                        Text(q.code)
                        if q.code == mainCode {Text("主力").font(.caption).foregroundStyle(MarketPalette.accent)}
                        Spacer()
                        Text(q.last.map{$0.formatted()} ?? "--").foregroundStyle(.secondary)
                    }
                }.disabled(!contract.hasMetadata)
            }
        }.navigationTitle(instrument.name).task{await load()}
    }
    @MainActor private func load()async{
        loading = true;error = nil;defer{loading = false}
        do{quotes = try await MarketDataService.listedContracts(for:instrument.id);if quotes.isEmpty{error = "暂无挂牌合约"}}
        catch{self.error = error.localizedDescription}
    }
}

// Entry and read-only layout only. No bank credentials, API calls, fake
// transfers, or changes to the paper ledger.
