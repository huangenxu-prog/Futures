import SwiftUI

/// Edit visibility and period independently for every moving average.
struct IndicatorSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: String?
    @State private var draft: ChartDisplaySettings
    @State private var editingFormula: FormulaDefinition?
    @State private var composingFormula: FormulaDefinition?
    let previewBars: [FormulaBar]
    let onSave: (ChartDisplaySettings) -> Void

    init(settings: ChartDisplaySettings, previewBars: [FormulaBar] = [],
         onSave: @escaping (ChartDisplaySettings) -> Void) {
        _draft = State(initialValue: settings)
        self.previewBars = previewBars
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    averageRow("MA", kind: .sma, value: $draft.sma)
                    averageRow("EMA 1", kind: .emaFast, value: $draft.emaFast)
                    averageRow("EMA 2", kind: .emaSlow, value: $draft.emaSlow)
                    averageRow("WMA", kind: .wma, value: $draft.wma)
                } header: {
                    Text("基础均线")
                } footer: {
                    Text("原 SMA 简单均线现标为 MA，计算及设置不变。EMA 1/2 是两个普通 EMA 槽位，与函数 EMA2 不同。")
                }

                Section {
                    ForEach($draft.additionalAverages) { $average in
                        VStack(alignment:.leading,spacing:8) {
                            HStack(spacing:8) {
                                Toggle("启用", isOn: $average.enabled)
                                    .labelsHidden()
                                    .accessibilityLabel("显示 \(average.label)")
                                Spacer(minLength:0)
                                Picker("类型", selection: $average.type) {
                                    ForEach(MovingAverageType.allCases) { type in
                                        Text(type.title).tag(type)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .fixedSize(horizontal:true,vertical:false)
                                if average.type == .dma {
                                    TextField("权重",value:$average.dynamicAlpha,format:.number)
    .focused($focusedField,equals:"alpha-\(average.id)")
                                        .keyboardType(.decimalPad)
                                        .multilineTextAlignment(.trailing)
                                        .frame(width:64)
                                        .accessibilityLabel("DMA 权重")
                                } else {
                                    TextField("周期", value: $average.period, format: .number)
    .focused($focusedField,equals:"period-\(average.id)")
                                        .keyboardType(.numberPad)
                                        .multilineTextAlignment(.trailing)
                                        .frame(width:52)
                                        .accessibilityLabel("均线周期")
                                }
                                Button {
                                    dismissInput()
                                    let id = average.id
                                    draft.additionalAverages.removeAll { $0.id == id }
                                } label: {
                                    Image(systemName:"minus.circle").foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("删除均线")
                            }
                            if average.type == .smoothSMA {
                                HStack {
                                    Text("平滑权重 M").font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    TextField("M",value:$average.smoothingWeight,format:.number)
    .focused($focusedField,equals:"weight-\(average.id)")
                                        .keyboardType(.numberPad)
                                        .multilineTextAlignment(.trailing)
                                        .frame(width:58)
                                }
                            } else if average.type == .dma {
                                Text("固定权重 0～1；动态权重表达式请用组合指标。")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button {
                        dismissInput()
                        draft.addAverage()
                    } label: {
                        Label("新增均线", systemImage: "plus.circle")
                    }
                } header: {
                    Text("自定义均线")
                } footer: {
                    Text("可添加全部10种均线。MA 是简单均线，SMA 另需平滑权重 M；DMA 使用固定权重，EMA2 与 WMA 等价。相同算法与参数不能重复启用。")
                }

                Section("布林带 BOLL") {
                    Toggle("显示 BOLL", isOn: enabledBinding(.boll))
                    parameter("计算周期", value: $draft.bollPeriod, id:"bollPeriod")
                    HStack {
                        Text("标准差倍数")
                        Spacer()
                        TextField("倍数", value: $draft.bollMultiplier, format: .number)
    .focused($focusedField,equals:"boll-multiplier")
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                    }
                }
                Section("MACD") {
                    Toggle("显示 MACD", isOn: enabledBinding(.macd))
                    parameter("快线周期", value: $draft.macdFast, id:"macdFast")
                    parameter("慢线周期", value: $draft.macdSlow, id:"macdSlow")
                    parameter("信号周期", value: $draft.macdSignal, id:"macdSignal")
                }
                Section("KDJ") {
                    Toggle("显示 KDJ", isOn: enabledBinding(.kdj))
                    parameter("RSV 周期", value: $draft.kdjPeriod, id:"kdjPeriod")
                    parameter("K 平滑周期", value: $draft.kdjK, id:"kdjK")
                    parameter("D 平滑周期", value: $draft.kdjD, id:"kdjD")
                }
                Section("ATR") {
                    Toggle("显示 ATR", isOn: enabledBinding(.atr))
                    parameter("计算周期", value: $draft.atrPeriod, id:"atrPeriod")
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
                    parameter("成交量均线", value: $draft.volumeMA, id:"volumeMA")
                    Toggle("显示 RSI", isOn: enabledBinding(.rsi))
                    parameter("RSI 周期", value: $draft.rsi, id:"rsi")
                }
                Section("结构指标（试验）") {
                    Toggle("缠论分型、笔与重叠区", isOn: enabledBinding(.chan))
                    Toggle("猎杀结构与提示", isOn: enabledBinding(.hunt))
                    Text("缠论只显示结构线及重叠区，不显示顶底文字。猎杀显示结构、趋势及猎杀/等/确认状态；图上为本周期研究提示，并非完整多周期交易资格。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("自定义公式指标") {
                    ForEach($draft.formulas) { $formula in
                        HStack {
                            Toggle(formula.name, isOn: $formula.enabled)
                            Menu {
                                if formula.composition != nil {
                                    Button("编辑组合",systemImage:"slider.horizontal.3") { dismissInput(); composingFormula = formula }
                                }
                                Button("编辑公式",systemImage:"pencil") { dismissInput(); editingFormula = formula }
                            } label: {
                                Image(systemName:"pencil")
                            }
                            .accessibilityLabel("编辑指标")
                        }
                    }
                    .onDelete { dismissInput(); draft.formulas.remove(atOffsets: $0) }
                    Button {
                        dismissInput()
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
                        dismissInput()
                        editingFormula = FormulaDefinition()
                    } label: {
                        Label("新建公式指标", systemImage: "plus.circle")
                    }
                    .disabled(draft.formulas.count >= 12)
                }
                Section {
                    Button("恢复默认参数") {
                        dismissInput()
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
                        Text("周期2～500，SMA 权重1～N，DMA 权重0～1；MACD 快线小于慢线，BOLL 倍数0.1～10，SAR 加速因子大于0且不超过最大值，最大值不超过1。")
                            .foregroundStyle(.red)
                    } else {
                        Text("保存后立即重新计算指标，设置保存在当前设备上。")
                    }
                }
            }
            .scrollDismissesKeyboard(.immediately)
            .onSubmit { dismissInput() }
            .scrollContentBackground(.hidden)
            .background(MarketPalette.background.ignoresSafeArea())
            .navigationTitle("指标参数")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement:.keyboard) {
                    Spacer()
                    Button("完成") { dismissInput() }.fontWeight(.semibold)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismissInput(); dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        dismissInput()
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
            FormulaComposerView(draft:formula,previewBars:previewBars) { updated in
                if let i = draft.formulas.firstIndex(where:{$0.id == updated.id}) {
                    draft.formulas[i] = updated
                } else if draft.formulas.count < 12 {
                    draft.formulas.append(updated)
                }
            }
        }
        .tint(MarketPalette.accent)
    }

    private func dismissInput() {
        focusedField = nil
        IndicatorKeyboard.dismiss()
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
                .focused($focusedField,equals:"average-\(kind.rawValue)")
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
    .focused($focusedField,equals:"decimal-\(label)")
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
        }
    }

    private func parameter(_ label: String, value: Binding<Int>, id: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("周期", value: value, format: .number)
                .focused($focusedField,equals:id)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
        }
    }
}
