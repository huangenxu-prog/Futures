import SwiftUI

struct FormulaEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: FormulaDefinition
    let onSave: (FormulaDefinition) -> Void
    @State private var result: String?
    @State private var passed = false

    var body: some View {
        NavigationStack {
            Form {
                Section("名称与位置") {
                    TextField("指标名称",text:$draft.name)
                    Picker("绘制位置",selection:$draft.overlay) {
                        Text("主图").tag(true)
                        Text("副图").tag(false)
                    }
                    Toggle("显示指标",isOn:$draft.enabled)
                }
                Section("公式源码") {
                    TextEditor(text:$draft.source)
                        .font(.system(size:13,design:.monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .frame(minHeight:220)
                    Button("检查公式") { check() }
                    if let result {
                        Text(result).font(.caption)
                            .foregroundStyle(passed ? Color.green : Color.red)
                    }
                }
                Section("语法说明") {
                    Text(":= 定义中间变量，: 绘制输出，每行以 ; 分隔。")
                    Text("行情：OPEN HIGH LOW CLOSE VOL（O H L C V），HL2 HLC3 OHLC4；支持自定义价格表达式。")
                    Text("均线：MA EMA SMA WMA EMA2 HMA DEMA TEMA DMA WILDER")
                    Text("其他：HHV LLV SUM STD REF COUNT IF CROSS BARSLAST ABS MAX MIN")
                    Text("EMA2 与 WMA 等价；HMA 半周期、平方根周期向下取整。DMA 支持 0～1 的权重表达式。")
                    Text("嵌套示例：HMA(EMA((3*C+H+L+O)/6,5),20)")
                    Text("样式：COLORRED、COLORGREEN、COLORBLUE、COLORYELLOW、COLORWHITE、COLORCYAN、COLORMAGENTA、LINETHICK1～5、COLORSTICK。")
                    Text("仅支持公式子集；EMA/SMA 从首个有效值递推，MA 等窗口函数需足够历史。缺失值不补零，不支持未来引用或任意代码。")
                }
                .font(.caption)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("公式指标")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement:.confirmationAction) {
                    Button("保存") {
                        guard check() else { return }
                        draft.name = draft.name.trimmingCharacters(in:.whitespacesAndNewlines)
                        // Raw edits must never leave stale visual composition metadata.
                        if let composition = draft.composition,
                           (try? composition.source()) != draft.source {
                            draft.composition = nil
                        }
                        onSave(draft); dismiss()
                    }
                }
            }
            .onChange(of:draft.source) { _,_ in result = nil }
            .onChange(of:draft.name) { _,_ in result = nil }
        }
    }

    @discardableResult private func check() -> Bool {
        do {
            let name = draft.name.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 24 else { throw FormulaFailure("指标名称长度需为1～24字") }
            _ = try FormulaProgram(draft.source)
            passed = true; result = "公式检查通过。"
            return true
        } catch {
            passed = false; result = error.localizedDescription
            return false
        }
    }
}
