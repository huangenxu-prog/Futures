import Foundation
@main
struct IntradaySessionSelfTest {
    static func main() {
        let f = DateFormatter(); f.timeZone = TimeZone(identifier:"Asia/Shanghai")!; f.dateFormat = "yyyy-MM-dd HH:mm"
        func timestamp(_ s:String)->Int64 { Int64(f.date(from:s)!.timeIntervalSince1970) }
        func bar(_ s:String,_ close:Double,_ volume:Int64)->MarketBar {
            MarketBar(time:timestamp(s),open:close,high:close,low:close,close:close,preSettlement:nil,volume:volume)
        }
        // Friday night and Saturday after midnight belong to Monday's
        // observed session, not Friday daytime. No synthetic weekend bars.
        let fri = bar("2026-11-20 14:59",90,1)
        let night = bar("2026-11-20 21:00",100,2)
        let early = bar("2026-11-21 00:01",110,3)
        let monday = bar("2026-11-23 09:00",120,5)
        precondition(IntradaySession.latest([fri,night,early,monday]) == [night,early,monday])
        precondition(IntradaySession.averages([night,early,monday]) == [100,106,113])
        let live = bar("2026-11-23 09:00",121,7)
        let merged = IntradaySession.merge(existing:[night,live],incoming:[fri,early,monday],preserve:[live.time])
        precondition(merged == [fri,night,early,live])
        let replaced = IntradaySession.merge(existing:merged,incoming:[monday])
        precondition(replaced.last == monday)
        let next = bar("2026-11-23 21:00",130,0)
        precondition(IntradaySession.latest(merged+[next]) == [next])
        precondition(IntradaySession.averages([next]) == [nil])
        print("Intraday rollover, volume-weighted approximation, and live precedence passed")
    }
}
