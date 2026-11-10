import SwiftUI

struct ContentView: View {
    @State private var selectedTab = 0
    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            Group {
                switch selectedTab {
                case 0: MarketHomeView()
                case 1: SearchView()
                default: ProfileView()
                }
            }
            .safeAreaPadding(.bottom, 88)
            GlassTabBar(selection: $selectedTab)
        }
        .preferredColorScheme(.dark)
    }
}

private struct GlassTabBar: View {
    @Binding var selection: Int
    private let items = [("自选","house.fill"),("搜索","magnifyingglass"),("我的","person.crop.circle")]
    var body: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                Button { selection = index } label: {
                    VStack(spacing: 5) {
                        Image(systemName: items[index].1).font(.system(size: 23, weight: .medium))
                        Text(items[index].0).font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(selection == index ? Color.cyan : .white)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(selection == index ? Color.white.opacity(0.13) : .clear, in: Capsule())
                }.buttonStyle(.plain)
            }
        }
        .padding(7)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(LinearGradient(colors:[.white.opacity(0.9),.white.opacity(0.15),.cyan.opacity(0.5)], startPoint:.topLeading,endPoint:.bottomTrailing),lineWidth:1))
        .shadow(color:.cyan.opacity(0.18),radius:14)
        .padding(.horizontal, 22).padding(.bottom, 8)
    }
}

private struct SearchView: View {
    @State private var query = ""
    private var filtered: [FuturesInstrument] {
        FuturesInstrument.samples.filter {
            query.isEmpty ||
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.id.localizedCaseInsensitiveContains(query) ||
            $0.exchange.localizedCaseInsensitiveContains(query)
        }
    }
    var body: some View {
        NavigationStack {
            VStack(spacing:0) {
                TextField("搜索合约名称或代码", text:$query)
                    .font(.system(size:16))
                    .padding(.horizontal,16)
                    .padding(.vertical,13)
                    .background(Color.white.opacity(0.08),in:Capsule())
                    .padding(.horizontal,16)
                    .padding(.top,12)
                    .padding(.bottom,8)

                if query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing:0) {
                            ForEach(filtered) { item in
                                NavigationLink {
                                    InstrumentDetailView(instrument:item)
                                } label: {
                                    InstrumentRow(instrument:item)
                                        .padding(.horizontal,16)
                                }
                                .buttonStyle(.plain)
                                .tint(.white)
                                .overlay(alignment:.bottom) {
                                    Rectangle().fill(.white.opacity(0.12)).frame(height:0.5)
                                }
                            }
                            if filtered.isEmpty {
                                Text("没有找到匹配的合约")
                                    .font(.caption)
                                    .foregroundStyle(.gray)
                                    .frame(maxWidth:.infinity)
                                    .padding(.top,28)
                            }
                        }
                    }
                }
                Spacer(minLength:0)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark,for:.navigationBar)
            .toolbarBackground(Color.black,for:.navigationBar)
            .toolbarBackground(.visible,for:.navigationBar)
        }
        .tint(.white)
        .preferredColorScheme(.dark)
    }
}

