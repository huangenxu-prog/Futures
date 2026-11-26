import SwiftUI

struct QihuiSettingsView: View {
    var backgroundStyle = MarketBackgroundStyle()
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
    @State private var indicators = false
    @State private var period = false
    @AppStorage("qihui.chart.period-order.v1") private var storedPeriodOrder = ""
    @AppStorage("qihui.chart.period-hidden.v1") private var hiddenPeriods = "3分,10分,120分"
    private var periods: [String] { QihuiPeriods.visible(storedPeriodOrder, hidden: hiddenPeriods) }
    var body: some View {
        NavigationStack {
            Form {
                Section("常规") {
                    Text("涨跌幅基准").font(.caption).foregroundStyle(.secondary)
                    Picker("涨跌幅基准", selection: $changeBasis) {
                        Text("昨结").tag("settlement")
                        Text("今开").tag("open")
                    }.pickerStyle(.segmented)
                    Text("界面主题").font(.caption).foregroundStyle(.secondary)
                    Picker("主题", selection: $appearance) {
                        Text("浅色").tag(AppAppearanceMode.light.rawValue)
                        Text("深色").tag(AppAppearanceMode.dark.rawValue)
                        Text("纯黑").tag(AppAppearanceMode.black.rawValue)
                        Text("纯灰").tag(AppAppearanceMode.gray.rawValue)
                        Text("跟随系统").tag(AppAppearanceMode.system.rawValue)
                    }.pickerStyle(.menu)

                }
                QuoteAppearanceFields()
                CandleAppearanceFields()
                Section("图表与策略") {
                    Button { strategy = true } label: {
                        HStack { Text("策略回测"); Spacer(); Image(systemName: "chevron.right") }
                    }
                    Button("指标管理") { indicators = true }
                    Button("周期排序") { period = true }
                }
                TradeConnectionFields()
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

                }

            }
            .scrollContentBackground(backgroundStyle.isCustom ? .hidden : .automatic)
            .background(backgroundStyle.isCustom ? backgroundStyle.surface : Color.clear)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .onAppear { marketConfigured = !MarketAccessKey.load().isEmpty }
            .onDisappear { marketKey = "" }
            .sheet(isPresented: $strategy) { StrategyCenterView(instruments: instruments, favoriteIDs: favoriteIDs, mainCodes: mainCodes) }
            .sheet(isPresented: $indicators) { IndicatorSettingsView(settings: ChartDisplaySettings.load()) { $0.save() } }
            .sheet(isPresented: $period) {
                PeriodOrderView(order: periods, label: { QihuiPeriods.labels[$0] ?? $0 }) { updated in
                    storedPeriodOrder = updated.joined(separator: ",")
                    hiddenPeriods = QihuiPeriods.all.filter { !updated.contains($0) }.joined(separator: ",")
                }
            }
        }.tint(MarketPalette.accent)
    }
}
