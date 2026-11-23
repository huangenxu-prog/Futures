import SwiftUI

/// Edit visibility and period independently for every moving average.
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
                    averageRow("SMA", kind: .sma, value: $draft.sma)
                    averageRow("EMA 1", kind: .emaFast, value: $draft.emaFast)
                    averageRow("EMA 2", kind: .emaSlow, value: $draft.emaSlow)
                    averageRow("WMA", kind: .wma, value: $draft.wma)
                } header: {
                    Text("基础均线")
                } footer: {
                    Text("开关控制是否显示，右侧填写周期。例如 EMA 1 设 20、EMA 2 设 50，可同时显示 EMA20 和 EMA50。")
                }

                Section {
                    ForEach($draft.additionalAverages) { $average in
                        HStack(spacing: 10) {
                            Toggle("启用", isOn: $average.enabled)
                                .labelsHidden()
                                .accessibilityLabel("显示 \(average.type.rawValue)\(average.period)")
                            Picker("类型", selection: $average.type) {
                                ForEach(MovingAverageType.allCases) { type in
                                    Text(type.rawValue).tag(type)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 88)
                            TextField("周期", value: $average.period, format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 58)
                                .accessibilityLabel("均线周期")
                            Button {
                                let id = average.id
                                draft.additionalAverages.removeAll { $0.id == id }
                            } label: {
                                Image(systemName: "minus.circle")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("删除均线")
                        }
                    }
                    Button {
                        draft.addAverage()
                    } label: {
                        Label("新增均线", systemImage: "plus.circle")
                    }
                } header: {
                    Text("自定义均线")
                } footer: {
                    Text("可以添加多条 SMA、EMA、WMA，分别设置周期、显示状态和删除；同一类型、同一周期不能重复显示。")
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
                    if draft.hasDuplicateAverages {
                        Text("同类型、同周期的均线不能重复启用，请关闭或调整其中一条。")
                            .foregroundStyle(.red)
                    } else if !draft.isValid {
                        Text("周期必须在 2～500，MACD 快线小于慢线，BOLL 倍数为 0.1～10。")
                            .foregroundStyle(.red)
                    } else {
                        Text("保存后立即重新计算指标，设置保存在当前设备上。")
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollContentBackground(.hidden)
            .background(MarketPalette.background.ignoresSafeArea())
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
    }

    private func enabledBinding(_ kind: ChartIndicatorKind) -> Binding<Bool> {
        Binding(
            get: { draft.enabled.contains(kind) },
            set: { isEnabled in
                if isEnabled { draft.enabled.insert(kind) }
                else { draft.enabled.remove(kind) }
            }
        )
    }

    private func averageRow(_ label: String, kind: ChartIndicatorKind, value: Binding<Int>) -> some View {
        HStack {
            Toggle(label, isOn: enabledBinding(kind))
            TextField("周期", value: value, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
                .accessibilityLabel("\(label) 周期")
        }
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
