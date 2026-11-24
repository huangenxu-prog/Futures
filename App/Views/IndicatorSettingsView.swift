import SwiftUI

/// Edit visibility and period independently for every moving average.
struct IndicatorSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ChartDisplaySettings
    @State private var editingFormula: FormulaDefinition?
    @State private var composingFormula: FormulaDefinition?
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
                    Toggle("显示 BOLL", isOn: enabledBinding(.boll))
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
                    Toggle("显示 MACD", isOn: enabledBinding(.macd))
                    parameter("快线周期", value: $draft.macdFast)
                    parameter("慢线周期", value: $draft.macdSlow)
                    parameter("信号周期", value: $draft.macdSignal)
                }
                Section("KDJ") {
                    Toggle("显示 KDJ", isOn: enabledBinding(.kdj))
                    parameter("RSV 周期", value: $draft.kdjPeriod)
                    parameter("K 平滑周期", value: $draft.kdjK)
                    parameter("D 平滑周期", value: $draft.kdjD)
                }
                Section("ATR") {
                    Toggle("显示 ATR", isOn: enabledBinding(.atr))
                    parameter("计算周期", value: $draft.atrPeriod)
                }
                Section("SAR") {
                    Toggle("显示 SAR", isOn: enabledBinding(.sar))
                    decimalParameter("加速因子", value: $draft.sarStep)
                    decimalParameter("最大加速因子", value: $draft.sarMaximum)
                    Text("SAR 采用主图连线显示，计算使用逐根K线的高低价。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("其他指标") {
                    Toggle("显示 OPI 持仓量", isOn: enabledBinding(.opi))
                    Text("使用每根K线的实际期末持仓量。旧缓存未包含持仓量时不绘制缺失数据。")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("显示 VOL", isOn: enabledBinding(.volume))
                    parameter("成交量均线", value: $draft.volumeMA)
                    Toggle("显示 RSI", isOn: enabledBinding(.rsi))
                    parameter("RSI 周期", value: $draft.rsi)
                }
                Section("自定义公式指标") {
                    ForEach($draft.formulas) { $formula in
                        HStack {
                            Toggle(formula.name, isOn: $formula.enabled)
                            Menu {
                                if formula.composition != nil {
                                    Button("编辑组合",systemImage:"slider.horizontal.3") { composingFormula = formula }
                                }
                                Button("编辑公式",systemImage:"pencil") { editingFormula = formula }
                            } label: {
                                Image(systemName:"pencil")
                            }
                            .accessibilityLabel("编辑指标")
                        }
                    }
                    .onDelete { draft.formulas.remove(atOffsets: $0) }
                    Button {
                        var formula = FormulaDefinition()
                        formula.name = "组合指标"
                        formula.enabled = true
                        formula.composition = FormulaComposition()
                        composingFormula = formula
                    } label: {
                        Label("新建组合指标", systemImage:"plus.circle")
                    }
                    .disabled(draft.formulas.count >= 12)
                    Button {
                        editingFormula = FormulaDefinition()
                    } label: {
                        Label("新建公式指标", systemImage: "plus.circle")
                    }
                    .disabled(draft.formulas.count >= 12)
                }
                Section {
                    Button("恢复默认参数") {
                        let formulas = draft.formulas
                        draft = ChartDisplaySettings()
                        draft.formulas = formulas
                    }
                        .foregroundStyle(MarketPalette.accent)
                } footer: {
                    if draft.hasDuplicateAverages {
                        Text("同类型、同周期的均线不能重复启用，请关闭或调整其中一条。")
                            .foregroundStyle(.red)
                    } else if !draft.isValid {
                        Text("周期 2～500；MACD 快线小于慢线；BOLL 倍数 0.1～10；SAR 加速因子大于0且不超过最大值，最大值不超过1。")
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
        .sheet(item: $editingFormula) { formula in
            FormulaEditorView(draft: formula) { updated in
                if let i = draft.formulas.firstIndex(where: { $0.id == updated.id }) {
                    draft.formulas[i] = updated
                } else if draft.formulas.count < 12 {
                    draft.formulas.append(updated)
                }
            }
        }
        .sheet(item: $composingFormula) { formula in
            FormulaComposerView(draft:formula) { updated in
                if let i = draft.formulas.firstIndex(where:{$0.id == updated.id}) {
                    draft.formulas[i] = updated
                } else if draft.formulas.count < 12 {
                    draft.formulas.append(updated)
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

    private func decimalParameter(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("数值", value: value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
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
