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
                        Image(systemName: items[index].1).font(.system(size: 22, weight: .medium))
                        Text(items[index].0).font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(selection == index ? Color.cyan : .white)
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
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
        let all = FuturesInstrument.samples
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if keyword.isEmpty { return Array(all.prefix(4)) }
        return all.filter {
            $0.name.localizedCaseInsensitiveContains(keyword) ||
            $0.id.localizedCaseInsensitiveContains(keyword) ||
            $0.exchange.localizedCaseInsensitiveContains(keyword)
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
            .toolbar(.hidden, for: .navigationBar)
        }
        .tint(.white)
        .preferredColorScheme(.dark)
    }
}

private struct ProfileView: View {
    private let blue = Color(red:0.28,green:0.55,blue:1.0)
    private let green = Color(red:0.15,green:0.78,blue:0.48)
    private let red = Color(red:0.15,green:0.78,blue:0.48)

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators:false) {
                VStack(spacing:0) {
                    accountHeader
                    capitalPanel
                    tradingActions
                    functionGrid
                    disclaimer
                }
                .padding(.horizontal,14)
                .padding(.top,8)
                .padding(.bottom,24)
            }
            .background(Color(red:0.07,green:0.07,blue:0.07).ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    private var accountHeader: some View {
        HStack(spacing:12) {
            ZStack {
                Circle().fill(Color.white).frame(width:48,height:48)
                Image(systemName:"building.columns.fill").font(.system(size:22,weight:.medium)).foregroundStyle(blue)
            }
            VStack(alignment:.leading,spacing:4) {
                Text("国元期货 · CTP主席").font(.system(size:16,weight:.semibold)).foregroundStyle(.white)
                Text("交易账号  ****7870").font(.system(size:12)).foregroundStyle(.gray)
            }
            Spacer()
            Menu {
                Button("模拟账户  ****7870", action: {})
                Button("添加模拟账户", action: {})
            } label: {
                HStack(spacing:4) {
                    Text("切换账户").font(.system(size:12))
                    Image(systemName:"chevron.down").font(.system(size:10))
                }.foregroundStyle(.gray)
            }
        }
        .padding(.vertical,15)
        .overlay(alignment:.bottom) { Rectangle().fill(.white.opacity(0.12)).frame(height:0.5) }
    }

    private var capitalPanel: some View {
        VStack(spacing:18) {
            HStack(spacing:0) {
                capitalMetric("市值权益","128,650.80",nil,.white)
                capitalMetric("逐笔盈亏","+2,386.40","+1.89%",green)
            }
            HStack(spacing:0) {
                NavigationLink { SilverTransferView() } label: {
                    VStack(alignment:.leading,spacing:7) {
                        HStack(spacing:5) {
                            Text("可用资金").font(.system(size:12)).foregroundStyle(.gray)
                            Text("转账 ›").font(.system(size:10)).foregroundStyle(blue).padding(.horizontal,6).padding(.vertical,2).overlay(Rectangle().stroke(blue.opacity(0.8), lineWidth: 1))
                        }
                        Text("96,320.80").font(.system(size:23,weight:.medium,design:.rounded)).monospacedDigit().foregroundStyle(.white)
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }.buttonStyle(.plain)
                capitalMetric("资金使用率","25.12%",nil,.white)
            }
        }
        .padding(.vertical,18)
        .overlay(alignment:.bottom) { Rectangle().fill(.white.opacity(0.12)).frame(height:0.5) }
    }

    private func capitalMetric(_ title:String,_ value:String,_ detail:String?,_ color:Color)->some View {
        VStack(alignment:.leading,spacing:7) {
            Text(title).font(.system(size:12)).foregroundStyle(.gray)
            Text(value).font(.system(size:23,weight:.medium,design:.rounded)).monospacedDigit().foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.75)
            if let detail {
                Text(detail).font(.system(size:11,weight:.medium,design:.rounded)).foregroundStyle(color)
            }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }

    private var tradingActions: some View {
        HStack(spacing:0) {
            tradeAction("下单","arrow.left.arrow.right",blue)
            tradeAction("撤单/改价","doc.text",Color(red:1,green:0.40,blue:0.32))
            tradeAction("当日委托","list.bullet.rectangle.fill",Color.orange)
            tradeAction("当日成交","checkmark.shield.fill",Color.orange)
        }
        .padding(.top,17)
        .padding(.bottom,18)
        .overlay(alignment:.bottom) { Rectangle().fill(.white.opacity(0.12)).frame(height:7).padding(.horizontal,-14) }
    }

    private func tradeAction(_ title:String,_ symbol:String,_ tint:Color)->some View {
        VStack(spacing:8) {
            Image(systemName:symbol).font(.system(size:21,weight:.semibold)).foregroundStyle(.white)
                .frame(width:48,height:48)
                .background(LinearGradient(colors:[tint,tint.opacity(0.72)],startPoint:.topLeading,endPoint:.bottomTrailing),in:Circle())
            Text(title).font(.system(size:12)).foregroundStyle(.white.opacity(0.85))
        }.frame(maxWidth:.infinity)
    }

    private var functionGrid: some View {
        LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],alignment:.leading,spacing:0) {
            NavigationLink { SilverTransferView() } label: {
                functionItem("银期转账","银行转钱到期货账户","yensign.circle")
            }.buttonStyle(.plain)
            functionItem("交易设置","交易个性化设置","gearshape")
            functionItem("资金明细","查看资金变动记录","chart.xyaxis.line")
            functionItem("账单查询","查看当日 / 月结算单","doc.text")
            functionItem("风险测评","风险承受能力评估","shield.lefthalf.filled")
            functionItem("模拟账户管理","账户与演示数据设置","person.crop.rectangle.stack")
        }
        .padding(.top,12)
    }

    private func functionItem(_ title:String,_ subtitle:String,_ symbol:String)->some View {
        HStack(spacing:11) {
            Image(systemName:symbol).font(.system(size:23,weight:.regular)).foregroundStyle(blue).frame(width:32)
            VStack(alignment:.leading,spacing:5) {
                Text(title).font(.system(size:14,weight:.medium)).foregroundStyle(.white.opacity(0.9))
                Text(subtitle).font(.system(size:11)).foregroundStyle(.gray)
            }
            Spacer(minLength:0)
            Image(systemName:"chevron.right").font(.system(size:9,weight:.semibold)).foregroundStyle(.gray.opacity(0.7))
        }
        .padding(.vertical,17)
        .padding(.horizontal,5)
        .frame(maxWidth:.infinity,alignment:.leading)
    }

    private var disclaimer: some View {
        Text("演示账户 · 所有资金、盈亏及交易数据均为虚拟数据，不代表真实账户")
            .font(.system(size:10)).foregroundStyle(.gray).multilineTextAlignment(.center)
            .padding(.top,15)
    }
}

