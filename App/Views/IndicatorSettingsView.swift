import SwiftUI

struct IndicatorSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.qihuiInPageStack) private var inPageStack
    @State private var draft:ChartDisplaySettings
    @State private var main=true
    @State private var route:[Route]=[]
    private var backgroundStyle=MarketBackgroundStyle()
    let previewBars:[FormulaBar]
    let onSave:(ChartDisplaySettings)->Void
    var onExit:(()->Void)?=nil
    private enum Route:Hashable {
        case average(MovingAverageType)
        case builtIn(ChartIndicatorKind)
        case formula(UUID)
        case newFormula
    }
    init(settings:ChartDisplaySettings,previewBars:[FormulaBar]=[],onExit:(()->Void)?=nil,onSave:@escaping(ChartDisplaySettings)->Void) {
        _draft=State(initialValue:settings)
        self.previewBars=previewBars
        self.onExit=onExit
        self.onSave=onSave
    }
    var body:some View {
        // Explicitly owned child path. The settings parent controls its own presentation.
        if inPageStack { workspace }
        else { NavigationStack { workspace } }
    }
    private var workspace:some View {
        VStack(spacing:12) {
            HStack(spacing:4) { tab("主图指标",true);tab("副图指标",false) }
                .padding(4).background(Color.primary.opacity(0.05),in:RoundedRectangle(cornerRadius:12))
            List {
                Section {
                    if main {
                        ForEach(MovingAverageType.allCases) { type in
                            row(type.title,detail:description(type),visible:Binding(get:{draft.toolbarAverages.contains(type)},set:{draft.setToolbarAverage(type,$0)})) { route=[.average(type)] }
                        }
                    }
                    ForEach(main ? ChartDisplaySettings.mainKinds : ChartDisplaySettings.subKinds) { kind in
                        row(kind.title,detail:"",visible:Binding(get:{draft.toolbarKinds.contains(kind)},set:{draft.setToolbarKind(kind,$0)})) { route=[.builtIn(kind)] }
                    }
                } header:{Text("内置指标")} footer:{Text("开关仅控制K线底栏入口，绘制状态由底栏控制。")}
                Section("公式指标") {
                    ForEach(draft.formulas.filter{$0.overlay==main}) { formula in
                        row(formula.name,detail:"公式",visible:Binding(get:{draft.toolbarFormulas.contains(formula.id)},set:{draft.setToolbarFormula(formula.id,$0)})) { route=[.formula(formula.id)] }
                            .swipeActions { Button("删除",role:.destructive) { draft.formulas.removeAll{$0.id==formula.id};draft.toolbarFormulas.remove(formula.id) } }
                    }
                    if !draft.formulas.contains(where:{$0.overlay==main}) { Text("暂无公式指标").foregroundStyle(MarketPalette.muted) }
                }
            }.listStyle(.insetGrouped).scrollContentBackground(.hidden)
            Button { route=[.newFormula] } label:{
                Label("新建公式指标",systemImage:"plus").foregroundStyle(.white).frame(maxWidth:.infinity).padding(13)
                    .background(MarketPalette.accent,in:RoundedRectangle(cornerRadius:10))
            }.buttonStyle(.plain).disabled(draft.formulas.count>=12).padding(.horizontal,16)
        }.padding(.top,8).padding(.bottom,12)
        .background(backgroundStyle.raised.ignoresSafeArea()).navigationTitle("指标管理").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !inPageStack { ToolbarItem(placement:.cancellationAction){Button("取消"){dismiss()}} }
            ToolbarItem(placement:.confirmationAction){Button("保存"){onSave(draft);if let onExit {onExit()}else{dismiss()}}.disabled(!draft.isValid)}
        }
        .navigationDestination(isPresented:Binding(get:{!route.isEmpty},set:{if !$0 {route=[]}})) {
            if let current=route.last {
                switch current {
                case .average(let type):
                    BuiltInIndicatorEditor(settings:draft,type:type,kind:nil,bars:previewBars,onSave:{draft=$0;route=[]})
                case .builtIn(let kind):
                    BuiltInIndicatorEditor(settings:draft,type:nil,kind:kind,bars:previewBars,onSave:{draft=$0;route=[]})
                case .formula(let id):
                    if let formula=draft.formulas.first(where:{$0.id==id}) { formulaEditor(formula) }
                case .newFormula:
                    formulaEditor(newFormula)
                }
            }
        }.tint(MarketPalette.accent)
    }
    private var newFormula:FormulaDefinition { var f=FormulaDefinition();f.overlay=main;return f }
    private func formulaEditor(_ formula:FormulaDefinition)->some View {
        FormulaEditorView(draft:formula,onSave:{updated in
            if let i=draft.formulas.firstIndex(where:{$0.id==updated.id}) { draft.formulas[i]=updated }
            else if draft.formulas.count<12 { draft.formulas.append(updated);draft.toolbarFormulas.insert(updated.id) }
            route=[]
        },previewBars:previewBars,onExit:{route=[]}).environment(\.qihuiInPageStack,true)
    }
    private func row(_ name:String,detail:String,visible:Binding<Bool>,action:@escaping()->Void)->some View {
        HStack(spacing:10) {
            Image(systemName:"chart.xyaxis.line").foregroundStyle(MarketPalette.accent).frame(width:24)
            Button(action:action) { HStack { Text(name).font(.subheadline.weight(.semibold));Text(detail).font(.caption).foregroundStyle(MarketPalette.muted);Spacer(minLength:0) }.foregroundStyle(.primary).contentShape(Rectangle()) }.buttonStyle(.plain)
            Toggle("底栏显示 "+name,isOn:visible).labelsHidden().scaleEffect(0.82).fixedSize()
            Button(action:action){Image(systemName:"chevron.right").font(.caption.weight(.semibold)).foregroundStyle(MarketPalette.muted)}.buttonStyle(.plain)
        }
    }
    private func tab(_ title:String,_ value:Bool)->some View {
        Button {main=value} label:{Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(main==value ? Color.white : MarketPalette.muted).frame(maxWidth:.infinity).padding(.vertical,11).background(main==value ? MarketPalette.accent : Color.clear,in:RoundedRectangle(cornerRadius:9))}.buttonStyle(.plain)
    }
    private func description(_ type:MovingAverageType)->String {
        switch type {
        case .sma:return "简单移动平均"
        case .ema:return "指数移动平均"
        case .wma:return "加权移动平均"
        case .ema2:return "线性加权别名"
        case .hma:return "赫尔均线"
        case .dema:return "双重指数均线"
        case .tema:return "三重指数均线"
        case .smoothSMA:return "平滑移动平均"
        case .dma:return "动态移动平均"
        case .wilder:return "威尔德均线"
        }
    }
}
