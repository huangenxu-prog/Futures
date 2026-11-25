import SwiftUI

struct QihuiSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("qihui.appearance.mode.v1") private var appearance = AppAppearanceMode.dark.rawValue
    @AppStorage("qihui.change.basis.v1") private var changeBasis = "settlement"
    let instruments: [FuturesInstrument]
    let favoriteIDs: [String]
    let mainCodes: [String:String]
    @State private var marketAccess = false
    @State private var marketKey = ""
    @State private var marketKeyError = false
    @State private var strategy = false
    @State private var account = false
    @State private var indicators = false
    @State private var candle = false
    @State private var period = false
    @AppStorage("qihui.chart.period-order.v1") private var storedPeriodOrder = ""
    @AppStorage("qihui.chart.period-hidden.v1") private var hiddenPeriods = "3分,10分,120分"
    private var periods: [String] { QihuiPeriods.visible(storedPeriodOrder, hidden: hiddenPeriods) }
    var body: some View {
        NavigationStack {
            Form {
                Section("行情") {
                    Picker("涨跌幅基准", selection: $changeBasis) {
                        Text("昨结").tag("settlement")
                        Text("今开").tag("open")
                    }.pickerStyle(.segmented)
                    Text("今开为交易日开盘价；行情未提供基准时显示 --。").font(.caption).foregroundStyle(.secondary)
                    Button("行情访问密钥") {
                        marketKey = ""
                        marketKeyError = false
                        marketAccess = true
                    }
                }
                Section("图表与指标") {
                    Button("K线样式") { candle = true }
                    Button("周期排序") { period = true }
                    Button("指标管理") { indicators = true }
                }
                Section("外观") {
                    Picker("主题", selection: $appearance) {
                        ForEach(AppAppearanceMode.allCases) { mode in Text(mode.title).tag(mode.rawValue) }
                    }
                }
                Section("策略与回测") {
                    Button { strategy = true } label: {
                        HStack { Text("策略回测"); Spacer(); Image(systemName: "chevron.right") }
                    }
                }
                Section("账户与交易") {
                    Button { account = true } label: {
                        HStack { Text("交易设置"); Spacer(); Image(systemName: "chevron.right") }
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .sheet(isPresented: $marketAccess) {
                NavigationStack {
                    Form {
                        SecureField("输入独立行情密钥", text: $marketKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Text("密钥仅保存在本机钥匙串。保存后重新打开期汇，以新密钥连接。").font(.caption)
                        if marketKeyError { Text("密钥格式无效或保存失败").foregroundStyle(.red) }
                        Button("保存") {
                            if MarketAccessKey.save(marketKey.trimmingCharacters(in: .whitespacesAndNewlines)) {
                                marketKey = ""
                                marketAccess = false
                            } else { marketKeyError = true }
                        }.disabled(marketKey.isEmpty)
                        Button("清除已保存密钥", role: .destructive) {
                            if MarketAccessKey.save("") { marketAccess = false }
                            else { marketKeyError = true }
                        }
                    }
                    .navigationTitle("行情访问密钥")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { marketAccess = false } } }
                }
            }
            .sheet(isPresented: $strategy) { StrategyCenterView(instruments: instruments, favoriteIDs: favoriteIDs, mainCodes: mainCodes) }
            .sheet(isPresented: $account) { TradeConnectionSettingsView() }
            .sheet(isPresented: $indicators) { IndicatorSettingsView(settings: ChartDisplaySettings.load()) { $0.save() } }
            .sheet(isPresented: $candle) { CandleAppearanceView() }
            .sheet(isPresented: $period) {
                PeriodOrderView(order: periods, label: { QihuiPeriods.labels[$0] ?? $0 }) { updated in
                    storedPeriodOrder = updated.joined(separator: ",")
                    hiddenPeriods = QihuiPeriods.all.filter { !updated.contains($0) }.joined(separator: ",")
                }
            }
        }.tint(MarketPalette.accent)
    }
}
