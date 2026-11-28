import SwiftUI
import TradingChart

struct BuiltInIndicatorEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var settings: ChartDisplaySettings
    let kind: ChartIndicatorKind
    let bars: [FormulaBar]
    @State private var draft = ChartDisplaySettings()
    @State private var initialized = false
    private var type: MovingAverageType? {
        switch kind { case .sma:return .sma; case .emaFast:return .ema; case .wma:return .wma; default:return nil }
    }
    private var slots: [ChartIndicatorKind] { kind == .emaFast ? [.emaFast,.emaSlow] : [kind] }
    private var title: String { kind == .sma ? "MA（均线）" : kind == .emaFast ? "EMA（指数均线）" : kind.title }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                Toggle("启用该指标",isOn:enabled).padding(12).background(panel)
                Text("参数设置").font(.subheadline.weight(.semibold)).foregroundStyle(MarketPalette.muted)
                VStack(spacing:10) {
                    if let type {
                        HStack { Text("显示"); Text("名称"); Spacer(); Text("周期"); Spacer(); Text("颜色") }.font(.caption).foregroundStyle(MarketPalette.muted)
                        ForEach(slots) { slot in
                            averageRow(slot.rawValue,label:slot == .emaSlow ? "EMA2" : slot == .emaFast ? "EMA1" : title.components(separatedBy:"（")[0],type:type,period:period(slot),active:slotEnabled(slot))
                            Divider()
                        }
                        ForEach($draft.additionalAverages) { $average in
                            if average.type == type || (kind == .sma && ![.sma,.ema,.wma].contains(average.type)) {
                                if average.type == .dma {
                                    HStack { Toggle("DMA",isOn:$average.enabled); TextField("权重",value:$average.dynamicAlpha,format:.number).keyboardType(.decimalPad).frame(width:65) }
                                } else {
                                    averageRow(average.id.uuidString,label:average.type.title,type:average.type,period:$average.period,active:$average.enabled)
                                    if average.type == .smoothSMA { Stepper("平滑权重 M：\(average.smoothingWeight)",value:$average.smoothingWeight,in:1...max(1,average.period)) }
                                }
                                HStack {
                                    Picker("计算类型",selection:$average.type) { ForEach(MovingAverageType.allCases) { Text($0.title).tag($0) } }
                                    Spacer()
                                    Button(role:.destructive) { let id=average.id; draft.additionalAverages.removeAll{$0.id==id}; draft.averageColors.removeValue(forKey:id.uuidString); draft.averageWidths.removeValue(forKey:id.uuidString); draft.averageLineTypes.removeValue(forKey:id.uuidString) } label: { Image(systemName:"minus.circle") }.buttonStyle(.plain)
                                }.font(.caption)
                                Divider()
                            }
                        }
                        Button {
                            let used = Set(draft.additionalAverages.filter{$0.type==type}.map(\.period) + slots.map{period($0).wrappedValue})
                            if let p = ([5,10,20,30,50,60,100,120,200]+Array(2...500)).first(where:{!used.contains($0)}) {
                                draft.additionalAverages.append(AdditionalMovingAverage(type:type,period:p))
                            }
                        } label: { Label("添加一条均线",systemImage:"plus.circle").frame(maxWidth:.infinity,alignment:.leading) }.buttonStyle(.plain).foregroundStyle(MarketPalette.accent)
                    } else { parameters }
                }.padding(12).background(panel)
                Text("效果预览").font(.subheadline.weight(.semibold)).foregroundStyle(MarketPalette.muted)
                if bars.isEmpty { Text("从K线页进入指标管理可预览真实行情。").font(.caption).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading).padding(16).background(panel) }
                else if let type { averagePreview(type) }
                else { Text("该指标的完整绘图请在K线页查看。").font(.caption).foregroundStyle(.secondary).padding(12).background(panel) }
                Button { if draft.isValid { settings=draft; dismiss() } } label: {
                    Text("保存").font(.headline).foregroundStyle(.white).frame(maxWidth:.infinity).padding(13).background(MarketPalette.accent,in:RoundedRectangle(cornerRadius:10))
                }.buttonStyle(.plain).disabled(!draft.isValid).opacity(draft.isValid ? 1 : 0.4)
                if !draft.isValid { Text("参数无效或启用的均线重复。").foregroundStyle(.red).font(.caption) }
            }.padding(16)
        }.background(MarketPalette.background.ignoresSafeArea()).navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .task { if !initialized { draft=settings; initialized=true } }
    }
    private var panel: some ShapeStyle { Color.primary.opacity(0.055) }
    private var enabled: Binding<Bool> {
        Binding(get:{ slots.contains{draft.enabled.contains($0)} || (type.map{t in draft.additionalAverages.contains{$0.type==t && $0.enabled}} ?? false) },set:{value in
            for slot in slots { if value { draft.enabled.insert(slot) } else { draft.enabled.remove(slot) } }
            if let type { for i in draft.additionalAverages.indices where draft.additionalAverages[i].type == type { draft.additionalAverages[i].enabled=value } }
        })
    }
    private func slotEnabled(_ slot:ChartIndicatorKind)->Binding<Bool> {
        Binding(get:{draft.enabled.contains(slot)},set:{if $0 { draft.enabled.insert(slot) } else { draft.enabled.remove(slot) }})
    }
    private func period(_ slot:ChartIndicatorKind)->Binding<Int> {
        switch slot { case .sma:return $draft.sma; case .emaFast:return $draft.emaFast; case .emaSlow:return $draft.emaSlow; default:return $draft.wma }
    }
    private func averageRow(_ key:String,label:String,type:MovingAverageType,period:Binding<Int>,active:Binding<Bool>)->some View {
        VStack(spacing:8) {
            HStack(spacing:8) {
                Button { active.wrappedValue.toggle() } label: { Image(systemName:active.wrappedValue ? "checkmark.square.fill":"square").foregroundStyle(MarketPalette.accent) }.buttonStyle(.plain)
                Text(label).font(.subheadline).frame(width:46,alignment:.leading)
                Spacer(minLength:0)
                Button { period.wrappedValue=max(2,period.wrappedValue-1) } label:{Image(systemName:"minus")}.buttonStyle(.borderless)
                TextField("周期",value:period,format:.number).keyboardType(.numberPad).multilineTextAlignment(.center).frame(width:42)
                Button { period.wrappedValue=min(500,period.wrappedValue+1) } label:{Image(systemName:"plus")}.buttonStyle(.borderless)
                Spacer(minLength:0)
                ColorPicker("颜色",selection:Binding(get:{
                    let c=draft.averageStyle(key:key,type:type,period:max(2,min(500,period.wrappedValue))).color ?? ChartDisplaySettings.averageColor(type:type,period:20)
                    return Color(red:c.red,green:c.green,blue:c.blue)
                },set:{if let n=CandleAppearance.rgb($0){draft.averageColors[key]=String(format:"%06X",n)}}),supportsOpacity:false).labelsHidden()
            }
            HStack {
                Text("线宽").font(.caption).foregroundStyle(.secondary)
                Picker("线宽",selection:Binding(get:{draft.averageWidths[key] ?? 1.7},set:{draft.averageWidths[key]=$0})) {
                    ForEach([0.5,1.0,1.5,1.7,2.0,2.5,3.0,3.5,4.0],id:\.self){Text($0.formatted()).tag($0)}
                }.pickerStyle(.menu)
                Spacer()
                Picker("线型",selection:Binding(get:{draft.averageLineTypes[key] ?? "solid"},set:{draft.averageLineTypes[key]=$0})) {
                    Text("实线").tag("solid"); Text("虚线").tag("dash"); Text("点线").tag("dot")
                }.pickerStyle(.segmented).frame(maxWidth:175)
            }
        }
    }
    @ViewBuilder private var parameters:some View {
        switch kind {
        case .boll:
            Stepper("计算周期：\(draft.bollPeriod)",value:$draft.bollPeriod,in:2...500)
            HStack { Text("标准差倍数"); Spacer(); TextField("倍数",value:$draft.bollMultiplier,format:.number).keyboardType(.decimalPad).frame(width:72) }
        case .sar:
            HStack { Text("加速因子"); Spacer(); TextField("数值",value:$draft.sarStep,format:.number).keyboardType(.decimalPad).frame(width:72) }
            HStack { Text("最大加速因子"); Spacer(); TextField("数值",value:$draft.sarMaximum,format:.number).keyboardType(.decimalPad).frame(width:72) }
        case .macd:
            Stepper("快线：\(draft.macdFast)",value:$draft.macdFast,in:2...500)
            Stepper("慢线：\(draft.macdSlow)",value:$draft.macdSlow,in:2...500)
            Stepper("信号：\(draft.macdSignal)",value:$draft.macdSignal,in:2...500)
        case .rsi: Stepper("周期：\(draft.rsi)",value:$draft.rsi,in:2...500)
        case .kdj:
            Stepper("RSV：\(draft.kdjPeriod)",value:$draft.kdjPeriod,in:2...500)
            Stepper("K：\(draft.kdjK)",value:$draft.kdjK,in:2...500)
            Stepper("D：\(draft.kdjD)",value:$draft.kdjD,in:2...500)
        case .atr: Stepper("周期：\(draft.atrPeriod)",value:$draft.atrPeriod,in:2...500)
        case .volume: Stepper("成交量均线：\(draft.volumeMA)",value:$draft.volumeMA,in:2...500)
        default: Text("无需额外参数").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func averagePreview(_ type:MovingAverageType)->some View {
        // Use the same native indicator implementation and style as the chart.
        var only=draft
        only.enabled=only.enabled.intersection(Set(slots))
        only.additionalAverages=only.additionalAverages.filter{$0.type==type}
        only.formulas=[]
        return IndicatorWorkspacePreview(bars:bars,settings:only).frame(height:145)
    }
}
