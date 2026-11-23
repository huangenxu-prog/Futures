import SwiftUI

struct OptionChainView: View {
    let code: String
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [MarketDataService.OptionQuote] = []
    @State private var side = "CALL"
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            VStack {
                Picker("期权方向", selection: $side) {
                    Text("看涨").tag("CALL")
                    Text("看跌").tag("PUT")
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                if loading {
                    ProgressView().frame(maxHeight: .infinity)
                } else if let error {
                    VStack { Text(error); Button("重试") { Task { await load() } } }
                        .frame(maxHeight: .infinity)
                } else if rows.filter({ $0.side == side }).isEmpty {
                    Text("暂无该方向的挂牌期权").frame(maxHeight: .infinity)
                } else {
                    List(rows.filter { $0.side == side }) { option in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("行权价 " + option.strike.formatted())
                                Spacer()
                                Text("最新 " + (option.last?.formatted() ?? "--"))
                            }
                            Text(option.code).foregroundStyle(.secondary)
                            HStack {
                                Text("买1")
                                Text(option.bid?.formatted() ?? "--")
                                Text("卖1")
                                Text(option.ask?.formatted() ?? "--")
                            }
                        }
                        .font(.caption.monospacedDigit())
                    }
                    .listStyle(.plain)
                    .refreshable { await load() }
                }
            }
            .navigationTitle(code + " 期权")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { dismiss() } }
            .task(id: code) { await load() }
        }
    }

    @MainActor private func load() async {
        loading = rows.isEmpty
        defer { loading = false }
        do {
            rows = try await MarketDataService.options(for: code)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
