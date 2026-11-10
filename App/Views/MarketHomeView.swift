import SwiftUI

struct MarketHomeView: View {
    @State private var instruments = FuturesInstrument.samples
    private let yellow = Color(red:1,green:0.82,blue:0.02)
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                homeHeader
                HStack(spacing: 0) {
                    Text("名称").frame(maxWidth:.infinity,alignment:.leading)
                    Image(systemName:"square.grid.2x2.fill").frame(width:34)
                    header("最新")
                    header("涨幅%")
                    header("日增仓")
                }
                .font(.system(size:14,weight:.semibold)).foregroundStyle(.white)
                .padding(.horizontal,12).padding(.vertical,15)
                .background(.ultraThinMaterial,in:Capsule())
                .overlay(Capsule().stroke(LinearGradient(colors:[.white,.cyan.opacity(0.5),.white.opacity(0.25)],startPoint:.topLeading,endPoint:.bottomTrailing),lineWidth:1))
                .shadow(color:.cyan.opacity(0.2),radius:8)
                .padding(.horizontal,12).padding(.top,5).padding(.bottom,5)
                ScrollView {
                    LazyVStack(spacing:0) {
                        ForEach(instruments) { item in
                            NavigationLink { InstrumentDetailView(instrument:item) } label: {
                                HStack(spacing:0) {
                                    HStack(spacing:5) {
                                        Text(item.name).font(.system(size:17,weight:.semibold)).foregroundStyle(yellow).lineLimit(1)
                                        Text("M").font(.system(size:9,weight:.bold)).foregroundStyle(.black).padding(3).background(.pink,in:RoundedRectangle(cornerRadius:3))
                                    }.frame(maxWidth:.infinity,alignment:.leading)
                                    Text(item.lastPrice.formatted()).foregroundStyle(item.isRising ? .red : .green).frame(width:76,alignment:.trailing)
                                    Text(String(format:"%.2f%%",item.changePercent)).foregroundStyle(item.isRising ? .red : .green).frame(width:78,alignment:.trailing)
                                    Text("\(Int(item.change * 37))").foregroundStyle(.white.opacity(0.8)).frame(width:72,alignment:.trailing)
                                }
                                .font(.system(size:16,weight:.medium,design:.rounded)).monospacedDigit()
                                .padding(.horizontal,12).frame(height:49)
                                .overlay(alignment:.bottom){Rectangle().fill(.white.opacity(0.14)).frame(height:0.5)}
                            }.buttonStyle(.plain)
                        }
                    }
                }
                Spacer(minLength:0)
                Text("演示行情 · 非实时数据").font(.caption2).foregroundStyle(.gray).padding(.bottom,8)
            }
            .background(Color.black)
            .toolbar(.hidden, for:.navigationBar)
        }.preferredColorScheme(.dark)
    }
    private var homeHeader: some View {
        ZStack {
            Text("期汇").font(.system(size:20,weight:.bold)).foregroundStyle(.white)
            HStack {
                Spacer()
                Image(systemName:"magnifyingglass")
                    .font(.system(size:19,weight:.medium))
                    .foregroundStyle(.white)
                    .frame(width:42,height:42)
                    .background(.ultraThinMaterial,in:Circle())
                    .overlay(Circle().stroke(.white.opacity(0.18),lineWidth:1))
            }
        }
        .frame(height:46)
        .padding(.horizontal,16)
        .padding(.top,1)
    }
    private func header(_ value:String)->some View { Text(value).frame(width:78,alignment:.trailing) }
}
