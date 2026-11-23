import SwiftUI

/// Edits real chart parameters, not only indicator visibility.
struct IndicatorSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ChartDisplaySettings
    let onSave: (ChartDisplaySettings) -> Void

    init(settings: ChartDisplaySettings, onSave: @escaping (ChartDisplaySettings) -> Void) {
        _draft = State(initialValue: settings)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    parameter("SMA 周期", value: $draft.sma)
                    parameter("EMA 1 周期", value: $draft.emaFast)
                    parameter("EMA 2 周期", value: $draft.emaSlow)
                    parameter("WMA 周期", value: $draft.wma)
                } header: {
                    Text("移动平均线")
                } footer: {
                    Text("周期以 K 线根数计算；例如 EMA30 表示最近 30 根 K 线的指数移动平均。")
                }

                Section("布林带 BOLL") {
                    parameter("计算周期", value: $draft.bollPeriod)
                    HStack {
                        Text("标准差倍数")
                        Spacer()
                        TextField("倍数", value: $draft.bollMultiplier, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                    }
                }
                Section("MACD") {
                    parameter("快线周期", value: $draft.macdFast)
                    parameter("慢线周期", value: $draft.macdSlow)
                    parameter("信号周期", value: $draft.macdSignal)
                }
                Section("其他指标") {
                    parameter("成交量均线", value: $draft.volumeMA)
                    parameter("RSI 周期", value: $draft.rsi)
                }
                Section {
                    Button("恢复默认参数") { draft = ChartDisplaySettings() }
                        .foregroundStyle(MarketPalette.accent)
                } footer: {
                    if !draft.isValid {
                        Text("周期必须在 2～500，MACD 快线应小于慢线，BOLL 倍数应在 0.1～10 之间。")
                            .foregroundStyle(.red)
                    } else {
                        Text("保存后立即重新计算指标，设置保存在当前设备上。")
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("指标参数")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        guard draft.isValid else { return }
                        onSave(draft)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!draft.isValid)
                }
            }
        }
        .tint(MarketPalette.accent)
        .preferredColorScheme(.light)
    }

    private func parameter(_ label: String, value: Binding<Int>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("周期", value: value, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
        }
    }
}
