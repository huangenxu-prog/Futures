import Foundation

// Presentation and action eligibility for both old and current trade gateways.
// A terminal order with an unknown cause is never reported as canceled.
enum CloudOrderState: String {
    case alive = "ALIVE", partial = "PARTIAL", filled = "FILLED"
    case canceled = "CANCELED", partialCanceled = "PARTIAL_CANCELED"
    case rejected = "REJECTED", finished = "FINISHED", unknown = "UNKNOWN"

    var label: String {
        switch self {
        case .alive: return "未成"
        case .partial: return "部成"
        case .filled: return "已成"
        case .canceled: return "已撤"
        case .partialCanceled: return "部撤"
        case .rejected: return "废单"
        case .finished: return "终止"
        case .unknown: return "待定"
        }
    }
    var isWorking: Bool { self == .alive || self == .partial }
    var isTerminal: Bool {
        switch self {
        case .filled, .canceled, .partialCanceled, .rejected, .finished: return true
        default: return false
        }
    }
    static func resolve(display: String?, status: String, quantity: Int, remaining: Int, isDead: Bool?) -> Self {
        guard quantity > 0, remaining >= 0, remaining <= quantity else { return .unknown }
        if let display {
            guard let value = Self(rawValue: display) else { return .unknown }
            if value.isWorking && (isDead == true || status == "FINISHED") { return remaining == 0 ? .filled : .finished }
            if value == .filled && remaining != 0 { return .unknown }
            if value == .canceled && remaining != quantity { return .unknown }
            if value == .partialCanceled && !(remaining > 0 && remaining < quantity) { return .unknown }
            return value
        }
        if isDead == true || status == "FINISHED" { return remaining == 0 ? .filled : .finished }
        if status == "ALIVE" { return remaining < quantity ? .partial : .alive }
        return .unknown
    }
}
