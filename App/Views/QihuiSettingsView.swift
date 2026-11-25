import SwiftUI

struct QihuiSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("qihui.appearance.mode.v1") private var appearance = AppAppearanceMode.dark.rawValue
    @AppStorage("qihui.change.basis.v1") private var changeBasis = "settlement"
    let instruments: [FuturesInstrument]
    let favoriteIDs: [String]
    let mainCodes: [String:String]
    @State private var strategy = false
    @State private var account = false
    @State private var indicators = false
    @State private var candle = false
    @State private var period = false
    @AppStorage("qihui.chart.period-order.v1") private var storedPeriodOrder = ""
    private var periods: [String] {
        let defaults = ["1分","5分","15分","30分","60分","日线"]
        var result: [String] = []
        for item in storedPeriodOrder.split(separator: ",").map(String.init) + defaults {
            if defaults.contains(item), !result.contains(item) { result.append(item) }
        }
        return result
    }
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
            .sheet(isPresented: $strategy) { StrategyCenterView(instruments: instruments, favoriteIDs: favoriteIDs, mainCodes: mainCodes) }
            .sheet(isPresented: $account) { TradeConnectionSettingsView() }
            .sheet(isPresented: $indicators) { IndicatorSettingsView(settings: ChartDisplaySettings.load()) { $0.save() } }
            .sheet(isPresented: $candle) { CandleAppearanceView() }
            .sheet(isPresented: $period) {
                PeriodOrderView(order: periods, label: { ["1分":"1m","5分":"5m","15分":"15m","30分":"30m","60分":"1h","日线":"日"][$0] ?? $0 }) { storedPeriodOrder = $0.joined(separator: ",") }
            }
        }.tint(MarketPalette.accent)
    }
}
