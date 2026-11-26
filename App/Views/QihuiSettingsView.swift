import SwiftUI

struct QihuiSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("qihui.appearance.mode.v1") private var appearance = AppAppearanceMode.dark.rawValue
    @AppStorage("qihui.change.basis.v1") private var changeBasis = "settlement"
    let instruments: [FuturesInstrument]
    let favoriteIDs: [String]
    let mainCodes: [String:String]
    @State private var marketConfigured = false
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

                }
                Section("服务器配置") {
                    LabeledContent("行情服务器", value: MarketDataService.configuredHost)
                    LabeledContent("行情访问密钥", value: marketConfigured ? "已配置" : "未配置")
                    SecureField("更换行情访问密钥（可选）", text: $marketKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if marketKeyError { Text("密钥格式无效或保存失败").foregroundStyle(.red) }
                    Button("保存行情密钥") {
                        if MarketAccessKey.save(marketKey.trimmingCharacters(in: .whitespacesAndNewlines)) {
                            marketKey = ""; marketKeyError = false; marketConfigured = !MarketAccessKey.load().isEmpty
                        } else { marketKeyError = true }
                    }.disabled(marketKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("行情正常时无需设置。密钥仅保存在本机钥匙串，修改后重新打开期汇。").font(.caption).foregroundStyle(.secondary)
                    if marketConfigured {
                        Button("清除行情密钥", role: .destructive) {
                            if MarketAccessKey.save("") { marketConfigured = false; marketKey = ""; marketKeyError = false }
                            else { marketKeyError = true }
                        }
                    }
                    Button { account = true } label: {
                        HStack { Text("交易网关与账户配置"); Spacer(); Image(systemName: "chevron.right") }
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
            .onAppear { marketConfigured = !MarketAccessKey.load().isEmpty }
            .onDisappear { marketKey = "" }
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