private struct SilverTransferView: View {
    @State private var direction = 0
    @State private var amount = ""
    @State private var showResult = false
    private let blue = Color(red:0.28,green:0.55,blue:1.0)

    var body: some View {
        ScrollView {
            VStack(spacing:18) {
                HStack(spacing:0) {
                    directionButton("银行转期货",index:0)
                    directionButton("期货转银行",index:1)
                }
                .padding(5)
                .background(Color.white.opacity(0.07),in:RoundedRectangle(cornerRadius:12))

                VStack(spacing:0) {
                    balanceRow("银行账户余额","¥ 32,580.00")
                    Divider().overlay(.white.opacity(0.12))
                    balanceRow("期货可用资金","¥ 96,320.80")
                    Divider().overlay(.white.opacity(0.12))
                    balanceRow("期货可取资金","¥ 86,320.80")
                }
                .padding(15)
                .background(Color.white.opacity(0.06),in:RoundedRectangle(cornerRadius:14))

                VStack(alignment:.leading,spacing:12) {
                    Text("转账金额").font(.system(size:13)).foregroundStyle(.gray)
                    HStack(alignment:.firstTextBaseline,spacing:8) {
                        Text("¥").font(.system(size:22,weight:.medium)).foregroundStyle(.white)
                        TextField("请输入转账金额",text:$amount).keyboardType(.decimalPad).font(.system(size:28,weight:.medium,design:.rounded)).foregroundStyle(.white)
                    }
                    Divider().overlay(.white.opacity(0.2))
                    HStack {
                        Text("单笔限额以银行及期货公司规定为准").font(.system(size:10)).foregroundStyle(.gray)
                        Spacer()
                        Button("全部转入") { amount = direction == 0 ? "32580.00" : "86320.80" }
                            .font(.system(size:11)).foregroundStyle(blue)
                    }
                }
                .padding(16)
                .background(Color.white.opacity(0.06),in:RoundedRectangle(cornerRadius:14))

                VStack(alignment:.leading,spacing:10) {
                    Text("签约银行卡").font(.system(size:13)).foregroundStyle(.gray)
                    HStack {
                        Image(systemName:"creditcard.fill").font(.system(size:22)).foregroundStyle(blue)
                        VStack(alignment:.leading,spacing:4) {
                            Text("中国建设银行").font(.system(size:14,weight:.medium)).foregroundStyle(.white)
                            Text("储蓄卡  ****  6288").font(.system(size:11)).foregroundStyle(.gray)
                        }
                        Spacer()
                        Text("已签约").font(.system(size:11)).foregroundStyle(Color.green)
                    }
                }
                .padding(16)
                .background(Color.white.opacity(0.06),in:RoundedRectangle(cornerRadius:14))

                Button {
                    showResult = true
                } label: {
                    Text("确认转账").font(.system(size:16,weight:.semibold)).foregroundStyle(.white)
                        .frame(maxWidth:.infinity).padding(.vertical,15)
                        .background(blue,in:RoundedRectangle(cornerRadius:12))
                }
                .alert("模拟转账",isPresented:$showResult) {
                    Button("知道了",role:.cancel) {}
                } message: {
                    Text("当前为演示账户，未连接银行或期货公司，未发生真实资金划转。")
                }

                Text("银期转账仅支持交易所及银行规定的转账时段。当前页面为交互演示，不连接真实账户。")
                    .font(.system(size:10)).foregroundStyle(.gray).multilineTextAlignment(.center)
            }
            .padding(16)
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("银期转账")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark,for:.navigationBar)
    }

    private func directionButton(_ title:String,index:Int)->some View {
        Button { direction = index; amount = "" } label: {
            Text(title).font(.system(size:13,weight:.medium))
                .foregroundStyle(direction == index ? .white : .gray)
                .frame(maxWidth:.infinity).padding(.vertical,11)
                .background(direction == index ? blue : .clear,in:RoundedRectangle(cornerRadius:9))
        }.buttonStyle(.plain)
    }

    private func balanceRow(_ title:String,_ value:String)->some View {
        HStack {
            Text(title).font(.system(size:12)).foregroundStyle(.gray)
            Spacer()
            Text(value).font(.system(size:14,weight:.medium,design:.rounded)).foregroundStyle(.white)
        }.padding(.vertical,10)
    }
}
