import SwiftUI

@main
struct QihuiappApp: App {
    var body: some Scene {
        WindowGroup {
            #if QIHUI_LIVE_PROBE
            LiveCandleProbeView()
            #elseif DEBUG
            if ProcessInfo.processInfo.arguments.contains("-qihui-chart-replay") {
                ChartReplayView()
            } else if ProcessInfo.processInfo.arguments.contains("-detail-pager-ui-test") {
                DetailPagerFixture()
            } else {
                ContentView()
            }
            #else
            ContentView()
            #endif
        }
    }
}
