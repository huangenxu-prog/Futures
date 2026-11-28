import SwiftUI
import UIKit

struct QihuiSettingsView: View {
    var backgroundStyle = MarketBackgroundStyle()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.qihuiInPageStack) private var inPageStack
    @AppStorage("qihui.appearance.mode.v1") private var appearance = AppAppearanceMode.dark.rawValue
    @AppStorage("qihui.change.basis.v1") private var changeBasis = "settlement"
    let instruments: [FuturesInstrument]
    let favoriteIDs: [String]
    let mainCodes: [String:String]
    private enum SettingsGroup: String { case general, quote, candle, chart, trade, server }
    @State private var expandedGroup: SettingsGroup?
    @State private var captureRunning = DevicePerformanceCapture.shared.running
    @State private var reportCopied = false
    @State private var marketConfigured = false
    @State private var marketKey = ""
    @State private var marketKeyError = false
    @State private var strategy = false
    @State private var indicators = false
    @State private var period = false
    @AppStorage("qihui.chart.period-order.v1") private var storedPeriodOrder = ""
    @AppStorage("qihui.chart.period-hidden.v1") private var hiddenPeriods = "3分,10分,120分"
    private var periods: [String] { QihuiPeriods.visible(storedPeriodOrder, hidden: hiddenPeriods) }
    private func groupHeader(_ group: SettingsGroup, _ title: String, icon: String) -> some View {
        Section {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedGroup = expandedGroup == group ? nil : group
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: icon).frame(width: 24).foregroundStyle(MarketPalette.accent)
                    Text(title).foregroundStyle(MarketPalette.ink)
                    Spacer()
                    Image(systemName: expandedGroup == group ? "chevron.down" : "chevron.right")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(MarketPalette.muted)
                }
                .frame(minHeight: 35)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expandedGroup == group ? "已展开" : "已收起")
        }
    }

    var body: some View {
        QihuiPageStack {
            Form {
                Section("临时性能诊断") {
                    Button(captureRunning ? "停止采样" : "开始采样") {
                        if captureRunning { DevicePerformanceCapture.shared.stop() }
                        else { DevicePerformanceCapture.shared.start(); reportCopied = false }
                        captureRunning = DevicePerformanceCapture.shared.running
                    }
                    Button("复制诊断报告") {
                        UIPasteboard.general.string = DevicePerformanceCapture.shared.report()
                        reportCopied = true
                    }.disabled(captureRunning)
                    if reportCopied { Text("已复制报告").font(.caption) }
                    Text("仅诊断版使用。开始后正常使用，结束时返回这里停止并复制。数据保存在内存，不上传。").font(.caption).foregroundStyle(.secondary)
                }
                groupHeader(.general, "常规设置", icon: "gearshape")
                if expandedGroup == .general {
                Section {
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
                }
                groupHeader(.quote, "行情配色", icon: "paintpalette")
                if expandedGroup == .quote { QuoteAppearanceFields() }
                groupHeader(.candle, "K线样式", icon: "chart.bar.xaxis")
                if expandedGroup == .candle { CandleAppearanceFields() }
                groupHeader(.chart, "图表与策略", icon: "chart.xyaxis.line")
                if expandedGroup == .chart {
                Section {
                    Button { strategy = true } label: {
                        HStack { Text("策略回测"); Spacer(); Image(systemName: "chevron.right") }
                    }
                    Button("指标管理") { indicators = true }
                    Button("周期排序") { period = true }
                }
                }
                groupHeader(.trade, "交易连接", icon: "wallet.bifold")
                if expandedGroup == .trade { TradeConnectionFields() }
                groupHeader(.server, "服务器配置", icon: "server.rack")
                if expandedGroup == .server {
                Section {
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
            }
            .scrollContentBackground(backgroundStyle.isCustom ? .hidden : .automatic)
            .background(backgroundStyle.isCustom ? backgroundStyle.surface : Color.clear)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !inPageStack { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            }
            .onAppear { marketConfigured = !MarketAccessKey.load().isEmpty }
            .onDisappear { marketKey = "" }
            .navigationDestination(isPresented: $strategy) { StrategyCenterView(instruments: instruments, favoriteIDs: favoriteIDs, mainCodes: mainCodes) }
            .navigationDestination(isPresented: $indicators) { IndicatorSettingsView(settings: ChartDisplaySettings.load()) { $0.save() } }
            .navigationDestination(isPresented: $period) {
                PeriodOrderView(order: periods, label: { QihuiPeriods.labels[$0] ?? $0 }) { updated in
                    storedPeriodOrder = updated.joined(separator: ",")
                    hiddenPeriods = QihuiPeriods.all.filter { !updated.contains($0) }.joined(separator: ",")
                }
            }
        }.tint(MarketPalette.accent)
    }
}
