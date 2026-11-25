import Foundation

/// A bounded local troubleshooting log. No upload, no credentials, no
/// synchronous disk work on the network queue or the main actor.
enum SSEReceiveTrace {
    private final class Writer: @unchecked Sendable {
        let queue = DispatchQueue(label: "qihui.sse.trace", qos: .utility)
        var lines: [String] = []
        var lastWrite = -Double.infinity
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("行情接收诊断.txt")

        func record(_ line: String) {
            queue.async {
                self.lines.append(line)
                if self.lines.count > 1800 { self.lines.removeFirst(self.lines.count - 1800) }
                let now = ProcessInfo.processInfo.systemUptime
                guard now - self.lastWrite >= 1, let url = self.url else { return }
                self.lastWrite = now
                let header = "期汇 SSE 接收诊断 | epoch=Unix秒 | queue_ms=解码完成至主线程开始 | apply_ms=主线程处理耗时\n"
                try? (header + self.lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    private static let writer = Writer()
    static func record(_ message: @autoclosure () -> String) {
        #if DEBUG
        let timestamp = String(format: "%.3f", Date().timeIntervalSince1970)
        writer.record(timestamp + " " + message())
        #endif
    }

    static func ms(_ seconds: Double) -> String {
        String(format: "%.2f", seconds * 1000)
    }
}
