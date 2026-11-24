import Foundation

/// Additional tools use the same data-space primitives, clipping, selection,
/// anchor editing and persistence as the original three tools.
public struct ExtendedDrawingTool: DrawingTool {
    public let kind: DrawingKind
    public init(_ kind: DrawingKind) { self.kind = kind }
    public var requiredAnchorCount: Int {
        switch kind {
        case .verticalLine,.horizontalRay: return 1
        case .parallelChannel: return 3
        default: return 2
        }
    }
    public func primitives(for anchors:[ChartAnchor],in domain:ChartDomain) -> [DrawingPrimitive] {
        guard anchors.count >= requiredAnchorCount,let a = anchors.first else { return [] }
        func at(_ time:Date,_ price:Double) -> ChartAnchor { ChartAnchor(time:time,price:price) }
        if kind == .verticalLine { return [.verticalLine(time:a.time)] }
        if kind == .horizontalRay {
            return [.segment(a,at(max(a.time,domain.x.upperBound),a.price))]
        }
        let b = anchors[1]
        switch kind {
        case .rectangle,.priceMeasure,.timeMeasure:
            let c = at(a.time,b.price), d = at(b.time,a.price)
            if kind == .rectangle {
                return [.segment(a,c),.segment(c,b),.segment(b,d),.segment(d,a)]
            }
            return [.segment(a,b),.segment(a,d),.segment(d,b)]
        case .parallelChannel:
            let c = anchors[2], dt = b.time.timeIntervalSince(a.time)
            guard dt != 0 else { return [.segment(a,b)] }
            let slope = (b.price-a.price)/dt
            let offset = c.price-(a.price+slope*c.time.timeIntervalSince(a.time))
            guard offset.isFinite else { return [] }
            let p = at(a.time,a.price+offset), q = at(b.time,b.price+offset)
            return [.segment(a,b),.segment(p,q),.segment(a,p),.segment(b,q)]
        case .fibonacci:
            let lo = min(a.time,b.time), hi = max(a.time,b.time)
            return Self.fibRatios.map { ratio in
                let price = b.price+(a.price-b.price)*ratio
                return .segment(at(lo,price),at(hi,price))
            }
        default: return []
        }
    }
    public static let fibRatios:[Double] = [0,0.236,0.382,0.5,0.618,0.786,1]
}
