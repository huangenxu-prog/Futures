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
        let drawing = try FormulaProgram("STICKLINE(C>3,L,H,5,1),COLORRED; DRAWICON(CROSS(C,3),L,1); DRAWTEXT(C=3,H,'Buy买'),COLORBLUE; A:IF(C>3,C,DRAWNULL);")
        let drawn = try drawing.evaluate(bars)
        precondition(drawn.count == 4)
        if case .stick(let starts,let width,let hollow)? = drawn[0].drawing {
            precondition(width == 5 && hollow)
            precondition(starts[2] == nil)
            near(starts[3],3); near(drawn[0].values[3],5)
        } else { preconditionFailure("missing stick") }
        if case .signal(let text)? = drawn[1].drawing {
            precondition(text == "↑"); near(drawn[1].values[3],3)
            precondition(drawn[1].values[4] == nil)
        } else { preconditionFailure("missing icon") }
        if case .signal(let text)? = drawn[2].drawing {
            precondition(text == "Buy买"); near(drawn[2].values[2],4)
        } else { preconditionFailure("missing text") }
        precondition(drawn[3].values[2] == nil); near(drawn[3].values[3],4)
        for bad in ["DRAWICON(C,L,9);","DRAWTEXT(C,H,3);","STICKLINE(C,O,C,20,0);","STICKLINE(C,O,C,5,2);","A:'text';","DRAWTEXT(C,H,'abc);","A:STICKLINE(C,O,C,5,0);"] {
            do { _ = try FormulaProgram(bad); preconditionFailure("accepted \(bad)") }
            catch is FormulaFailure {}
        }
        let before = try drawing.evaluate(bars)
        let after = try drawing.evaluate(changed)
        for i in before.indices {
            precondition(Array(before[i].values.dropLast()) == Array(after[i].values.dropLast()))
        }
        let state = try FormulaProgram("A:VALUEWHEN(C=2 OR C=5,C); B:FILTER(C>1,2); D:HHVBARS(H,3); E:LLVBARS(L,3); F:EXIST(C>3,3); G:EVERY(C>3,3); I:REF(C,BARSLAST(C=2)); J:BARSCOUNT(C);")
        let states = try state.evaluate(bars)
        precondition(states[0].values[0] == nil); near(states[0].values[3],2); near(states[0].values[4],5)
        precondition(states[1].values == [0,1,0,0,1,0])
        near(states[2].values[5],0); near(states[3].values[5],2)
        near(states[4].values[3],1); near(states[5].values[3],0); near(states[5].values[5],1)
        precondition(states[6].values[0] == nil); near(states[6].values[5],2)
        near(states[7].values[5],6)
        let pairs = try FormulaProgram("DRAWLINE(C=1 OR C=2,L,C=4,H,0),COLORBLUE,LINETHICK2;")
        let paired = try pairs.evaluate(bars)
        if case .segments(let segments)? = paired[0].drawing {
            precondition(segments == [FormulaSegment(startIndex:1,endIndex:3,startValue:1,endValue:5)])
        } else { preconditionFailure("missing line segment") }
        let prefix = try pairs.evaluate(Array(bars.prefix(3)))
        if case .segments(let segments)? = prefix[0].drawing {
            precondition(segments.isEmpty)
        } else { preconditionFailure("missing pending line segment") }
        for bad in ["DRAWLINE(C,L,C,H,1);","A:REF(C,-1);","A:REF(C,20001);","A:FILTER(C,-1);"] {
            do { _ = try FormulaProgram(bad); preconditionFailure("accepted \(bad)") }
            catch is FormulaFailure {}
        }
        precondition(MovingAverageType.allCases.count == 10)
        let legacyAverage = """
        {"id":"00000000-0000-0000-0000-000000000001","type":"SMA","period":20,"enabled":true}
        """
        let simple = try JSONDecoder().decode(AdditionalMovingAverage.self,from:Data(legacyAverage.utf8))
        precondition(simple.type == .sma && simple.label == "MA20" && simple.key == "SMA:20")
        for type in MovingAverageType.allCases {
            var average = AdditionalMovingAverage(type:type,period:4)
            average.smoothingWeight = 2
            average.dynamicAlpha = 0.5
            let source = try average.expression()
            let values = try FormulaProgram("A:"+source+";").evaluate(bars)
            precondition(values.count == 1 && values[0].values.count == bars.count)
            let restoredAverage = try JSONDecoder().decode(AdditionalMovingAverage.self,from:JSONEncoder().encode(average))
            precondition(restoredAverage == average)
        }
        precondition(AdditionalMovingAverage(type:.ema2,period:20).key == AdditionalMovingAverage(type:.wma,period:20).key)
        var weighted = AdditionalMovingAverage(type:.smoothSMA,period:3)
        weighted.smoothingWeight = 4
        precondition(!weighted.isValid)
        var dmaAverage = AdditionalMovingAverage(type:.dma,period:20)
        dmaAverage.dynamicAlpha = 1.1
        precondition(!dmaAverage.isValid)
        var previewLine = CompositionLine()
        previewLine.layers = [CompositionLayer(function:.ema,period:20),CompositionLayer(function:.ema,period:50)]
        let expression = try previewLine.calculationExpression()
        let statement = try previewLine.statement(index:1)
        precondition(statement.hasPrefix("LINE1:"+expression+","))
        let previewValues = try FormulaProgram("A:"+expression+";").evaluate(bars)
        let savedValues = try FormulaProgram(statement).evaluate(bars)
        precondition(previewValues[0].values == savedValues[0].values)
        var namedLine = previewLine
        namedLine.name = "趋势线"
        var namedSecond = CompositionLine()
        namedSecond.name = "fast20"
        let namedComposition = FormulaComposition(lines:[namedLine,namedSecond])
        let namedSource = try namedComposition.validatedSource()
        precondition(namedSource.hasPrefix("趋势线:") && namedSource.contains("FAST20:"))
        let namedOutputs = try FormulaProgram(namedSource).evaluate(bars)
        precondition(namedOutputs[0].name == "趋势线" && namedOutputs[1].name == "FAST20")
        precondition(namedOutputs[0].values == savedValues[0].values)
        let namedRestored = try JSONDecoder().decode(FormulaComposition.self,from:JSONEncoder().encode(namedComposition))
        precondition(namedRestored == namedComposition)
        let oldLine = try JSONDecoder().decode(CompositionLine.self,from:JSONEncoder().encode(previewLine))
        precondition(oldLine.name == nil && oldLine.outputName(index:2) == "LINE2")
        for badName in ["C","2趋势","快 线","A;B","AND","快线:","😀"] {
            var bad = namedLine
            bad.name = badName
            do {
                _ = try FormulaComposition(lines:[bad]).validatedSource()
                preconditionFailure("accepted invalid curve name \(badName)")
            } catch is FormulaFailure {}
        }
        do {
            _ = try FormulaComposition(lines:[namedLine,namedLine]).validatedSource()
            preconditionFailure("accepted duplicate curve names")
        } catch is FormulaFailure {}
        let references = try FormulaProgram("快线:EMA(C,2); 慢线:EMA(快线,3);").evaluate(bars)
        precondition(references.count == 2 && references[1].name == "慢线")
        let compatible = try FormulaProgram("""
        SHORT: = 2; // period
        A:EMA(C,SHORT),COLORFF8D1E;
        N:=BARSLAST(C=2)+1;
        B:HHV(H,N);
        D:LLV(L,N);
        X:CROSSUP(C,3)&&RANGE(C,2,5);
        Y:IFN(C>3,1,0);
        HIDDEN:C,NODRAW;
        { ignored comment }
        DRAWTEXT(C>3,H,'☼'),FONTSIZE18,COLOR00FF00;
        STICKLINE(C>3,0,C,1,0),COLOR0000CC;
        """).evaluate(bars)
        precondition(compatible.count == 8 && compatible[0].color == "FF8D1E")
        near(compatible[1].values[5],7); near(compatible[2].values[5],1)
        near(compatible[3].values[3],1); near(compatible[4].values[5],1)
        precondition(compatible[5].legendOnly && compatible[5].name == "HIDDEN")
        precondition(compatible[6].fontSize == 18 && compatible[7].color == "0000CC")
        let styles = try FormulaProgram("X:IFELSE(ISUP,C,O),COLORFF00FF,LINETHICK1,DOT; Y:IF(ISDOWN,1,ISEQUAL),DASHLINE; Z:C,NODRAW;").evaluate(bars)
        precondition(styles[0].dash == [1,3] && styles[0].width == 1 && styles[0].color == "FF00FF")
        precondition(styles[1].dash == [5,3] && styles[2].legendOnly)
        let candleStates = try FormulaProgram("U:ISUP;D:ISDOWN;E:ISEQUAL;").evaluate([
            FormulaBar(open:1,high:2,low:1,close:2,volume:nil),
            FormulaBar(open:2,high:2,low:1,close:1,volume:nil),
            FormulaBar(open:1,high:1,low:1,close:1,volume:nil)])
        precondition(candleStates[0].values == [1,0,0] && candleStates[1].values == [0,1,0] && candleStates[2].values == [0,0,1])
        precondition(FormulaDefinition().source.isEmpty)
        for (source, expected) in [("甲:C;\n乙:EMAA(C,20);","EMAA"),("甲:C;\n乙:未知;","未知"),("甲:C,COLORNOPE;","COLORNOPE")] {
            do { _ = try FormulaProgram(source); preconditionFailure("expected failure") }
            catch let failure as FormulaFailure {
                guard let range = failure.range else { preconditionFailure("missing error range") }
                precondition((source as NSString).substring(with:range) == expected)
            }
        }
        let layers = (0..<20).map { _ in "STICKLINE(C>0,0,C,1,0),COLORFF0000;" }.joined()
        let layered = try FormulaProgram(layers).evaluate(bars)
        precondition(layered.count == 20)
        let dynamicCounts = try FormulaProgram("N:=BARSLAST(C=2)+1; A:COUNT(C>3,N); B:EXIST(C>3,N); D:EVERY(C>3,N); E:COUNT(C>3,C);").evaluate(bars)
        precondition(dynamicCounts[0].values == [nil,0,0,1,2,3])
        precondition(dynamicCounts[1].values == [nil,0,0,1,1,1])
        precondition(dynamicCounts[2].values == [nil,0,0,0,0,0])
        precondition(dynamicCounts[3].values == [0,0,0,1,2,3])
        let invalidWindows = try FormulaProgram("A:COUNT(C>0,C-2); B:COUNT(C>0,C+1); D:COUNT(C>0,C/2); E:COUNT(IF(C=3,DRAWNULL,1),C);").evaluate(bars)
        precondition(invalidWindows[0].values[0] == nil && invalidWindows[0].values[1] == nil)
        near(invalidWindows[0].values[2],1)
        precondition(invalidWindows[1].values.allSatisfy{$0 == nil})
        precondition(invalidWindows[2].values[0] == nil && invalidWindows[2].values[2] == nil)
        near(invalidWindows[2].values[3],2)
        precondition(invalidWindows[3].values[2] == nil && invalidWindows[3].values[5] == nil)
        let trend = try FormulaProgram("""
        N:=10;
        M:=3.5;
        TR1:=MAX(MAX(H-L,ABS(REF(C,1)-H)),ABS(REF(C,1)-L));
        UP:=(H+L)/2+MA(TR1,N)*M;
        DN:=(H+L)/2-MA(TR1,N)*M;
        DR:=REF(UP,BARSLAST(UP<=REF(UP,1)));
        VF:=LLV(UP,N*1.5);
        AR:=IF(VF<>REF(VF,1) AND DR<REF(DR,1),DR,IF(DR=VF,DR,VF));
        Z1:=BARSLAST(CROSS(0.5,UP=AR))+1;
        Z2:=CROSS(COUNT((CROSS(C,AR) OR CROSS(C,REF(AR,2))) AND UP>AR,Z1),0.5);
        YX6:=BARSLAST(Z2);
        D6:=BARSLAST(CROSS(HHV(DN,YX6+1),C));
        BY:=CROSS(D6,YX6);
        SL:=CROSS(YX6,D6);
        ST:=IF(D6>YX6,HHV(DN,BARSLAST(BY)+1),LLV(UP,BARSLAST(SL)+1));
        支撑线:IF(D6<=YX6,ST,DRAWNULL),COLOR23C6C8,LINETHICK2;
        阻力线:IF(D6>YX6,ST,DRAWNULL),COLORFF4545,LINETHICK2;
        """)
        let oscillating = (0..<500).map { i -> FormulaBar in
            let c=100+sin(Double(i)/9)*20+Double(i)/20
            return FormulaBar(open:c,high:c+2,low:c-2,close:c,volume:100)
        }
        let fullTrend = try trend.evaluate(oscillating)
        let prefixTrend = try trend.evaluate(Array(oscillating.prefix(350)))
        precondition(fullTrend.count == 2 && prefixTrend.count == 2)
        for i in fullTrend.indices {
            precondition(Array(fullTrend[i].values.prefix(350)) == prefixTrend[i].values)
        }
        let recursive = try FormulaProgram("A:IF(BARSCOUNT(C)=1,C,REF(A,1)+C); B:IF(BARSCOUNT(C)<=2,C,REF(B,2)+C); D:IF(C=1,C,REF(D,1)*0.9+C*0.1);").evaluate(bars)
        precondition(recursive[0].values == [1,3,6,10,15,21])
        precondition(recursive[1].values == [1,2,4,6,9,12])
        near(recursive[2].values[1],1.1)
        let held = try FormulaProgram("A:IF(C<=2,C,REF(A,1));").evaluate(bars)
        precondition(held[0].values == [1,2,2,2,2,2])
        let recursivePrefix = try FormulaProgram("A:IF(BARSCOUNT(C)=1,C,REF(A,1)+C);").evaluate(Array(bars.prefix(4)))
        precondition(recursivePrefix[0].values == Array(recursive[0].values.prefix(4)))
        for bad in ["A:A+1;","A:REF(A,0);","A:REF(A,-1);","A:REF(A,A);","A:EMA(REF(A,1),3);"] {
            do { _ = try FormulaProgram(bad); preconditionFailure("accepted invalid recursive formula") }
            catch is FormulaFailure {}
        }
        print("Formula engine: causal state, dynamic references, confirmed segments and previous fixtures passed")
    }
}
