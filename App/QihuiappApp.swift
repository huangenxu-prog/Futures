import SwiftUI

@main
struct QihuiappApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-qihui-chart-replay") {
                ChartReplayView()
            } else {
                ContentView()
            }
            #else
            ContentView()
            #endif
        }
    }
}
