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
