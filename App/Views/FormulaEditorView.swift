import SwiftUI
import UIKit

struct FormulaEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: String?
    @State var draft: FormulaDefinition
    let onSave: (FormulaDefinition) -> Void
    @State private var result: String?
    @State private var passed = false
    @State private var showHelp = false
    @State private var showColors = false

    var body: some View {
        NavigationStack {
            Form {
                Section("名称与位置") {
                    TextField("指标名称",text:$draft.name)
    .focused($focusedField,equals:"name")
                    Picker("绘制位置",selection:$draft.overlay) {
                        Text("主图").tag(true)
                        Text("副图").tag(false)
                    }
                    Toggle("显示指标",isOn:$draft.enabled)
                }
                Section("公式源码") {
                    ZStack(alignment:.topLeading) {
                        TextEditor(text:$draft.source)
                            .focused($focusedField,equals:"source")
                            .font(.system(size:13,design:.monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight:340)
                        if draft.source.isEmpty {
                            Text("在此输入或粘贴期汇公式")
                                .font(.system(size:13)).foregroundStyle(.secondary)
                                .padding(.top,8).padding(.leading,5)
                                .allowsHitTesting(false)
                        }
                    }
                    HStack {
                        Button("检查公式") { dismissInput(); check() }.buttonStyle(.borderless)
                        Spacer()
                        Button { dismissInput(); showHelp = true } label: { Label("函数",systemImage:"function") }.buttonStyle(.borderless)
                        Button { dismissInput(); showColors = true } label: { Image(systemName:"paintpalette") }.buttonStyle(.borderless).accessibilityLabel("颜色代码")
                    }
                    if let result {
                        Text(result).font(.caption)
                            .foregroundStyle(passed ? Color.green : Color.red)
                    }
                }
                Section("原生语法") {
                    DisclosureGroup("语法说明",isExpanded:$showHelp) {
                    Text(":= 定义中间变量，: 绘制输出，每行以 ; 分隔。变量名支持中文、英文字母、数字和下划线，不能以数字开头。")
                    Text("行情：OPEN HIGH LOW CLOSE VOL（O H L C V），HL2 HLC3 OHLC4；支持自定义价格表达式。")
                    Text("持仓：OPI（期末持仓），OPEN_OI（期初持仓），OI_CHANGE（本根K线持仓变化）。旧历史可能缺少持仓数据。")
                    Text("均线：MA EMA SMA WMA EMA2 HMA DEMA TEMA DMA WILDER")
                    Text("其他：HHV LLV SUM STD REF COUNT IF CROSS BARSLAST ABS MAX MIN")
                    Text("状态：VALUEWHEN、FILTER、HHVBARS、LLVBARS、EXIST、EVERY、NOT、BARSCOUNT；REF 支持非负动态偏移。")
                    Text("HHVBARS/LLVBARS 同值取最近一根；FILTER 保留信号并屏蔽随后N根。")
                    Text("EMA2 与 WMA 等价；HMA 半周期、平方根周期向下取整。DMA 支持 0～1 的权重表达式。")
                    Text("嵌套示例：HMA(EMA((3*C+H+L+O)/6,5),20)")
                    Text("样式：COLORRED、COLORGREEN、COLORBLUE、COLORYELLOW、COLORWHITE、COLORCYAN、COLORMAGENTA、LINETHICK1～5、COLORSTICK。")
                    Text("条件绘图（独立成句）：STICKLINE(条件,起点,终点,宽度,空心),COLORRED;")
                    Text("STICKLINE 宽度0～10，0为细线，空心参数0实心、1空心。")
                    Text("DRAWICON(CROSS(EMA(C,20),EMA(C,50)),L,1),COLORRED;")
                    Text("图标编号1～4依次为↑、↓、●、×；不是其他平台完整图标库。")
                    Text("DRAWTEXT(C>O,H,'上涨'),COLORYELLOW; 文字最多32字。")
                    Text("DRAWLINE(起点条件,起点值,终点条件,终点值,0),COLORBLUE;")
                    Text("DRAWLINE 暂仅支持不延长：最近起点配对第一个后续终点，终点成立才补画历史线段；不代表起点当时已确认。")
                    Text("DRAWNULL 表示缺失值，适用于条件输出。当前未收盘K线的信号可能变化。")
                    Text("仅支持期汇原生公式；EMA/SMA 从首个有效值递推，MA 等窗口函数需足够历史。缺失值不补零，不支持未来引用或任意代码。")
                    Text("DOT 点线；DASHLINE 虚线；NODRAW 仅显示数值；ISUP、ISDOWN、ISEQUAL 判断K线方向。")
                    }
                }
                .font(.caption)
            }
            .scrollContentBackground(.hidden)
            .background(MarketPalette.background.ignoresSafeArea())
            .sheet(isPresented:$showColors) {
                NavigationStack {
                    List([ "FF4545","20C6C8","D77DFF","FFFF00","4C8DFF","FFFFFF" ],id:\.self) { hex in
                        HStack {
                            Text("COLOR"+hex).font(.system(.body,design:.monospaced)).textSelection(.enabled)
                            Spacer()
                            Button("复制") { UIPasteboard.general.string = "COLOR"+hex }.buttonStyle(.borderless)
                        }
                    }
                    .navigationTitle("颜色代码")
                    .toolbar { ToolbarItem(placement:.confirmationAction) { Button("完成") { showColors = false } } }
                }
                .presentationDetents([.medium,.large])
            }
            .scrollDismissesKeyboard(.immediately)
            .onSubmit { dismissInput() }
            .navigationTitle("编辑公式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement:.keyboard) {
                    Spacer()
                    Button("完成") { dismissInput() }.fontWeight(.semibold)
                }
                ToolbarItem(placement:.cancellationAction) { Button("取消") { dismissInput(); dismiss() } }
                ToolbarItem(placement:.confirmationAction) {
                    Button("保存") {
                        dismissInput()
                        guard check() else { return }
                        draft.name = draft.name.trimmingCharacters(in:.whitespacesAndNewlines)
                        // Raw edits must never leave stale visual composition metadata.
                        if let composition = draft.composition,
                           (try? composition.source()) != draft.source {
                            draft.composition = nil
                        }
                        onSave(draft); dismiss()
                    }
                    .disabled(draft.source.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                }
            }
            .onChange(of:draft.source) { _,_ in result = nil }
            .onChange(of:draft.name) { _,_ in result = nil }
        }
    }

    private func dismissInput() {
        focusedField = nil
        IndicatorKeyboard.dismiss()
    }

    @discardableResult private func check() -> Bool {
        do {
            let name = draft.name.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 24 else { throw FormulaFailure("指标名称长度需为1～24字") }
            guard !draft.source.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw FormulaFailure("请输入公式") }
            _ = try FormulaProgram(draft.source)
            passed = true; result = "公式检查通过。"
            return true
        } catch {
            passed = false; result = error.localizedDescription
            return false
        }
    }
}
