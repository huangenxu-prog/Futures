import Foundation
import OSLog
import UIKit
import Darwin

/// Sampled diagnostics only. No market or account data is uploaded from iOS.
@MainActor
enum KlineDiagnostics {
    private static let logger = Logger(subsystem: "com.huangenxu.futures", category: "KlineLatency")
    private struct Sample {
        let symbol: String
        let period: Int
        let bar: MarketBar
        let received: Double
        let version: String
    }
    private static var pending: Sample?
    private static var lastLocalSample = -Double.infinity

    static func record(_ event: MarketDataService.CandlePush, period: Int,
                       newest: MarketBar?, started: Double) {
        guard let bar = newest, let received = event.phoneUptime else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // If another event replaces the pending bar before SwiftUI observes it,
        // do not incorrectly attribute the next model update to the old event.
        if let old = pending, old.symbol == event.symbol, old.period == period, old.bar != bar {
            pending = nil
        }
        guard event.diag != nil || now - lastLocalSample >= 2 else { return }
        lastLocalSample = now
        let version = event.diag.map { String($0.version) } ?? "local"
        let server = event.diag.map { ($0.sent_at - $0.received_at) * 1000 }
        let transit = event.diag.flatMap { timing in event.phoneEpoch.map { ($0 - timing.sent_at) * 1000 } }
        let message = "QIHUI_LATENCY receive symbol=\(event.symbol) period=\(period) version=\(version) server_ms=\(format(server)) transit_est_ms=\(format(transit)) phone_queue_ms=\(format((started - received) * 1000)) apply_ms=\(format((now - started) * 1000))"
        logger.notice("\(message, privacy: .public)")
        DevicePerformanceCapture.shared.record(message)
        pending = Sample(symbol: event.symbol, period: period, bar: bar, received: received, version: version)
    }

    static func chartUpdated(symbol: String, period: Int, newest: MarketBar?, started: Double) {
        guard let sample = pending, sample.symbol == symbol, sample.period == period,
              sample.bar == newest else { return }
        pending = nil
        let now = ProcessInfo.processInfo.systemUptime
        let message = "QIHUI_LATENCY chart_model symbol=\(symbol) period=\(period) version=\(sample.version) model_ms=\(format((now - started) * 1000)) phone_total_ms=\(format((now - sample.received) * 1000))"
        logger.notice("\(message, privacy: .public)")
        DevicePerformanceCapture.shared.record(message)
    }

    private static func format(_ value: Double?) -> String {
        value.map { String(format: "%.1f", $0) } ?? "na"
    }
}


/// Diagnostic branch only. Explicit opt-in, bounded memory, foreground sampling.
/// Display-link intervals measure main-run-loop delivery, not GPU presentation.
@MainActor
final class DevicePerformanceCapture: NSObject {
    static let shared = DevicePerformanceCapture()
    private var displayLink: CADisplayLink?
    private var previousFrame: CFTimeInterval?
    private var previousResourceTime: Double = 0
    private var previousCPU: Double?
    private var startTime: Double = 0
    private var frames: [Double] = []
    private var resources: [String] = []
    private var events: [String] = []
    private var totalFrames = 0
    private var droppedEvents = 0
    private var droppedResources = 0
    var running: Bool { displayLink != nil }

    func start() {
        guard !running else { return }
        frames.removeAll(keepingCapacity: true)
        resources.removeAll(keepingCapacity: true)
        events.removeAll(keepingCapacity: true)
        totalFrames = 0; droppedEvents = 0; droppedResources = 0
        previousFrame = nil; previousCPU = nil
        startTime = ProcessInfo.processInfo.systemUptime
        previousResourceTime = startTime
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        // Do not request a higher refresh rate than the app normally uses.
        link.add(to: .main, forMode: .common)
        displayLink = link
    }
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        previousFrame = nil
    }
    func record(_ line: String) {
        guard running else { return }
        guard events.count < 12000 else { droppedEvents += 1; return }
        events.append(String(format: "t=%.3f %@", ProcessInfo.processInfo.systemUptime-startTime, line))
    }
    @objc private func tick(_ link: CADisplayLink) {
        guard UIApplication.shared.applicationState == .active else {
            previousFrame = nil; previousCPU = nil
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let previousFrame {
            let interval = (link.timestamp - previousFrame) * 1000
            if interval > 0 {
                totalFrames += 1
                if frames.count < 120000 { frames.append(interval) }
            }
        }
        previousFrame = link.timestamp
        guard now - previousResourceTime >= 5 else { return }
        let elapsed = now - previousResourceTime
        previousResourceTime = now
        var usage = rusage()
        let cpu: Double? = getrusage(RUSAGE_SELF, &usage) == 0
            ? Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec)/1e6
              + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec)/1e6 : nil
        let cpuPercent = cpu.flatMap { current in previousCPU.map { max(0, (current-$0)/elapsed*100) } }
        previousCPU = cpu
        var vm = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        let memory = status == KERN_SUCCESS ? String(format: "%.2f", Double(vm.phys_footprint)/1048576) : "na"
        let percent = cpuPercent.map { String(format: "%.2f", $0) } ?? "na"
        if resources.count < 2000 {
            resources.append(String(format: "t=%.3f cpu_pct_one_core=%@ footprint_mib=%@ thermal=%d", now-startTime, percent, memory, ProcessInfo.processInfo.thermalState.rawValue))
        } else { droppedResources += 1 }
    }
    func report() -> String {
        let sorted = frames.sorted()
        func percentile(_ p: Double) -> String {
            guard !sorted.isEmpty else { return "na" }
            return String(format: "%.3f", sorted[min(sorted.count-1, max(0, Int(ceil(Double(sorted.count)*p))-1))])
        }
        let header = [
            "QIHUI DEVICE PERFORMANCE v1",
            "iOS=\(UIDevice.current.systemVersion) cores=\(ProcessInfo.processInfo.activeProcessorCount)",
            "display_link_samples=\(sorted.count) total_intervals=\(totalFrames) p50_ms=\(percentile(0.5)) p95_ms=\(percentile(0.95)) p99_ms=\(percentile(0.99)) max_ms=\(percentile(1))",
            "display-link timing is not actual rendered FPS; CPU percentage is relative to one core.",
            "resource_samples=\(resources.count) dropped=\(droppedResources) events=\(events.count) dropped=\(droppedEvents)"
        ]
        return (header + ["RESOURCES"] + resources + ["EVENTS"] + events).joined(separator: "\n")
    }
}
