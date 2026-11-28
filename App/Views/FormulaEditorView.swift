import SwiftUI
import UIKit

struct FormulaEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.qihuiInPageStack) private var inPageStack
    @FocusState private var focusedField: String?
    @State var draft: FormulaDefinition
    let onSave: (FormulaDefinition) -> Void
    @State private var result: String?
    @State private var passed = false
    @State private var showHelp = false
    @State private var showColors = false
    @State private var errorRange: NSRange?
    @State private var jump = 0
    @State private var selection = NSRange(location:0,length:0)
    @State private var insertion = 0

    var body: some View {
        QihuiPageStack {
            VStack(alignment:.leading,spacing:12) {
                VStack(spacing:10) {
                    HStack {
                        Text("名称").foregroundStyle(MarketPalette.muted).frame(width:48,alignment:.leading)
                        TextField("指标名称",text:$draft.name).focused($focusedField,equals:"name")
                        Toggle("显示指标",isOn:$draft.enabled).labelsHidden().fixedSize()
                    }
                    Divider()
                    HStack {
                        Text("类型").foregroundStyle(MarketPalette.muted).frame(width:48,alignment:.leading)
                        Picker("绘制位置",selection:$draft.overlay) {
                            Text("主图").tag(true)
                            Text("副图").tag(false)
                        }.pickerStyle(.segmented)
                    }
                }.font(.subheadline).padding(12).background(Color.primary.opacity(0.055),in:RoundedRectangle(cornerRadius:10))
                HStack {
                    Text("公式编辑").font(.subheadline.weight(.semibold)).foregroundStyle(MarketPalette.accent)
                    Spacer()
                    Text("期汇原生").font(.caption).foregroundStyle(MarketPalette.muted)
                }
                ZStack(alignment:.topLeading) {
                    NativeFormulaTextView(text:$draft.source,errorRange:errorRange,jump:jump,selection:$selection,insertion:insertion)
                    if draft.source.isEmpty {
                        Text("在此输入或粘贴期汇公式").font(.system(size:13)).foregroundStyle(.secondary)
                            .padding(.top,8).padding(.leading,6).allowsHitTesting(false)
                    }
                }.frame(minHeight:120).frame(maxHeight:.infinity)
                    .background(Color.black.opacity(0.18),in:RoundedRectangle(cornerRadius:8))
                    .overlay(RoundedRectangle(cornerRadius:8).stroke(Color.primary.opacity(0.12),lineWidth:1))
                if let result {
                    Button { if errorRange != nil { jump += 1 } } label: {
                        Text(result).font(.caption).foregroundStyle(passed ? Color.green : Color.red)
                    }.buttonStyle(.plain)
                }
                HStack(spacing:8) {
                    Button("检查公式") { dismissInput(); check() }.font(.subheadline.weight(.semibold))
                    Spacer()
                    Button { dismissInput(); showHelp.toggle(); if showHelp { showColors = false } } label: {
                        Label("函数",systemImage:"function").foregroundStyle(showHelp ? Color.white : MarketPalette.accent)
                    }
                    Button { dismissInput(); showColors.toggle(); if showColors { showHelp = false } } label: {
                        Label("颜色",systemImage:"paintpalette").foregroundStyle(showColors ? Color.white : MarketPalette.accent)
                    }
                }.buttonStyle(.plain).foregroundStyle(MarketPalette.accent).padding(.vertical,8)
                if showColors {
                    HStack(spacing:12) {
                        ForEach(["FF4545","20C6C8","D77DFF","FFFF00","4C8DFF","FFFFFF","FF00FF"],id:\.self) { hex in
                            Button {
                                insert("COLOR"+hex)
                            } label: {
                                Circle().fill(swatch(hex)).frame(width:30,height:30)
                                    .overlay(Circle().stroke(Color.white.opacity(0.25),lineWidth:1))
                            }.buttonStyle(.plain).accessibilityLabel("插入 COLOR"+hex)
                        }
                    }.frame(maxWidth:.infinity).padding(.vertical,8)
                }
                if showHelp {
                    ScrollView {
                        VStack(alignment:.leading,spacing:8) {
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
                        }.font(.caption).foregroundStyle(MarketPalette.muted).frame(maxWidth:.infinity,alignment:.leading)
                    }.frame(maxHeight:150)
                }
            }
            .padding(16)
            .background(MarketPalette.background.ignoresSafeArea())
            .scrollDismissesKeyboard(.immediately)
            .onSubmit { dismissInput() }
            .navigationTitle("编辑公式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement:.keyboard) {
                    Spacer()
                    Button("完成") { dismissInput() }.fontWeight(.semibold)
                }
                if !inPageStack {
                    ToolbarItem(placement:.cancellationAction) { Button("取消") { dismissInput(); dismiss() } }
                }
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
            .onChange(of:draft.source) { _,_ in result = nil; errorRange = nil }
            .onChange(of:draft.name) { _,_ in result = nil }
        }
    }

    private func swatch(_ hex:String) -> Color {
        let n = UInt32(hex,radix:16) ?? 0
        return Color(red:Double((n >> 16)&255)/255,green:Double((n >> 8)&255)/255,blue:Double(n&255)/255)
    }

    private func insert(_ value:String) {
        let source = draft.source as NSString
        let start = min(selection.location,source.length)
        let length = min(selection.length,source.length-start)
        draft.source = source.replacingCharacters(in:NSRange(location:start,length:length),with:value)
        selection = NSRange(location:start+value.utf16.count,length:0)
        insertion += 1
        showColors = false
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
            errorRange = nil; passed = true; result = "公式检查通过。"
            return true
        } catch {
            passed = false; result = error.localizedDescription
            errorRange = (error as? FormulaFailure)?.range
            if let range = errorRange {
                let prefix = (draft.source as NSString).substring(to:min(range.location,(draft.source as NSString).length))
                let lines = prefix.components(separatedBy:.newlines)
                result = "第\(lines.count)行，第\((lines.last ?? "").count+1)列：\(error.localizedDescription)"
                jump += 1
            }
            return false
        }
    }
}

