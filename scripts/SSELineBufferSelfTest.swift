import Foundation

@main
struct SSELineBufferSelfTest {
    static func main() {
        var buffer = SSELineBuffer()
        precondition(buffer.append(Data(": connected\n\nda".utf8)).isEmpty)
        precondition(buffer.append(Data("ta: {\"a\":".utf8)).isEmpty)
        let first = buffer.append(Data("1}\n\n: heartbeat\r\n\r\ndata: {\"a\":2}\r\n".utf8))
        precondition(first.map { String(decoding: $0, as: UTF8.self) } == ["{\"a\":1}", "{\"a\":2}"])
        let bytes = Array("data: {\"name\":\"棉花\"}\n\n".utf8)
        var delivered: [Data] = []
        for byte in bytes { delivered += buffer.append(Data([byte])) }
        precondition(delivered.count == 1)
        precondition(String(decoding: delivered[0], as: UTF8.self) == "{\"name\":\"棉花\"}")
        print("SSE fragmented and combined transport chunks: OK")
    }
}
