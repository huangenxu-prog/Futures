import Foundation

@main
struct FuturesIndicatorSelfTest {
    static func near(_ a: Double?, _ b: Double) {
        precondition(a != nil && abs(a!-b) < 1e-9, "expected \(b), got \(String(describing:a))")
    }
    static func main() {
        typealias Bar = FuturesIndicatorMath.OHLC
        let bars = [Bar(high:11,low:9,close:10),Bar(high:13,low:11,close:12),Bar(high:14,low:12,close:13)]
        let atr = FuturesIndicatorMath.atr(bars,period:2)
        precondition(atr[0] == nil); near(atr[1],2.5); near(atr[2],2.25)
        let kdj = FuturesIndicatorMath.kdj(bars,period:2,kPeriod:3,dPeriod:3)
        precondition(kdj.k[0] == nil)
        near(kdj.k[1],50+25.0/3); near(kdj.d[1],50+25.0/9)
        near(kdj.j[1],3*(50+25.0/3)-2*(50+25.0/9))
        let flat = Array(repeating: Bar(high:10,low:10,close:10), count: 20)
        near(FuturesIndicatorMath.kdj(flat,period:9,kPeriod:3,dPeriod:3).j.last!,50)
        near(FuturesIndicatorMath.atr(flat,period:14).last!,0)
        let sar = FuturesIndicatorMath.sar(bars,step:0.02,maximum:0.2)
        precondition(sar[0] == nil); near(sar[1],9); near(sar[2],9)
        let reverse = bars + [Bar(high:10,low:7,close:8)]
        near(FuturesIndicatorMath.sar(reverse,step:0.02,maximum:0.2).last!,14)
        // Replacing the unfinished bar must not change earlier outputs.
        var changed = bars; changed[2] = Bar(high:16,low:12,close:15)
        let a = FuturesIndicatorMath.kdj(changed,period:2,kPeriod:3,dPeriod:3)
        precondition(Array(a.k.dropLast()) == Array(kdj.k.dropLast()))
        precondition(a.k.last! != kdj.k.last!)
        let long = (0..<9000).map { i in Bar(high: Double(100+i%11),low:Double(90+i%11),close:Double(95+i%11)) }
        let out = FuturesIndicatorMath.kdj(long,period:500,kPeriod:3,dPeriod:3)
        precondition(out.j.compactMap{$0}.count == 8501)
        precondition(out.j.compactMap{$0}.allSatisfy{$0.isFinite})
        print("KDJ, ATR, SAR: numerical fixtures, warm-up, reversal and live replacement passed")
    }
}
