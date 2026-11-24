import Foundation

/// Qihui's gateway emits one JSON payload per SSE data line. TCP/HTTP
/// chunks may split a line at any byte or contain multiple complete lines.
struct SSELineBuffer {
    private var pending = Data()

    mutating func append(_ chunk: Data) -> [Data] {
        pending.append(chunk)
        var messages: [Data] = []
        while let newline = pending.firstIndex(of: 10) {
            let line = String(decoding: pending[..<newline], as: UTF8.self)
            pending.removeSubrange(...newline)
            guard line.hasPrefix("data:") else { continue }
            let body = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { messages.append(Data(body.utf8)) }
        }
        return messages
    }
}

struct SSEDecodedFrame<Value: Sendable>: Sendable {
    let value: Value
    let sequence: Int
    let epoch: Double
    let uptime: Double
    let decodedUptime: Double
}

/// Delivers each complete JSON frame at the time its final chunk arrives.
/// Called exclusively from a serial URLSession delegate queue.
struct SSEFrameDecoder<Value: Decodable & Sendable> {
    private var lines = SSELineBuffer()
    private let decoder = JSONDecoder()
    private var sequence = 0

    mutating func append(_ chunk: Data, epoch: Double, uptime: Double,
                         onFrame: (SSEDecodedFrame<Value>) -> Void) throws {
        for payload in lines.append(chunk) {
            let value = try decoder.decode(Value.self, from: payload)
            sequence += 1
            onFrame(SSEDecodedFrame(value: value, sequence: sequence, epoch: epoch,
                                    uptime: uptime, decodedUptime: ProcessInfo.processInfo.systemUptime))
        }
    }
}
