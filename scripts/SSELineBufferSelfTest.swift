import Foundation

@main
struct SSELineBufferSelfTest {
    static func main() {
        struct Tick: Codable, Sendable { let price: Int }
        var frames = SSEFrameDecoder<Tick>()
        var received: [SSEDecodedFrame<Tick>] = []
        try! frames.append(Data("data: {\"pri".utf8), epoch: 1, uptime: 10) { received.append($0) }
        precondition(received.isEmpty)
        try! frames.append(Data("ce\":1}\n\ndata: {\"price\":2}\r\n\n".utf8),
                           epoch: 2, uptime: 20) { received.append($0) }
        precondition(received.map { $0.value.price } == [1, 2])
        precondition(received.map(\.sequence) == [1, 2])
        precondition(received.allSatisfy { $0.epoch == 2 && $0.uptime == 20 })
        print("Decoded SSE frames preserve arrival order and final-chunk timestamps")

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
