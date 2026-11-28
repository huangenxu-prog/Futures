import SwiftUI
import TradingChart

struct BuiltInIndicatorEditor:View {
    @State private var draft:ChartDisplaySettings
    let type:MovingAverageType?
    let kind:ChartIndicatorKind?
    let bars:[FormulaBar]
    let onSave:(ChartDisplaySettings)->Void
    private var backgroundStyle=MarketBackgroundStyle()
    init(settings:ChartDisplaySettings,type:MovingAverageType?,kind:ChartIndicatorKind?,bars:[FormulaBar],onSave:@escaping(ChartDisplaySettings)->Void) {
        _draft=State(initialValue:settings);self.type=type;self.kind=kind;self.bars=bars;self.onSave=onSave
    }
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                if let type {
                    VStack(spacing:0) {
                        HStack(spacing:8) {
                            Text("显示").frame(width:34)
                            Text(type == .dma ? "权重":"周期").frame(maxWidth:.infinity)
                            if type == .smoothSMA { Text("M").frame(width:30) }
                            Text("颜色").frame(width:34)
                            Text("线宽").frame(width:42)
                            Text("线型").frame(width:42)
                            Color.clear.frame(width:24,height:1)
                        }.font(.caption).foregroundStyle(MarketPalette.muted).padding(.vertical,10)
                        ForEach($draft.additionalAverages) { $average in
                            if average.type==type { Divider();averageRow($average) }
                        }
                        Divider()
                        Button { add(type) } label:{
                            Label("添加一条均线",systemImage:"plus.circle").frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,14)
                        }.buttonStyle(.plain).foregroundStyle(MarketPalette.accent)
                    }.padding(.horizontal,12).background(backgroundStyle.surface,in:RoundedRectangle(cornerRadius:12))
                } else {
                    VStack(spacing:12){parameters}.padding(12).background(backgroundStyle.surface,in:RoundedRectangle(cornerRadius:12))
                }
                if !draft.isValid { Text("参数无效或重复，保留上一次有效设置。").font(.caption).foregroundStyle(.red) }
                if !bars.isEmpty && kind != .intraday && draft.isValid {
                    Text("效果预览").font(.subheadline.weight(.semibold)).foregroundStyle(MarketPalette.muted)
                    IndicatorWorkspacePreview(bars:bars,settings:previewSettings).frame(height:type != nil || kind == .boll || kind == .sar ? 170:250)
                }
            }.padding(16)
        }.background(backgroundStyle.raised.ignoresSafeArea())
        .navigationTitle(type?.title ?? kind?.title ?? "指标参数").navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar { ToolbarItemGroup(placement:.keyboard){Spacer();Button("完成"){IndicatorKeyboard.dismiss()}} }
        .onChange(of:draft) { _,updated in if updated.isValid {onSave(updated)} }
    }
    private func add(_ type:MovingAverageType) {
        if type == .dma {
            let used=Set(draft.additionalAverages.filter{$0.type==type}.map(\.dynamicAlpha))
            if let a=(1...99).map({Double($0)/100}).first(where:{!used.contains($0)}) {
                draft.additionalAverages.append(AdditionalMovingAverage(type:type,period:20,alpha:a))
            }
        } else {
            let used=Set(draft.additionalAverages.filter{$0.type==type}.map(\.period))
            if let p=([5,10,20,30,50,60,100,120,200]+Array(2...500)).first(where:{!used.contains($0)}) {
                draft.additionalAverages.append(AdditionalMovingAverage(type:type,period:p))
            }
        }
    }
    private func averageRow(_ average:Binding<AdditionalMovingAverage>)->some View {
        let id=average.wrappedValue.id
        let key=id.uuidString
        let t=average.wrappedValue.type
        let period=average.wrappedValue.period
        return HStack(spacing:8) {
            Button { average.wrappedValue.enabled.toggle() } label:{
                Image(systemName:average.wrappedValue.enabled ? "checkmark.square.fill":"square").foregroundStyle(MarketPalette.accent).frame(width:34,height:32)
            }.buttonStyle(.plain)
            if t == .dma {
                TextField("权重",value:average.dynamicAlpha,format:.number).keyboardType(.decimalPad).multilineTextAlignment(.center)
            } else {
                TextField("周期",value:average.period,format:.number).keyboardType(.numberPad).multilineTextAlignment(.center)
            }
            if t == .smoothSMA {
                TextField("M",value:average.smoothingWeight,format:.number).keyboardType(.numberPad).multilineTextAlignment(.center).frame(width:30)
            }
            ColorPicker("颜色",selection:Binding(get:{
                let c=draft.averageStyle(key:key,type:t,period:max(2,min(500,period))).color ?? ChartDisplaySettings.averageColor(type:t,period:20)
                return Color(red:c.red,green:c.green,blue:c.blue)
            },set:{if let n=CandleAppearance.rgb($0){draft.averageColors[key]=String(format:"%06X",n)}}),supportsOpacity:false).labelsHidden().frame(width:34)
            Menu {
                ForEach([0.5,1.0,1.5,1.7,2.0,2.5,3.0,3.5,4.0],id:\.self){w in Button(w.formatted()){draft.averageWidths[key]=w}}
            } label:{Text((draft.averageWidths[key] ?? 1.7).formatted()).frame(width:42)}.foregroundStyle(MarketPalette.accent)
            Menu {
                Button("实线"){draft.averageLineTypes[key]="solid"}
                Button("虚线"){draft.averageLineTypes[key]="dash"}
                Button("点线"){draft.averageLineTypes[key]="dot"}
            } label:{
                Image(systemName:draft.averageLineTypes[key]=="dot" ? "ellipsis":draft.averageLineTypes[key]=="dash" ? "line.horizontal.3":"minus").frame(width:42)
            }.foregroundStyle(MarketPalette.accent)
            Button(role:.destructive) {
                IndicatorKeyboard.dismiss()
                draft.additionalAverages.removeAll{$0.id==id}
                draft.averageColors.removeValue(forKey:key);draft.averageWidths.removeValue(forKey:key);draft.averageLineTypes.removeValue(forKey:key)
            } label:{Image(systemName:"minus.circle").frame(width:24)}.buttonStyle(.plain)
        }.font(.subheadline.monospacedDigit()).padding(.vertical,8)
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

    private var previewSettings:ChartDisplaySettings {
        var only=draft;only.enabled=[];only.toolbarKinds=[];only.toolbarAverages=[];only.activeAverages=[];only.formulas=[]
        if let type {only.toolbarAverages=[type];only.activeAverages=[type]}
        if let kind {only.enabled=[kind];only.toolbarKinds=[kind]}
        return only
    }
}
