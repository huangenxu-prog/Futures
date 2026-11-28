import SwiftUI
import TradingChart

/// Edit visibility and period independently for every moving average.
struct IndicatorSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.qihuiInPageStack) private var inPageStack
    @FocusState private var focusedField: String?
    @State private var draft: ChartDisplaySettings
    @State private var customTab = false
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
        QihuiPageStack {
            VStack(spacing:8) {
                HStack(spacing:6) {
                    indicatorTab("内置指标",custom:false)
                    indicatorTab("自定义指标",custom:true)
                }.padding(.horizontal,16)
                if customTab { customWorkspace } else {
            Form {
                Section {
                    averageRow("MA", kind: .sma, value: $draft.sma)
                    averageRow("EMA 1", kind: .emaFast, value: $draft.emaFast)
                    averageRow("EMA 2", kind: .emaSlow, value: $draft.emaSlow)
                    averageRow("WMA", kind: .wma, value: $draft.wma)

                    ForEach(draft.additionalAverages) { average in
                        VStack(alignment:.leading,spacing:8) {
                            HStack(spacing:8) {
                                Toggle("启用", isOn: averageBinding(average, \.enabled))
                                    .labelsHidden()
                                    .accessibilityLabel("显示 \(average.label)")
                                Spacer(minLength:0)
                                Picker("类型", selection: averageBinding(average, \.type)) {
                                    ForEach(MovingAverageType.allCases) { type in
                                        Text(type.title).tag(type)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .fixedSize(horizontal:true,vertical:false)
                                if average.type == .dma {
                                    TextField("权重",value:averageBinding(average, \.dynamicAlpha),format:.number)
    .focused($focusedField,equals:"alpha-\(average.id)")
                                        .keyboardType(.decimalPad)
                                        .multilineTextAlignment(.trailing)
                                        .frame(width:64)
                                        .accessibilityLabel("DMA 权重")
                                } else {
                                    TextField("周期", value: averageBinding(average, \.period), format: .number)
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
                                    draft.averageColors.removeValue(forKey: id.uuidString)
                                    draft.averageWidths.removeValue(forKey: id.uuidString)
                                } label: {
                                    Image(systemName:"minus.circle").foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("删除均线")
                            }
                            styleRow(key: average.id.uuidString, type: average.type, period: average.type == .dma ? 20 : average.period)
                            if average.type == .smoothSMA {
                                HStack {
                                    Text("平滑权重 M").font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    TextField("M",value:averageBinding(average, \.smoothingWeight),format:.number)
    .focused($focusedField,equals:"weight-\(average.id)")
                                        .keyboardType(.numberPad)
                                        .multilineTextAlignment(.trailing)
                                        .frame(width:58)
                                }
                            }
                        }
                    }
                    Button {
                        dismissInput()
                        draft.addAverage()
                    } label: {
                        Label("新增均线", systemImage: "plus.circle")
                    }
                    DisclosureGroup("BOLL") {
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
                DisclosureGroup("SAR") {
                    Toggle("显示 SAR", isOn: enabledBinding(.sar))
                    decimalParameter("加速因子", value: $draft.sarStep)
                    decimalParameter("最大加速因子", value: $draft.sarMaximum)
                }
                } header: { Text("主图指标") }
                Section("副图指标") {
                DisclosureGroup("MACD") {
                    Toggle("显示 MACD", isOn: enabledBinding(.macd))
                    parameter("快线周期", value: $draft.macdFast, id:"macdFast")
                    parameter("慢线周期", value: $draft.macdSlow, id:"macdSlow")
                    parameter("信号周期", value: $draft.macdSignal, id:"macdSignal")
                }
                DisclosureGroup("KDJ") {
                    Toggle("显示 KDJ", isOn: enabledBinding(.kdj))
                    parameter("RSV 周期", value: $draft.kdjPeriod, id:"kdjPeriod")
                    parameter("K 平滑周期", value: $draft.kdjK, id:"kdjK")
                    parameter("D 平滑周期", value: $draft.kdjD, id:"kdjD")
                }
                DisclosureGroup("ATR") {
                    Toggle("显示 ATR", isOn: enabledBinding(.atr))
                    parameter("计算周期", value: $draft.atrPeriod, id:"atrPeriod")
                }
                DisclosureGroup("其他副图与分时") {
                    Toggle("显示分时",isOn:enabledBinding(.intraday))
                    Toggle("显示 OPI 持仓量", isOn: enabledBinding(.opi))
                    Toggle("显示 VOL", isOn: enabledBinding(.volume))
                    parameter("成交量均线", value: $draft.volumeMA, id:"volumeMA")
                    Toggle("显示 RSI", isOn: enabledBinding(.rsi))
                    parameter("RSI 周期", value: $draft.rsi, id:"rsi")
                }
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
            .scrollContentBackground(.hidden)
                }
            }
            .scrollDismissesKeyboard(.immediately)
            .onSubmit { dismissInput() }
            .scrollContentBackground(.hidden)
            .background(MarketPalette.background.ignoresSafeArea())
            .navigationTitle("指标管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement:.keyboard) {
                    Spacer()
                    Button("完成") { dismissInput() }.fontWeight(.semibold)
                }
                if !inPageStack {
                    ToolbarItem(placement: .topBarLeading) { Button("取消") { dismissInput(); dismiss() } }
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
        .navigationDestination(isPresented: Binding(get:{ editingFormula != nil },set:{ if !$0 { editingFormula = nil } })) {
            if let formula = editingFormula {
            FormulaEditorView(draft: formula) { updated in
                if let i = draft.formulas.firstIndex(where: { $0.id == updated.id }) {
                    draft.formulas[i] = updated
                } else if draft.formulas.count < 12 {
                    draft.formulas.append(updated)
                }
            }
        }
        }
        .navigationDestination(isPresented: Binding(get:{ composingFormula != nil },set:{ if !$0 { composingFormula = nil } })) {
            if let formula = composingFormula {
            FormulaComposerView(draft:formula,previewBars:previewBars) { updated in
                if let i = draft.formulas.firstIndex(where:{$0.id == updated.id}) {
                    draft.formulas[i] = updated
                } else if draft.formulas.count < 12 {
                    draft.formulas.append(updated)
                }
            }
        }
        }
        }
        .tint(MarketPalette.accent)
    }

    private func indicatorTab(_ title:String,custom:Bool) -> some View {
        Button {
            dismissInput(); customTab = custom
        } label: {
            Text(title).font(.subheadline.weight(.semibold))
                .foregroundStyle(customTab == custom ? Color.white : MarketPalette.muted)
                .frame(maxWidth:.infinity).padding(.vertical,11)
                .background(customTab == custom ? MarketPalette.accent : Color.clear,in:RoundedRectangle(cornerRadius:8))
        }.buttonStyle(.plain)
    }

    private var customWorkspace: some View {
        VStack(spacing:12) {
            ScrollView {
                LazyVStack(spacing:8) {
                    if draft.formulas.isEmpty {
                        Text("尚无自定义指标").foregroundStyle(MarketPalette.muted).padding(32)
                    }
                    ForEach(draft.formulas) { formula in
                        HStack(spacing:10) {
                            Image(systemName:formula.composition == nil ? "function" : "waveform.path")
                                .foregroundStyle(MarketPalette.accent).frame(width:28)
                            Button {
                                dismissInput()
                                if formula.composition != nil { composingFormula = formula }
                                else { editingFormula = formula }
                            } label: {
                                VStack(alignment:.leading,spacing:4) {
                                    Text(formula.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                    Text((formula.overlay ? "主图" : "副图") + (formula.composition == nil ? " · 公式" : " · 组合"))
                                        .font(.caption).foregroundStyle(MarketPalette.muted)
                                }.frame(maxWidth:.infinity,alignment:.leading)
                            }.buttonStyle(.plain)
                            Button {
                                let binding = formulaEnabledBinding(formula)
                                binding.wrappedValue.toggle()
                            } label: {
                                Image(systemName:formula.enabled ? "checkmark.circle.fill" : "circle")
                                    .font(.title3).foregroundStyle(formula.enabled ? MarketPalette.accent : MarketPalette.muted)
                            }.buttonStyle(.plain).accessibilityLabel(formula.enabled ? "关闭指标" : "启用指标")
                            Menu {
                                Button("编辑公式",systemImage:"pencil") { editingFormula = formula }
                                if formula.composition != nil {
                                    Button("编辑组合",systemImage:"slider.horizontal.3") { composingFormula = formula }
                                }
                                Button("上移",systemImage:"arrow.up") { moveFormula(formula.id,by:-1) }
                                Button("下移",systemImage:"arrow.down") { moveFormula(formula.id,by:1) }
                                Button("删除",systemImage:"trash",role:.destructive) { draft.formulas.removeAll { $0.id == formula.id } }
                            } label: {
                                Image(systemName:"ellipsis").frame(width:28,height:36).foregroundStyle(MarketPalette.muted)
                            }
                        }.padding(12).background(Color.primary.opacity(0.055),in:RoundedRectangle(cornerRadius:10))
                    }
                }.padding(.horizontal,16).padding(.top,6)
            }
            HStack(spacing:10) {
                Button {
                    var formula = FormulaDefinition()
                    formula.name = "组合指标"; formula.enabled = true; formula.composition = FormulaComposition()
                    composingFormula = formula
                } label: {
                    Label("新建组合",systemImage:"plus").frame(maxWidth:.infinity).padding(.vertical,12)
                        .background(Color.primary.opacity(0.07),in:RoundedRectangle(cornerRadius:10))
                }
                Button { editingFormula = FormulaDefinition() } label: {
                    Label("新建公式",systemImage:"plus").foregroundStyle(.white).frame(maxWidth:.infinity).padding(.vertical,12)
                        .background(MarketPalette.accent,in:RoundedRectangle(cornerRadius:10))
                }
            }.buttonStyle(.plain).disabled(draft.formulas.count >= 12).padding(.horizontal,16).padding(.bottom,12)
        }
    }

    private func moveFormula(_ id:UUID,by delta:Int) {
        guard let index = draft.formulas.firstIndex(where: { $0.id == id }),
              draft.formulas.indices.contains(index+delta) else { return }
        draft.formulas.swapAt(index,index+delta)
    }

    // Resolve by stable UUID on every access; SwiftUI controls may retain
    // bindings beyond an array mutation or a dismissed row.
    private func averageBinding<T>(_ snapshot: AdditionalMovingAverage, _ key: WritableKeyPath<AdditionalMovingAverage, T>) -> Binding<T> {
        Binding(get: {
            (draft.additionalAverages.first { $0.id == snapshot.id } ?? snapshot)[keyPath: key]
        }, set: { value in
            guard let index = draft.additionalAverages.firstIndex(where: { $0.id == snapshot.id }) else { return }
            draft.additionalAverages[index][keyPath: key] = value
        })
    }
    private func formulaEnabledBinding(_ snapshot: FormulaDefinition) -> Binding<Bool> {
        Binding(get: { draft.formulas.first { $0.id == snapshot.id }?.enabled ?? snapshot.enabled },
                set: { value in
                    guard let index = draft.formulas.firstIndex(where: { $0.id == snapshot.id }) else { return }
                    draft.formulas[index].enabled = value
                })
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
        let type: MovingAverageType = kind == .sma ? .sma : kind == .wma ? .wma : .ema
        return HStack(spacing: 8) {
            Text(label).frame(minWidth: 48, alignment: .leading)
            TextField("周期", value: value, format: .number)
                .focused($focusedField,equals:"average-\(kind.rawValue)")
                .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 40)
                .accessibilityLabel("\(label) 周期")
            Spacer(minLength: 0)
            styleRow(key: kind.rawValue, type: type, period: value.wrappedValue)
            Toggle("启用", isOn: enabledBinding(kind)).labelsHidden().accessibilityLabel("显示 \(label)")
        }
    }
    private func styleRow(key: String, type: MovingAverageType, period: Int) -> some View {
        HStack(spacing: 5) {
            ColorPicker("颜色", selection: Binding(get: {
                let fallback = ChartDisplaySettings.averageColor(type: type, period: max(2, min(500, period)))
                let rgb = draft.averageColors[key].flatMap { ChartColor(hex: $0) } ?? fallback
                return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
            }, set: { color in
                if let rgb = CandleAppearance.rgb(color) { draft.averageColors[key] = String(format: "%06X", rgb) }
            }), supportsOpacity: false).labelsHidden()
            Menu {
                ForEach([0.5, 1.0, 1.5, 1.7, 2.0, 2.5, 3.0, 3.5, 4.0], id: \.self) { width in
                    Button(width.formatted()) { draft.averageWidths[key] = width }
                }
            } label: {
                Text((draft.averageWidths[key] ?? 1.7).formatted()).font(.caption).monospacedDigit()
            }.accessibilityLabel("线宽")
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