private struct ProfileView: View {
    private let cyan = Color(red:0.20,green:0.78,blue:0.96)
    private let green = Color(red:0.20,green:0.82,blue:0.57)
    private let red = Color(red:1.0,green:0.30,blue:0.34)

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators:false) {
                VStack(spacing:14) {
                    header
                    accountCard
                    assetCard
                    quickActions
                    settingsCard
                    footer
                }
                .padding(.horizontal,14)
                .padding(.top,6)
                .padding(.bottom,18)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark,for:.navigationBar)
            .toolbarBackground(Color.black,for:.navigationBar)
            .toolbarBackground(.visible,for:.navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing:12) {
            ZStack {
                Circle().fill(LinearGradient(colors:[cyan.opacity(0.9),Color.blue.opacity(0.45)],startPoint:.topLeading,endPoint:.bottomTrailing))
                Image(systemName:"person.fill").font(.system(size:27)).foregroundStyle(.white)
            }.frame(width:58,height:58)
            VStack(alignment:.leading,spacing:5) {
                Text("模拟交易员").font(.system(size:19,weight:.bold)).foregroundStyle(.white)
                Text("期汇体验账户 · ID 8862 0317").font(.system(size:11,design:.rounded)).foregroundStyle(.gray)
            }
            Spacer()
            Image(systemName:"chevron.right").foregroundStyle(.gray)
        }
        .padding(15)
        .background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:18))
        .overlay(RoundedRectangle(cornerRadius:18).stroke(.white.opacity(0.18),lineWidth:1))
    }

    private var accountCard: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text("模拟账户总资产").font(.system(size:13)).foregroundStyle(.white.opacity(0.72))
                Spacer()
                Label("模拟数据",systemImage:"info.circle").font(.system(size:10)).foregroundStyle(.orange)
            }
            HStack(alignment:.firstTextBaseline,spacing:5) {
                Text("¥").font(.system(size:20,weight:.medium)).foregroundStyle(.white)
                Text("128,650.80").font(.system(size:32,weight:.bold,design:.rounded)).monospacedDigit().foregroundStyle(.white)
            }
            HStack(spacing:0) {
                metric("今日盈亏","+2,386.40","+1.89%",green)
                Divider().overlay(.white.opacity(0.2)).frame(height:36)
                metric("持仓盈亏","+6,428.60","+5.26%",red)
                Divider().overlay(.white.opacity(0.2)).frame(height:36)
                metric("可用资金","96,320.80","74.88%",cyan)
            }
            .padding(.top,5)
        }
        .padding(16)
        .background(LinearGradient(colors:[Color(red:0.07,green:0.18,blue:0.25),Color(red:0.08,green:0.10,blue:0.16)],startPoint:.topLeading,endPoint:.bottomTrailing),in:RoundedRectangle(cornerRadius:18))
        .overlay(RoundedRectangle(cornerRadius:18).stroke(cyan.opacity(0.35),lineWidth:1))
    }

    private func metric(_ title:String,_ value:String,_ detail:String,_ color:Color)->some View {
        VStack(alignment:.leading,spacing:5) {
            Text(title).font(.system(size:10)).foregroundStyle(.white.opacity(0.65))
            Text(value).font(.system(size:13,weight:.semibold,design:.rounded)).monospacedDigit().foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.75)
            Text(detail).font(.system(size:10,design:.rounded)).foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth:.infinity,alignment:.leading)
    }

    private var assetCard: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text("模拟持仓").font(.system(size:15,weight:.semibold)).foregroundStyle(.white)
                Spacer()
                Text("全部  ›").font(.system(size:11)).foregroundStyle(cyan)
            }
            positionRow("螺纹钢","RB2610","3手","+1,260.00","+0.82%",green)
            Divider().overlay(.white.opacity(0.12))
            positionRow("豆粕","M2701","5手","-386.00","-0.43%",red)
            Divider().overlay(.white.opacity(0.12))
            positionRow("沪铜","CU2610","1手","+2,180.00","+1.14%",green)
        }
        .padding(15)
        .background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:18))
        .overlay(RoundedRectangle(cornerRadius:18).stroke(.white.opacity(0.17),lineWidth:1))
    }

    private func positionRow(_ name:String,_ code:String,_ size:String,_ profit:String,_ change:String,_ color:Color)->some View {
        HStack {
            VStack(alignment:.leading,spacing:4) {
                Text(name).font(.system(size:14,weight:.semibold)).foregroundStyle(.white)
                Text(code+" · "+size).font(.system(size:10,design:.rounded)).foregroundStyle(.gray)
            }
            Spacer()
            VStack(alignment:.trailing,spacing:4) {
                Text(profit).font(.system(size:14,weight:.semibold,design:.rounded)).monospacedDigit().foregroundStyle(color)
                Text(change).font(.system(size:10,design:.rounded)).foregroundStyle(color)
            }
        }
    }

    private var quickActions: some View {
        HStack(spacing:10) {
            action("资金明细","list.bullet.rectangle")
            action("交易记录","clock.arrow.circlepath")
            action("风险测评","shield.lefthalf.filled")
            action("模拟设置","slider.horizontal.3")
        }
    }

    private func action(_ title:String,_ symbol:String)->some View {
        VStack(spacing:8) {
            Image(systemName:symbol).font(.system(size:19)).foregroundStyle(cyan)
            Text(title).font(.system(size:10)).foregroundStyle(.white.opacity(0.85))
        }
        .frame(maxWidth:.infinity).frame(height:70)
        .background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:14))
        .overlay(RoundedRectangle(cornerRadius:14).stroke(.white.opacity(0.14),lineWidth:1))
    }

    private var settingsCard: some View {
        VStack(spacing:0) {
            settingRow("行情偏好","红涨绿跌","arrow.left.arrow.right")
            Divider().overlay(.white.opacity(0.12))
            settingRow("图表设置","EMA20 / EMA50","chart.xyaxis.line")
            Divider().overlay(.white.opacity(0.12))
            settingRow("默认周期","15分钟","clock")
            Divider().overlay(.white.opacity(0.12))
            settingRow("数据模式","本地模拟数据","externaldrive")
            Divider().overlay(.white.opacity(0.12))
            settingRow("关于期汇","版本 0.2.0","info.circle")
        }
        .padding(.horizontal,14)
        .background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:18))
        .overlay(RoundedRectangle(cornerRadius:18).stroke(.white.opacity(0.16),lineWidth:1))
    }

    private func settingRow(_ title:String,_ value:String,_ symbol:String)->some View {
        HStack(spacing:10) {
            Image(systemName:symbol).font(.system(size:15)).foregroundStyle(cyan).frame(width:22)
            Text(title).font(.system(size:13)).foregroundStyle(.white)
            Spacer()
            Text(value).font(.system(size:11)).foregroundStyle(.gray)
            Image(systemName:"chevron.right").font(.system(size:10,weight:.semibold)).foregroundStyle(.gray)
        }.padding(.vertical,13)
    }

    private var footer: some View {
        VStack(spacing:5) {
            Text("期汇 · 专注行情与图表").font(.system(size:11,weight:.medium)).foregroundStyle(.gray)
            Text("所有账户、资金及持仓数据均为虚拟演示").font(.system(size:9)).foregroundStyle(.gray.opacity(0.75))
        }.padding(.top,2)
    }
}
