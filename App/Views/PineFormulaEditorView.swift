import SwiftUI

struct PineFormulaEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: PineFormulaDefinition
    let onSave: (PineFormulaDefinition) -> Void
    @State private var checking = false
    @State private var message: String?
    @State private var passed = false

    var body: some View {
        NavigationStack {
            Form {
                Section("名称与位置") {
                    TextField("指标名称", text: $draft.name)
                    Picker("绘制位置", selection: $draft.overlay) {
                        Text("主图").tag(true)
                        Text("副图").tag(false)
                    }
                    Toggle("显示指标", isOn: $draft.enabled)
                }
                Section("TradingView Pine Script") {
                    TextEditor(text: $draft.source)
                        .font(.system(size: 13, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .frame(minHeight: 220)
                    Button("检查公式") { validate(save: false) }
                        .disabled(checking)
                    if checking { ProgressView() }
                    if let message {
                        Text(message).font(.caption)
                            .foregroundStyle(passed ? Color.green : Color.red)
                    }
                }
                Section {
                    Text("实验版：支持本地数值指标线。暂不支持策略、多周期、特殊绘图和动态样式。仅使用可信公式。")
                        .font(.caption)
                }
            }
            .disabled(checking)
            .navigationTitle("TradingView 指标")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { validate(save: true) }.disabled(checking)
                }
            }
        }
    }

    private func validate(save: Bool) {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 24 else {
            passed = false; message = "指标名称长度需为1～24字"; return
        }
        let snapshot = draft
        checking = true; message = nil
        Task { @MainActor in
            defer { checking = false }
            do {
                let bars = (0..<200).map { i -> PineRuntimeBar in
                    let p = 100 + Double(i) * 0.1 + sin(Double(i)) * 2
                    let t = Int64(1704067200000) + Int64(i) * 60000
                    return PineRuntimeBar(open: p, high: p+1, low: p-1, close: p,
                                          volume: 1000, openTime: t, closeTime: t+59999)
                }
                let plots = try await PineRuntime.evaluateBundled(source: snapshot.source, bars: bars)
                guard !plots.isEmpty else { throw PineRuntimeError.failed("未返回可绘制的数值序列") }
                guard snapshot == draft else { return }
                passed = true; message = "样本计算通过，实际行情及绘图仍需验证。"
                if save { draft.name = name; onSave(draft); dismiss() }
            } catch {
                passed = false; message = error.localizedDescription
            }
        }
    }
}
