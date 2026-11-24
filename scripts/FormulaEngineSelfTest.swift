import Foundation
@main
struct FormulaEngineSelfTest {
    static func near(_ a: Double?,_ b: Double) {
        precondition(a != nil && abs(a!-b) < 1e-8, "Expected \(b), got \(String(describing:a))")
    }
    static func main() throws {
        let bars = (1...6).map { i -> FormulaBar in
            let x = Double(i)
            return FormulaBar(open:x,high:x+1,low:x-1,close:x,volume:x*10)
        }
        let p = try FormulaProgram("A:=EMA(C,3); B:MA(C,3),COLORBLUE,LINETHICK2; E:A; R:REF(C,1); W:WMA(C,3); X:HHV(H,3)-LLV(L,3);")
        let out = try p.evaluate(bars)
        precondition(out.count == 5 && out[0].name == "B")
        precondition(out[0].values[0] == nil && out[0].values[1] == nil)
        near(out[0].values[2],2); near(out[0].values[5],5)
        precondition(out[0].width == 2 && out[0].color == "4C8DFF")
        near(out[1].values[0],1); near(out[1].values[2],2.25)
        precondition(out[2].values[0] == nil); near(out[2].values[5],5)
        near(out[3].values[2],14.0/6); near(out[3].values[5],32.0/6)
        near(out[4].values[5],4)
        let logic = try FormulaProgram("B:COUNT(C>3,3); R:BARSLAST(C=3); F:IF(C>3,C,0),COLORSTICK; D:C/0; S:SMA(C,3,1);")
        let q = try logic.evaluate(bars)
        near(q[0].values[5],3); precondition(q[1].values[1] == nil); near(q[1].values[5],3)
        near(q[2].values[2],0); near(q[2].values[5],6); precondition(q[2].histogram)
        precondition(q[3].values.allSatisfy { $0 == nil }); near(q[4].values[1],4.0/3)
        for bad in ["A:REF(C,-1);","A:UNKNOWN(C);","A:MA(C,0);","A:=C;","A:UNKNOWN_OI;","C:C;","A:C;A:C;","A:MA(C,1),LINETHICK0;","A:IF(C,1);","A:1 @ 2;"] {
            do { _ = try FormulaProgram(bad); preconditionFailure("accepted \(bad)") }
            catch is FormulaFailure {}
        }
        var changed = bars
        changed[5] = FormulaBar(open:6,high:10,low:5,close:9,volume:60)
        let revised = try p.evaluate(changed)
        for i in out.indices {
            precondition(Array(out[i].values.dropLast()) == Array(revised[i].values.dropLast()))
        }
        let cross = try FormulaProgram("X:CROSS(C,3);")
        let crossed = try cross.evaluate(bars)[0].values
        precondition(crossed[0] == nil); near(crossed[3],1); near(crossed[4],0)
        let nested = try FormulaProgram("P:=(3*C+H+L+O)/6; A:EMA2(P,3); B:WMA(P,3); HULL:HMA(P,4); X:WMA(2*WMA(P,2)-WMA(P,4),2); D:DEMA(P,3); T:TEMA(P,3); DYN:DMA(P,0.5); E:EMA(P,3);")
        let m = try nested.evaluate(bars)
        precondition(m[0].values == m[1].values)
        precondition(m[2].values == m[3].values)
        precondition(m[2].values[3] == nil)
        near(m[2].values[4],5)
        near(m[4].values[1],1.75)
        near(m[5].values[1],1.875)
        precondition(m[6].values == m[7].values)
        let wilder = try FormulaProgram("W:WILDER(C,3);")
        let w = try wilder.evaluate(bars)[0].values
        precondition(w[1] == nil)
        near(w[2],2); near(w[3],8.0/3)
        let prices = [FormulaBar(open:8,high:12,low:6,close:10,volume:100)]
        let priceProgram = try FormulaProgram("P:(3*C+H+L+O)/6; A:HL2; B:HLC3; D:OHLC4; E:HMA(C,1);")
        let v = try priceProgram.evaluate(prices)
        near(v[0].values[0],56.0/6); near(v[1].values[0],9)
        near(v[2].values[0],28.0/3); near(v[3].values[0],9); near(v[4].values[0],10)
        let gaps = try FormulaProgram("A:WMA(IF(C=3,C/0,C),2);")
        let g = try gaps.evaluate(bars)[0].values
        near(g[1],5.0/3); precondition(g[2] == nil && g[3] == nil); near(g[4],14.0/3)
        let dynamic = try FormulaProgram("A:DMA(C,IF(C>3,1,0.5));")
        near(try dynamic.evaluate(bars)[0].values[3],4)
        var line = CompositionLine()
        line.source = .weightedClose
        line.layers = [CompositionLayer(function:.hma,period:4),CompositionLayer(function:.ema,period:3)]
        line.color = .blue
        var second = CompositionLine()
        second.source = .custom
        second.custom = "(O+C)/2"
        second.layers = [CompositionLayer(function:.sma,period:3,weight:1)]
        second.histogram = true
        let composition = FormulaComposition(lines:[line,second])
        let generated = try composition.validatedSource()
        let expected = try FormulaProgram("LINE1:EMA(HMA((3*C+H+L+O)/6,4),3),COLORBLUE,LINETHICK2;LINE2:SMA((O+C)/2,3,1),COLORSTICK;")
        let a = try FormulaProgram(generated).evaluate(bars)
        let b = try expected.evaluate(bars)
        precondition(a.count == b.count)
        precondition(a[0].values == b[0].values && a[1].values == b[1].values)
        precondition(a[1].histogram && a[0].width == 2)
        var definition = FormulaDefinition()
        definition.composition = composition
        definition.source = generated
        let restored = try JSONDecoder().decode(FormulaDefinition.self,from:JSONEncoder().encode(definition))
        precondition(restored == definition)
        let legacy = """
        {"id":"00000000-0000-0000-0000-000000000001","name":"Old","source":"A:C;","overlay":true,"enabled":true}
        """
        let old = try JSONDecoder().decode(FormulaDefinition.self,from:Data(legacy.utf8))
        precondition(old.composition == nil && old.enabled)
        for bad in ["C;X:C", "C),COLORRED", "C,H", "((C)", ""] {
            var invalid = second
            invalid.custom = bad
            do {
                _ = try FormulaComposition(lines:[invalid]).validatedSource()
                preconditionFailure("accepted invalid expression \(bad)")
            } catch is FormulaFailure {}
        }
        let oiBars = [
            FormulaBar(open:1,high:2,low:1,close:2,volume:3,openInterest:100,closeInterest:110),
            FormulaBar(open:2,high:3,low:1,close:2,volume:4),
            FormulaBar(open:2,high:3,low:1,close:2,volume:5,openInterest:110,closeInterest:0)
        ]
        let oi = try FormulaProgram("A:OPI; B:OPEN_OI; D:OI_CHANGE; E:MA(OPI,2);")
        let o = try oi.evaluate(oiBars)
        near(o[0].values[0],110); precondition(o[0].values[1] == nil); near(o[0].values[2],0)
        near(o[1].values[0],100); near(o[2].values[0],10); near(o[2].values[2],-110)
        precondition(o[3].values.allSatisfy { $0 == nil })
        print("Formula engine: composition, persistence, nesting, numeric fixtures, open interest and validation passed")
    }
}
