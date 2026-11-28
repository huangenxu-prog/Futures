import SwiftUI

struct FormulaComposerView: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: String?
    @State private var draft: FormulaDefinition
    @State private var composition: FormulaComposition
    @State private var error: String?
    @State private var checked = false
    @State private var showingSource = false
    @State private var preview: PreviewSnapshot?
    let previewBars: [FormulaBar]
    let onSave: (FormulaDefinition) -> Void

    private struct PreviewSnapshot {
        let composition: FormulaComposition
        let outputs: [FormulaOutput]
        let error: String?
    }

    init(draft: FormulaDefinition, previewBars: [FormulaBar] = [],
         onSave: @escaping (FormulaDefinition) -> Void) {
        _draft = State(initialValue: draft)
        _composition = State(initialValue: draft.composition ?? FormulaComposition())
        self.previewBars = previewBars
        self.onSave = onSave
    }

    var body: some View {
        QihuiPageStack {
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    metadataSection
                    curveSections
                    addCurveSection
                    previewSection
                    sourceSection
                }.padding(16)
            }
            .scrollDismissesKeyboard(.immediately)
            .onSubmit { dismissInput() }
            .scrollContentBackground(.hidden)
            .background(MarketPalette.background.ignoresSafeArea())
            .navigationTitle("组合指标")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement:.keyboard) {
                    Spacer()
                    Button("完成") { dismissInput() }.fontWeight(.semibold)
                }
                ToolbarItem(placement:.cancellationAction) {
                    Button("取消") { dismissInput(); dismiss() }
                }
                ToolbarItem(placement:.confirmationAction) {
                    Button("保存") {
                        dismissInput()
                        guard let source = validate() else {
                            showingSource = true
                            return
                        }
                        draft.name = draft.name.trimmingCharacters(in:.whitespacesAndNewlines)
                        draft.source = source
                        draft.composition = composition
                        onSave(draft)
                        dismiss()
                    }
                }
            }
            .onChange(of:composition) { _,_ in error = nil; checked = false }
            .onChange(of:draft.name) { _,_ in error = nil; checked = false }
            .task(id:composition) { await updatePreview() }
        }
        .tint(MarketPalette.accent)
    }

    private func dismissInput() {
        focusedField = nil
        IndicatorKeyboard.dismiss()
    }

    private var metadataSection: some View {
        VStack(spacing:10) {
            HStack {
                TextField("指标名称",text:$draft.name).focused($focusedField,equals:"indicator-name")
                Toggle("显示指标",isOn:$draft.enabled).labelsHidden().fixedSize()
            }
            Picker("绘制位置",selection:$draft.overlay) {
                Text("主图").tag(true)
                Text("副图").tag(false)
            }.pickerStyle(.segmented)
        }.padding(12).background(Color.primary.opacity(0.055),in:RoundedRectangle(cornerRadius:10))
    }

    private var curveSections: some View {
        ForEach($composition.lines) { binding in
            curveSection(binding)
        }
    }

    private func curveSection(_ binding: Binding<CompositionLine>) -> some View {
        let id = binding.wrappedValue.id
        let number = index(for:id)
        let canDelete = composition.lines.count > 1
        return VStack {
            CompositionLineEditor(line:binding,number:number,canDelete:canDelete,focusedField:$focusedField,onDelete: {
                removeCurve(id)
            })
        }.padding(12).background(Color.primary.opacity(0.055),in:RoundedRectangle(cornerRadius:10))
    }

    private func removeCurve(_ id:UUID) {
        dismissInput()
        composition.lines.removeAll { $0.id == id }
    }

    private var addCurveSection: some View {
        Button { dismissInput(); composition.lines.append(CompositionLine()) } label: {
            Label("新增曲线",systemImage:"plus.circle").font(.subheadline.weight(.semibold)).frame(maxWidth:.infinity).padding(.vertical,10)
        }.buttonStyle(.plain).foregroundStyle(MarketPalette.accent).disabled(composition.lines.count >= 8)
    }

    private var previewSection: some View {
        VStack(alignment:.leading,spacing:8) {
            Text("效果预览").font(.subheadline.weight(.semibold))
            previewContent
        }.padding(12).background(Color.primary.opacity(0.055),in:RoundedRectangle(cornerRadius:10))
    }

    private var sourceSection: some View {
        VStack(alignment:.leading,spacing:8) {
            DisclosureGroup("查看生成公式",isExpanded:$showingSource) {
                if let source = try? composition.source() {
                    Text(source).font(.system(size:12,design:.monospaced)).textSelection(.enabled)
                } else {
                    Text("请检查计算参数").foregroundStyle(.secondary)
                }
            }
            Button("检查公式") { dismissInput(); checked = validate() != nil }
            if checked {
                Label("公式检查通过",systemImage:"checkmark.circle")
                    .font(.caption).foregroundStyle(.green)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        if previewBars.isEmpty {
            Text("当前没有可用于预览的K线，仍可编辑并保存。")
                .font(.caption).foregroundStyle(.secondary)
        } else if let preview, preview.composition == composition {
            if let message = preview.error {
                Text(message).font(.caption).foregroundStyle(.red)
            } else if preview.outputs.contains(where: { $0.values.suffix(80).contains { $0?.isFinite == true } }) {
                CompositionPreviewChart(outputs:preview.outputs)
                    .frame(height:145)
                    .accessibilityLabel("组合指标曲线预览")
                ForEach(Array(preview.outputs.enumerated()),id:\.offset) { item in
                    HStack(spacing:6) {
                        Circle().fill(previewColor(composition.lines[item.offset].color,index:item.offset))
                            .frame(width:8,height:8)
                        Text(item.element.name).font(.caption)
                        Spacer()
                        Text(item.element.values.last.flatMap{$0}.map{
                            $0.formatted(.number.precision(.fractionLength(0...4)))
                        } ?? "无有效值")
                        .font(.caption.monospacedDigit())
                    }
                }
                Text("计算 \(previewBars.count) 根 · 展示最近 \(min(80,previewBars.count)) 根")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("最近K线暂无有效指标值，请检查数据源、周期或预热长度。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            HStack { ProgressView(); Text("计算预览…").font(.caption) }
        }
    }

    @MainActor
    private func updatePreview() async {
        guard !previewBars.isEmpty else { return }
        let snapshot = composition, bars = previewBars
        do {
            try await Task.sleep(for:.milliseconds(150))
            let calculation = Task.detached(priority:.userInitiated) {
                try FormulaProgram(snapshot.validatedSource()).evaluate(bars)
            }
            let outputs = try await withTaskCancellationHandler {
                try await calculation.value
            } onCancel: { calculation.cancel() }
            try Task.checkCancellation()
            guard snapshot == composition else { return }
            preview = PreviewSnapshot(composition:snapshot,outputs:outputs,error:nil)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled,snapshot == composition else { return }
            preview = PreviewSnapshot(composition:snapshot,outputs:[],error:error.localizedDescription)
        }
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
            checked = false
            self.error = error.localizedDescription
            return nil
        }
    }
}

private struct CompositionLineEditor: View {
    @Binding var line: CompositionLine
    let number: Int
    let canDelete: Bool
    var focusedField: FocusState<String?>.Binding
    let onDelete: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {
                Circle().fill(previewColor(line.color,index:number-1))
                    .frame(width:9,height:9)
                TextField("LINE\(number)",text:Binding(
                    get:{ line.name ?? "" },
                    set:{ line.name = $0.isEmpty ? nil : $0 }
                ))
                .focused(focusedField,equals:"name-\(line.id)")
                .font(.headline)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("曲线 \(number) 名称")
                Spacer()
                Menu {
                    ForEach(CompositionColor.allCases) { color in
                        Button(color.title) { line.color = color }
                    }
                } label: {
                    Circle().fill(previewColor(line.color,index:number-1)).frame(width:18,height:18)
                }
                Menu {
                    ForEach(1...5,id:\.self) { width in Button("\(width)") { line.width = width } }
                } label: { Text("\(line.width)").font(.caption).foregroundStyle(MarketPalette.accent) }
                Button { withAnimation(.easeInOut(duration:0.18)) { expanded.toggle() } } label: {
                    Image(systemName:expanded ? "chevron.up" : "chevron.down").foregroundStyle(MarketPalette.muted)
                }.buttonStyle(.plain)
            }
            Text((try? line.calculationExpression()) ?? "请检查计算参数")
                .font(.system(size:12,design:.monospaced)).foregroundStyle(previewColor(line.color,index:number-1))
                .lineLimit(expanded ? nil : 2).frame(maxWidth:.infinity,alignment:.leading)
            if expanded {
            Divider()
            Picker("数据来源",selection:$line.source) {
                ForEach(CompositionSource.allCases) { source in
                    Text(source.title).tag(source)
                }
            }
            if line.source == .custom {
                TextField("价格表达式",text:$line.custom)
    .focused(focusedField,equals:"custom-\(line.id)")
                    .font(.system(size:13,design:.monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            ForEach($line.layers) { $layer in
                let position = index(for:layer.id)
                HStack(spacing:8) {
                    Text(position == 1 ? "第一次计算" : "第 \(position) 次计算")
                        .font(.subheadline)
                    Spacer(minLength:0)
                    Picker("计算函数",selection:$layer.function) {
                        ForEach(CompositionFunction.allCases) { function in
                            Text(function.rawValue).tag(function)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize(horizontal:true,vertical:false)
                    if layer.function != .abs && layer.function != .dma {
                        TextField("周期",value:$layer.period,format:.number)
    .focused(focusedField,equals:"period-\(layer.id)")
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width:48)
                            .accessibilityLabel("计算周期")
                    }
                    Menu {
                        Button("向前移动",systemImage:"arrow.up") {
                            dismissInput()
                            let i = index(for:layer.id)-1
                            if i > 0 { line.layers.swapAt(i,i-1) }
                        }.disabled(position <= 1)
                        Button("向后移动",systemImage:"arrow.down") {
                            dismissInput()
                            let i = index(for:layer.id)-1
                            if i >= 0 && i+1 < line.layers.count { line.layers.swapAt(i,i+1) }
                        }.disabled(position >= line.layers.count)
                        Button("删除这次计算",systemImage:"trash",role:.destructive) {
                            dismissInput()
                            let id = layer.id
                            line.layers.removeAll {$0.id == id}
                        }
                    } label: {
                        Image(systemName:"ellipsis").foregroundStyle(MarketPalette.muted)
                            .frame(width:22,height:28)
                    }
                    .accessibilityLabel("计算步骤操作")
                }
                if layer.function == .dma {
                    TextField("权重表达式（0～1）",text:$layer.alpha)
    .focused(focusedField,equals:"alpha-\(layer.id)")
                        .font(.system(size:13,design:.monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else if layer.function == .sma {
                    HStack {
                        Text("平滑权重 M").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        TextField("权重",value:$layer.weight,format:.number)
    .focused(focusedField,equals:"weight-\(layer.id)")
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width:58)
                    }
                }
            }
            Button {
                dismissInput()
                line.layers.append(CompositionLayer(period:5))
            } label: {
                Label(line.layers.isEmpty ? "添加计算" : "继续计算",systemImage:"plus.circle")
                    .font(.subheadline)
            }
            .buttonStyle(.plain)
            .foregroundStyle(MarketPalette.accent)
            .disabled(line.layers.count >= 6)
            Divider()
            Text((try? line.calculationExpression()).map { "\(line.outputName(index:number)):\($0)" } ?? "请检查计算参数")
                .font(.system(size:12,design:.monospaced))
                .foregroundStyle(previewColor(line.color,index:number-1))
                .textSelection(.enabled)
                .frame(maxWidth:.infinity,alignment:.leading)
            if expanded {
                Divider()
                Picker("颜色",selection:$line.color) {
                    ForEach(CompositionColor.allCases) { color in
                        Text(color.title).tag(color)
                    }
                }
                Toggle("柱状图",isOn:$line.histogram)
                if !line.histogram {
                    Stepper("线宽 \(line.width)",value:$line.width,in:1...5)
                }
                if canDelete {
                    Button("删除这条曲线",role:.destructive,action:onDelete)
                        .buttonStyle(.plain)
                }
            }
            }
        }
        .padding(.vertical,2)
    }

    private func dismissInput() {
        focusedField.wrappedValue = nil
        IndicatorKeyboard.dismiss()
    }

    private func index(for id: UUID) -> Int {
        (line.layers.firstIndex(where:{$0.id == id}) ?? 0)+1
    }
}

private func previewColor(_ color: CompositionColor,index:Int) -> Color {
    switch color {
    case .automatic:
        let colors = [MarketPalette.sma,MarketPalette.ema20,MarketPalette.ema50,MarketPalette.wma]
        return colors[index % colors.count]
    case .blue: return rgb("4C8DFF")
    case .yellow: return rgb("F5A623")
    case .red: return rgb("FF5B5B")
    case .green,.cyan: return rgb("23C6C8")
    case .purple: return rgb("D77DFF")
    case .white: return .white
    case .black: return .black
    }
}

private func rgb(_ hex:String) -> Color {
    let number = UInt32(hex,radix:16) ?? 0
    return Color(red:Double((number >> 16)&255)/255,
                 green:Double((number >> 8)&255)/255,blue:Double(number&255)/255)
}

private struct CompositionPreviewChart: View {
    let outputs: [FormulaOutput]

    var body: some View {
        Canvas { context,size in
            let samples = outputs.map { Array($0.values.suffix(80)) }
            var minimum = Double.infinity, maximum = -Double.infinity
            for (i,values) in samples.enumerated() {
                for value in values {
                    guard let value,value.isFinite else { continue }
                    minimum = min(minimum,value); maximum = max(maximum,value)
                }
                if outputs[i].histogram { minimum = min(minimum,0); maximum = max(maximum,0) }
            }
            guard minimum.isFinite,maximum.isFinite,size.width > 0,size.height > 0 else { return }
            let padding = max((maximum-minimum)*0.08,max(abs(maximum),1)*0.000001)
            let lower = minimum-padding,upper = maximum+padding
            let span = upper-lower
            guard span.isFinite,span > 0 else { return }
            let margin: CGFloat = 6
            let width = max(1,size.width-2*margin),height = max(1,size.height-2*margin)
            func y(_ v:Double) -> CGFloat { margin+height*CGFloat((upper-v)/span) }
            for j in 0...4 {
                let py = margin+height*CGFloat(j)/4
                var path = Path()
                path.move(to:CGPoint(x:margin,y:py))
                path.addLine(to:CGPoint(x:margin+width,y:py))
                context.stroke(path,with:.color(MarketPalette.divider),lineWidth:0.5)
            }
            for (i,values) in samples.enumerated() {
                let output = outputs[i]
                let color = output.color.map(rgb) ?? previewColor(.automatic,index:i)
                let step = width/CGFloat(max(1,values.count))
                var path = Path(), active = false
                for (j,value) in values.enumerated() {
                    guard let value,value.isFinite else { active = false; continue }
                    let x = margin+(CGFloat(j)+0.5)*step, py = y(value)
                    guard py.isFinite else { active = false; continue }
                    if output.histogram {
                        let zero = y(0)
                        let rect = CGRect(x:x-step*0.32,y:min(py,zero),width:max(1,step*0.64),height:max(1,abs(py-zero)))
                        let fill = output.color == nil ? MarketPalette.movement(value) : color
                        context.fill(Path(rect),with:.color(fill))
                    } else {
                        let point = CGPoint(x:x,y:py)
                        if active { path.addLine(to:point) }
                        else { path.move(to:point) }
                        active = true
                    }
                }
                if !output.histogram { context.stroke(path,with:.color(color),lineWidth:CGFloat(output.width)) }
            }
        }
        .clipped()
    }
}
