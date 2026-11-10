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
    var body: some View {
        NavigationStack {
            List {
                Section("期汇") {
                    LabeledContent("版本", value: "0.2.0")
                    LabeledContent("行情模式", value: "本地演示")
                }
                Section { Text("当前版本不连接真实期货账户，不发送交易指令。").foregroundStyle(.secondary) }
            }.scrollContentBackground(.hidden).background(Color.black).navigationTitle("我的")
        }.preferredColorScheme(.dark)
    }
}
