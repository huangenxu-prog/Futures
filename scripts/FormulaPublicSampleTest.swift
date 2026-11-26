import Foundation

// Reads public example blocks on stdin. Only the indicator parser handles their contents.
@main
struct FormulaPublicSampleTest {
    struct Sample: Decodable { let id, source: String }
    struct Result: Encodable { let id: String; let error: String? }
    static func main() throws {
        let bars = (0..<128).map { i -> FormulaBar in
            let c = Double(100+i%9-i%7), o = c+Double(i%3-1)
            return FormulaBar(open:o,high:max(o,c)+1,low:min(o,c)-1,close:c,volume:Double(30+i%5))
        }
        let cases = try JSONDecoder().decode([Sample].self,from:FileHandle.standardInput.readDataToEndOfFile())
        let results = try cases.map { sample -> Result in
            do {
                let program = try FormulaProgram(sample.source,platform:.wenhua)
                let all = try program.evaluate(bars)
                let prefix = try program.evaluate(Array(bars.prefix(64)))
                precondition(all.count == prefix.count)
                for (a,b) in zip(all,prefix) {
                    precondition(Array(a.values.prefix(64)) == b.values,sample.id)
                }
                return Result(id:sample.id,error:nil)
            } catch let error as FormulaFailure {
                return Result(id:sample.id,error:error.message)
            }
        }
        FileHandle.standardOutput.write(try JSONEncoder().encode(results))
    }
}
