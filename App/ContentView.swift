import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            MarketHomeView()
                .tabItem {
                    Label("行情", systemImage: "chart.xyaxis.line")
                }

            WatchlistView()
                .tabItem {
                    Label("自选", systemImage: "star")
                }

            AccountPlaceholderView()
                .tabItem {
                    Label("账户", systemImage: "person.crop.circle")
                }

            SettingsPlaceholderView()
                .tabItem {
                    Label("设置", systemImage: "gearshape")
                }
        }
        .tint(Color.accentColor)
    }
}

private struct AccountPlaceholderView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "账户模块",
                systemImage: "person.crop.circle",
                description: Text("后续接入模拟账户与资金、持仓信息。")
            )
            .navigationTitle("账户")
        }
    }
}

private struct SettingsPlaceholderView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("应用") {
                    LabeledContent("版本", value: "0.1.0")
                    LabeledContent("数据模式", value: "本地模拟数据")
                }
                Section {
                    Text("当前版本不连接真实期货账户，也不会发送交易指令。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
        }
    }
}
