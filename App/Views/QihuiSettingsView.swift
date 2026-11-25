import SwiftUI

struct QihuiSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("qihui.appearance.mode.v1") private var appearance = AppAppearanceMode.dark.rawValue
    let instruments: [FuturesInstrument]
    let favoriteIDs: [String]
    let mainCodes: [String:String]
    @State private var strategy = false
    @State private var account = false
    var body: some View {
        NavigationStack {
            Form {
                Section("外观") {
                    Picker("主题", selection: $appearance) {
                        ForEach(AppAppearanceMode.allCases) { mode in Text(mode.title).tag(mode.rawValue) }
                    }
                }
                Section("策略") {
                    Button { strategy = true } label: {
                        HStack { Text("策略中心 / 回测"); Spacer(); Image(systemName: "chevron.right") }
                    }
                }
                Section("交易") {
                    Button { account = true } label: {
                        HStack { Text("交易账户"); Spacer(); Image(systemName: "chevron.right") }
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .sheet(isPresented: $strategy) { StrategyCenterView(instruments: instruments, favoriteIDs: favoriteIDs, mainCodes: mainCodes) }
            .sheet(isPresented: $account) { TradingCenterView(favoriteIDs: favoriteIDs, mainCodes: mainCodes) }
        }.tint(MarketPalette.accent)
    }
}
