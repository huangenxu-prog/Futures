import SwiftUI
import TradingChart

struct IndicatorSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.qihuiInPageStack) private var inPageStack
    @FocusState private var focusedField: String?
    @State private var draft: ChartDisplaySettings
    @State private var main = true
    private var backgroundStyle = MarketBackgroundStyle()
    @State private var editingFormula: FormulaDefinition?
    @State private var composingFormula: FormulaDefinition?
    @State private var builtIn: ChartIndicatorKind?
    let previewBars: [FormulaBar]
    let onSave: (ChartDisplaySettings) -> Void
    init(settings: ChartDisplaySettings, previewBars: [FormulaBar] = [], onSave: @escaping (ChartDisplaySettings) -> Void) {
        _draft = State(initialValue:settings)
        self.previewBars = previewBars
        self.onSave = onSave
    }
    var body: some View {
        QihuiPageStack {
            VStack(spacing:12) {
                HStack(spacing:4) {
                    tab("主图指标",true)
                    tab("副图指标",false)
                }.padding(4).background(Color.primary.opacity(0.05),in:RoundedRectangle(cornerRadius:12))
                ScrollView {
                    VStack(alignment:.leading,spacing:16) {
                        Text("内置指标").font(.subheadline.weight(.semibold)).foregroundStyle(MarketPalette.muted)
                        VStack(spacing:0) {
                            ForEach(main ? [ChartIndicatorKind.sma,.emaFast,.wma,.boll,.sar] : [.macd,.rsi,.kdj,.atr,.volume,.opi,.intraday]) { kind in
                                builtinRow(kind)
                                if kind != (main ? .sar : .intraday) { Divider().padding(.leading,46) }
                            }
                            if main {
                                ForEach(MovingAverageType.allCases.filter { type in ![.sma,.ema,.wma].contains(type) && draft.additionalAverages.contains(where: { a in a.type == type }) }) { type in
                                    Divider()
                                    Button { builtIn = .sma } label: {
                                        HStack { Text(type.title); Spacer(); Text("扩展均线").font(.caption).foregroundStyle(MarketPalette.muted); Image(systemName:"chevron.right") }
                                    }.buttonStyle(.plain).padding(12)
                                }
                            }
                        }.background(backgroundStyle.surface,in:RoundedRectangle(cornerRadius:12))
                        Text("自定义指标").font(.subheadline.weight(.semibold)).foregroundStyle(MarketPalette.muted)
                        VStack(spacing:0) {
                            let formulas = draft.formulas.filter { $0.overlay == main }
                            if formulas.isEmpty {
                                Text("暂无自定义指标").font(.subheadline).foregroundStyle(MarketPalette.muted).frame(maxWidth:.infinity).padding(24)
                            }
                            ForEach(formulas) { formula in
                                formulaRow(formula)
                                if formula.id != formulas.last?.id { Divider().padding(.leading,46) }
                            }
                        }.background(backgroundStyle.surface,in:RoundedRectangle(cornerRadius:12))
                        if !draft.isValid {
                            Text(draft.hasDuplicateAverages ? "均线周期重复，请调整。" : "请检查指标参数范围。").font(.caption).foregroundStyle(.red)
                        }
                    }.padding(.vertical,6)
                }
                HStack(spacing:10) {
                    Button {
                        var formula = FormulaDefinition(); formula.name = "组合指标"; formula.overlay = main; formula.composition = FormulaComposition()
                        composingFormula = formula
                    } label: {
                        Label("新建组合",systemImage:"plus").frame(maxWidth:.infinity).padding(.vertical,13)
                            .overlay(RoundedRectangle(cornerRadius:10).stroke(MarketPalette.accent,lineWidth:1))
                    }
                    Button {
                        var formula = FormulaDefinition(); formula.overlay = main; editingFormula = formula
                    } label: {
                        Label("新建公式",systemImage:"plus").foregroundStyle(.white).frame(maxWidth:.infinity).padding(.vertical,13)
                            .background(MarketPalette.accent,in:RoundedRectangle(cornerRadius:10))
                    }
                }.buttonStyle(.plain).foregroundStyle(MarketPalette.accent).disabled(draft.formulas.count >= 12)
            }.padding(16)
            .background(backgroundStyle.raised.ignoresSafeArea())
            .navigationTitle("指标管理").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !inPageStack { ToolbarItem(placement:.cancellationAction) { Button("取消") { dismiss() } } }
                ToolbarItem(placement:.confirmationAction) { Button("保存") { if draft.isValid { onSave(draft); dismiss() } }.disabled(!draft.isValid) }
            }
            .navigationDestination(isPresented:Binding(get:{ builtIn != nil },set:{ if !$0 { builtIn = nil } })) {
                if let kind = builtIn { BuiltInIndicatorEditor(settings:$draft,kind:kind,bars:previewBars) }
            }
            .navigationDestination(isPresented:Binding(get:{ editingFormula != nil },set:{ if !$0 { editingFormula = nil } })) {
                if let formula = editingFormula { FormulaEditorView(draft:formula,onSave:saveFormula,previewBars:previewBars).environment(\.qihuiInPageStack,true) }
            }
            .navigationDestination(isPresented:Binding(get:{ composingFormula != nil },set:{ if !$0 { composingFormula = nil } })) {
                if let formula = composingFormula { FormulaComposerView(draft:formula,previewBars:previewBars,onSave:saveFormula).environment(\.qihuiInPageStack,true) }
            }
        }.tint(MarketPalette.accent)
    }
    private func tab(_ title:String,_ value:Bool) -> some View {
        Button { main = value } label: {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(main == value ? Color.white : MarketPalette.muted)
                .frame(maxWidth:.infinity).padding(.vertical,11)
                .background(main == value ? MarketPalette.accent : Color.clear,in:RoundedRectangle(cornerRadius:9))
        }.buttonStyle(.plain)
    }
    private func group(_ kind:ChartIndicatorKind) -> [ChartIndicatorKind] { kind == .emaFast ? [.emaFast,.emaSlow] : [kind] }
    private func type(_ kind:ChartIndicatorKind) -> MovingAverageType? {
        switch kind { case .sma:return .sma; case .emaFast:return .ema; case .wma:return .wma; default:return nil }
    }
    private func groupEnabled(_ kind:ChartIndicatorKind) -> Binding<Bool> {
        Binding(get:{
            group(kind).contains { draft.enabled.contains($0) } || (type(kind).map { t in draft.additionalAverages.contains { $0.type == t && $0.enabled } } ?? false)
        },set:{ value in
            for k in group(kind) { if value { draft.enabled.insert(k) } else { draft.enabled.remove(k) } }
            if let t = type(kind) { for i in draft.additionalAverages.indices where draft.additionalAverages[i].type == t { draft.additionalAverages[i].enabled = value } }
        })
    }
    private func builtinRow(_ kind:ChartIndicatorKind) -> some View {
        let name = kind == .sma ? "MA" : kind == .emaFast ? "EMA" : kind.title
        let detail: String = [.sma:"均线",.emaFast:"指数均线",.wma:"加权均线",.boll:"布林带",.sar:"抛物线",.volume:"成交量",.opi:"持仓量"][kind] ?? ""
        return HStack(spacing:10) {
            Image(systemName:kind == .sar ? "chart.dots.scatter" : "chart.xyaxis.line").foregroundStyle(MarketPalette.accent).frame(width:28)
            Button { builtIn = kind } label: {
                HStack { Text(name).font(.subheadline.weight(.semibold)); Text(detail).font(.caption).foregroundStyle(MarketPalette.muted); Spacer(minLength:0) }
                    .foregroundStyle(.primary).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Toggle("启用 "+name,isOn:groupEnabled(kind)).labelsHidden().scaleEffect(0.82).fixedSize()
            Button { builtIn = kind } label: { Image(systemName:"chevron.right").font(.caption.weight(.semibold)).foregroundStyle(MarketPalette.muted) }.buttonStyle(.plain)
        }.padding(.horizontal,12).padding(.vertical,9)
    }
    private func formulaRow(_ formula:FormulaDefinition) -> some View {
        HStack(spacing:10) {
            Image(systemName:formula.composition == nil ? "chevron.left.forwardslash.chevron.right" : "square.3.layers.3d")
                .foregroundStyle(formula.composition == nil ? MarketPalette.accent : Color.purple).frame(width:28)
            Button { if formula.composition != nil { composingFormula = formula } else { editingFormula = formula } } label: {
                HStack { Text(formula.name).font(.subheadline.weight(.semibold)); Spacer(minLength:0); Text(formula.composition == nil ? "公式指标" : "组合指标").font(.caption).foregroundStyle(MarketPalette.muted) }
                    .foregroundStyle(.primary)
            }.buttonStyle(.plain)
            Toggle("启用",isOn:formulaEnabledBinding(formula)).labelsHidden().scaleEffect(0.82).fixedSize()
            Menu {
                Button("编辑",systemImage:"pencil") { if formula.composition != nil { composingFormula = formula } else { editingFormula = formula } }
                Button("上移",systemImage:"arrow.up") { moveFormula(formula.id,by:-1) }
                Button("下移",systemImage:"arrow.down") { moveFormula(formula.id,by:1) }
                Button("删除",systemImage:"trash",role:.destructive) { draft.formulas.removeAll { $0.id == formula.id } }
            } label: { Image(systemName:"chevron.right").font(.caption.weight(.semibold)).foregroundStyle(MarketPalette.muted) }
        }.padding(.horizontal,12).padding(.vertical,9)
    }
    private func saveFormula(_ formula:FormulaDefinition) {
        if let i = draft.formulas.firstIndex(where:{$0.id == formula.id}) { draft.formulas[i] = formula }
        else if draft.formulas.count < 12 { draft.formulas.append(formula) }
    }
    private func moveFormula(_ id:UUID,by delta:Int) {
        let visible = draft.formulas.indices.filter { draft.formulas[$0].overlay == main }
        guard let i = visible.firstIndex(where:{draft.formulas[$0].id == id}), visible.indices.contains(i+delta) else { return }
        draft.formulas.swapAt(visible[i],visible[i+delta])
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