private struct NativeFormulaTextView: UIViewRepresentable {
    @Binding var text: String
    let errorRange: NSRange?
    let jump: Int
    @Binding var selection: NSRange
    let insertion: Int
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.font = .monospacedSystemFont(ofSize:13,weight:.regular)
        view.textColor = .label
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.delegate = context.coordinator
        view.accessibilityLabel = "公式源码"
        view.text = text
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.markedTextRange != nil { return }
        if view.text != text { view.text = text }
        if context.coordinator.lastInsertion != insertion {
            context.coordinator.lastInsertion = insertion
            if NSMaxRange(selection) <= view.textStorage.length { view.selectedRange = selection; view.scrollRangeToVisible(selection) }
        }
        context.coordinator.paint(view)
        if context.coordinator.lastJump != jump {
            context.coordinator.lastJump = jump
            if let range = errorRange, NSMaxRange(range) <= view.textStorage.length {
                view.scrollRangeToVisible(range)
            }
        }
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NativeFormulaTextView
        var lastJump = 0
        var lastInsertion = 0
        var paintedText: String?
        var paintedRange: NSRange?
        init(_ parent: NativeFormulaTextView) { self.parent = parent }
        func textViewDidChangeSelection(_ view:UITextView) {
            guard view.markedTextRange == nil else { return }
            let range = view.selectedRange
            if parent.selection != range { parent.selection = range }
        }
        func textViewDidChange(_ view: UITextView) {
            guard view.markedTextRange == nil else { return }
            parent.text = view.text ?? ""
            paint(view,editing:true)
        }
        func paint(_ view: UITextView,editing:Bool = false) {
            let source = view.text ?? ""
            let range = editing ? nil : parent.errorRange
            guard paintedText != source || paintedRange != range else { return }
            paintedText = source; paintedRange = range
            let storage = view.textStorage
            let full = NSRange(location:0,length:storage.length)
            guard full.length > 0 else { return }
            storage.beginEditing()
            storage.setAttributes([.font:UIFont.monospacedSystemFont(ofSize:13,weight:.regular),.foregroundColor:UIColor.label],range:full)
            let rules: [(String,UIColor)] = [
                (#"\b[A-Za-z_][A-Za-z_0-9]*(?=\s*\()"#,.systemTeal),
                (#"\b(?:COLOR[A-Za-z0-9]+|LINETHICK[0-9]+|FONTSIZE[0-9]+|DOT|DASHLINE|NODRAW)\b"#,.systemPurple),
                (#"\b[0-9]+(?:\.[0-9]+)?\b"#,.systemOrange),
                (#"'[^'\n]*'|"[^"\n]*""#,.systemYellow),
                (#"//[^\n]*|\{[^}]*\}"#,.secondaryLabel)
            ]
            for (pattern,color) in rules {
                guard let regex = try? NSRegularExpression(pattern:pattern,options:[.caseInsensitive]) else { continue }
                for match in regex.matches(in:source,range:full) {
                    storage.addAttribute(.foregroundColor,value:color,range:match.range)
                }
            }
            if let range, range.location <= full.length, NSMaxRange(range) <= full.length {
                let visible = range.length == 0 && range.location > 0 ? NSRange(location:range.location-1,length:1) : range
                if visible.length > 0 {
                    storage.addAttributes([.foregroundColor:UIColor.systemRed,.underlineColor:UIColor.systemRed,.underlineStyle:NSUnderlineStyle.single.rawValue],range:visible)
                }
            }
            storage.endEditing()
            view.typingAttributes = [.font:UIFont.monospacedSystemFont(ofSize:13,weight:.regular),.foregroundColor:UIColor.label]
        }
    }
}
