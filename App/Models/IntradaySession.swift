import Foundation

/// Uses observed minute bars and the TqSdk example's Shanghai evening /
    /// weekend rollover. Exchange holiday calendar is not available in the
    /// current gateway, so never infer or fabricate unobserved minutes.
enum IntradaySession {
    private static var calendar:Calendar {
        var c = Calendar(identifier:.gregorian)
        c.timeZone = TimeZone(identifier:"Asia/Shanghai")!
        return c
    }
    static func day(_ time:Int64)->Date {
        let c = calendar, date = Date(timeIntervalSince1970:Double(time))
        var day = c.startOfDay(for:date)
        if c.component(.hour,from:date) >= 18 { day = c.date(byAdding:.day,value:1,to:day)! }
        while [1,7].contains(c.component(.weekday,from:day)) { day = c.date(byAdding:.day,value:1,to:day)! }
        return day
    }
    static func merge(existing:[MarketBar],incoming:[MarketBar],preserve:Set<Int64> = []) -> [MarketBar] {
        var index = Dictionary(existing.map{($0.time,$0)},uniquingKeysWith:{_,new in new})
        for bar in incoming where bar.time > 0 && bar.close.isFinite && bar.close > 0 && !preserve.contains(bar.time) {
            index[bar.time] = bar
        }
        return Array(index.values.sorted{$0.time < $1.time}.suffix(1000))
    }
    static func latest(_ bars:[MarketBar])->[MarketBar] {
        guard let last = bars.last else { return [] }
        let key = day(last.time)
        return Array(bars.reversed().prefix{day($0.time) == key}.reversed())
    }
    /// Kline close * volume is an approximation, not exchange turnover VWAP.
    static func averages(_ bars:[MarketBar])->[Double?] {
        var turnover = 0.0, volume = 0.0
        return bars.map { bar in
            if bar.volume > 0,bar.close.isFinite {
                turnover += bar.close*Double(bar.volume); volume += Double(bar.volume)
            }
            return volume > 0 ? turnover/volume : nil
        }
    }
    static func label(_ time:Int64,format:String)->String {
        let f = DateFormatter(); f.timeZone = calendar.timeZone; f.dateFormat = format
        return f.string(from:Date(timeIntervalSince1970:Double(time)))
    }
}
