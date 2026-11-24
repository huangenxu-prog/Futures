import SwiftUI

struct FormulaComposerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: FormulaDefinition
    @State private var composition: FormulaComposition
    @State private var error: String?
    let onSave: (FormulaDefinition) -> Void

    init(draft: FormulaDefinition, onSave: @escaping (FormulaDefinition) -> Void) {
        _draft = State(initialValue: draft)
        _composition = State(initialValue: draft.composition ?? FormulaComposition())
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("指标") {
                    TextField("名称",text:$draft.name)
                    Picker("绘制位置",selection:$draft.overlay) {
                        Text("主图").tag(true)
                        Text("副图").tag(false)
                    }
                    Toggle("显示指标",isOn:$draft.enabled)
                }
                ForEach($composition.lines) { $line in
                    Section {
                        CompositionLineEditor(line:$line)
                        if composition.lines.count > 1 {
                            Button("删除这条输出",role:.destructive) {
                                let id = line.id
                                composition.lines.removeAll { $0.id == id }
                            }
                        }
                    } header: {
                        Text("输出 \(index(for:line.id))")
                    }
                }
                Section {
                    Button {
                        composition.lines.append(CompositionLine())
                    } label: {
                        Label("增加一条输出",systemImage:"plus.circle")
                    }
                    .disabled(composition.lines.count >= 8)
                }
                Section("生成公式") {
                    if let source = try? composition.source() {
                        Text(source)
                            .font(.system(size:12,design:.monospaced))
                            .textSelection(.enabled)
                    } else {
                        Text("请检查各层参数").foregroundStyle(.secondary)
                    }
                    Button("检查公式") { _ = validate() }
                    if let error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("组合指标")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement:.confirmationAction) {
                    Button("保存") {
                        guard let source = validate() else { return }
                        draft.name = draft.name.trimmingCharacters(in:.whitespacesAndNewlines)
                        draft.source = source
                        draft.composition = composition
                        onSave(draft)
                        dismiss()
                    }
                }
            }
            .onChange(of:composition) { _,_ in error = nil }
            .onChange(of:draft.name) { _,_ in error = nil }
        }
        .tint(MarketPalette.accent)
    }

    private func index(for id: UUID) -> Int {
        (composition.lines.firstIndex(where:{$0.id == id}) ?? 0)+1
    }

    private func validate() -> String? {
        do {
            let name = draft.name.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 24 else { throw FormulaFailure("名称长度需为1～24字") }
            let source = try composition.validatedSource()
            error = nil
            return source
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }
}

private struct CompositionLineEditor: View {
    @Binding var line: CompositionLine

    var body: some View {
        Picker("数据源",selection:$line.source) {
            ForEach(CompositionSource.allCases) { source in
                Text(source.title).tag(source)
            }
        }
        if line.source == .custom {
            TextField("价格表达式",text:$line.custom)
                .font(.system(size:13,design:.monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        ForEach($line.layers) { $layer in
            VStack(alignment:.leading,spacing:8) {
                HStack {
                    Text("第 \(index(for:layer.id)) 层")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        let i = index(for:layer.id)-1
                        if i > 0 { line.layers.swapAt(i,i-1) }
                    } label: { Image(systemName:"arrow.up") }
                    .buttonStyle(.borderless)
                    .disabled(index(for:layer.id) <= 1)
                    .accessibilityLabel("上移计算层")
                    Button(role:.destructive) {
                        let id = layer.id
                        line.layers.removeAll {$0.id == id}
                    } label: { Image(systemName:"minus.circle") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("删除计算层")
                }
                Picker("计算函数",selection:$layer.function) {
                    ForEach(CompositionFunction.allCases) { function in
                        Text(function.rawValue).tag(function)
                    }
                }
                if layer.function == .dma {
                    TextField("权重表达式（0～1）",text:$layer.alpha)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else if layer.function != .abs {
                    HStack {
                        Text("周期 N")
                        Spacer()
                        TextField("周期",value:$layer.period,format:.number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width:70)
                    }
                    if layer.function == .sma {
                        HStack {
                            Text("权重 M")
                            Spacer()
                            TextField("权重",value:$layer.weight,format:.number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width:70)
                        }
                    }
                }
            }
            .padding(.vertical,3)
        }
        Button {
            line.layers.append(CompositionLayer(period:5))
        } label: {
            Label("增加计算层",systemImage:"plus.circle")
        }
        .disabled(line.layers.count >= 6)
        Picker("颜色",selection:$line.color) {
            ForEach(CompositionColor.allCases) { color in
                Text(color.title).tag(color)
            }
        }
        Toggle("柱状图",isOn:$line.histogram)
        if !line.histogram {
            Stepper("线宽 \(line.width)",value:$line.width,in:1...5)
        }
    }

    private func index(for id: UUID) -> Int {
        (line.layers.firstIndex(where:{$0.id == id}) ?? 0)+1
    }
}
