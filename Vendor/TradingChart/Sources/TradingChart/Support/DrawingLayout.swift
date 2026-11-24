import CoreGraphics
import Foundation
import TradingChartCore

/// One straight piece of a drawing in screen coordinates.
@available(iOS 17.0, *)
struct DrawingLine: Equatable {
    var from: CGPoint
    var to: CGPoint
}

/// What the canvas draws for one drawing: its lines, and its anchors when it is selected.
@available(iOS 17.0, *)
struct DrawingStroke: Equatable {
    var id: UUID
    var lines: [DrawingLine]
    var style: DrawingStyle
    var isSelected: Bool
    /// The anchors that are inside the plot (selected drawings only).
    var handles: [CGPoint]
    var fillRect: CGRect? = nil
    var labels: [DrawingLabel] = []
}

@available(iOS 17.0, *)
struct DrawingLabel: Equatable {
    let point: CGPoint
    let text: String
}

/// Everything the canvas draws for the drawings, in screen coordinates.
@available(iOS 17.0, *)
struct DrawingFrame: Equatable {
    var strokes: [DrawingStroke]
    /// The anchors placed so far for the drawing being created, inside the plot.
    var pending: [CGPoint]

    var isEmpty: Bool { strokes.isEmpty && pending.isEmpty }
}

/// Turns drawings into what the canvas draws. Pure.
///
/// A ray runs to the end of the series and a line can be anchored far outside the window, so the shapes are clipped to the
/// window in data space first (see ``DrawingPrimitive/clipped(to:)``): to the visible time range plus a margin, and to the
/// price range that is shown. Only then are they mapped to the screen, so far-off coordinates never reach the canvas.
@available(iOS 17.0, *)
enum DrawingLayout {
    /// How much of the visible window, on each side, the shapes are kept beyond it: the ends of a stroke are never seen.
    static let windowMargin = 0.1
    /// How far beyond the plot an anchor still gets a handle, in points (the radius of a handle).
    static let handleReach: CGFloat = 8

    static func frame(
        drawings: [ChartDrawing],
        selectedID: UUID?,
        pendingAnchors: [ChartAnchor],
        registry: DrawingToolRegistry,
        domain: ChartDomain,
        transform: ChartTransform,
        interval: ChartInterval
    ) -> DrawingFrame {
        let visible = transform.timeRange
        let margin = visible.upperBound.timeIntervalSince(visible.lowerBound) * windowMargin
        let clip = ChartDomain(
            x: visible.lowerBound.addingTimeInterval(-margin)...visible.upperBound.addingTimeInterval(margin),
            y: transform.priceRange
        )
        let reach = transform.plotRect.insetBy(dx: -handleReach, dy: -handleReach)

        var strokes: [DrawingStroke] = []
        strokes.reserveCapacity(drawings.count)
        for drawing in drawings {
            guard let tool = registry.tool(for: drawing.kind) else { continue }
            let isSelected = drawing.id == selectedID
            let lines = tool.primitives(for: drawing.anchors, in: domain).compactMap {
                line(of: $0, clip: clip, transform: transform)
            }
            let handles = isSelected
                ? drawing.anchors.map(transform.point(for:)).filter { reach.contains($0) }
                : []
            var stroke = DrawingStroke(id:drawing.id,lines:lines,style:drawing.style,isSelected:isSelected,handles:handles)
            if drawing.anchors.count >= 2 {
                let a = drawing.anchors[0], b = drawing.anchors[1]
                if drawing.kind == .rectangle {
                    let lo = max(min(a.time,b.time),visible.lowerBound), hi = min(max(a.time,b.time),visible.upperBound)
                    let low = max(min(a.price,b.price),transform.priceRange.lowerBound)
                    let high = min(max(a.price,b.price),transform.priceRange.upperBound)
                    if lo <= hi,low <= high {
                        let x = transform.x(for:lo), y = transform.y(for:high)
                        stroke.fillRect = CGRect(x:x,y:y,width:max(0,transform.x(for:hi)-x),height:max(0,transform.y(for:low)-y))
                    }
                }
                if drawing.kind == .fibonacci {
                    let end = min(max(a.time,b.time),visible.upperBound)
                    if visible.contains(end) {
                        for ratio in ExtendedDrawingTool.fibRatios {
                            let price = b.price+(a.price-b.price)*ratio
                            if transform.priceRange.contains(price) {
                                let point = CGPoint(x:transform.x(for:end)-4,y:transform.y(for:price))
                                stroke.labels.append(DrawingLabel(point:point,text:String(format:"%.1f%%",ratio*100)))
                            }
                        }
                    }
                }
                if drawing.kind == .priceMeasure || drawing.kind == .timeMeasure {
                    let delta = b.price-a.price
                    let bars = abs(b.time.timeIntervalSince(a.time))/interval.seconds
                    let text: String
                    if drawing.kind == .priceMeasure {
                        text = a.price != 0 ? String(format:"%+.4g (%+.2f%%)",delta,delta/abs(a.price)*100) : String(format:"%+.4g",delta)
                    } else {
                        text = String(format:"%.0f 根K线",bars)
                    }
                    let p = transform.point(for:b)
                    if reach.contains(p) {
                        let x = max(transform.plotRect.minX+50,min(transform.plotRect.maxX-4,p.x))
                        stroke.labels.append(DrawingLabel(point:CGPoint(x:x,y:max(12,p.y-8)),text:text))
                    }
                }
            }
            if !stroke.lines.isEmpty || !stroke.handles.isEmpty || stroke.fillRect != nil || !stroke.labels.isEmpty { strokes.append(stroke) }
        }
        let pending = pendingAnchors.map(transform.point(for:)).filter { reach.contains($0) }
        return DrawingFrame(strokes: strokes, pending: pending)
    }

    /// The screen line of one primitive, or `nil` when none of it is inside `clip`.
    static func line(of primitive: DrawingPrimitive, clip: ChartDomain, transform: ChartTransform) -> DrawingLine? {
        guard let visible = primitive.clipped(to: clip) else { return nil }
        let plot = transform.plotRect
        switch visible {
        case .segment(let first, let second):
            return DrawingLine(from: transform.point(for: first), to: transform.point(for: second))
        case .horizontalLine(let price):
            let y = transform.y(for: price)
            return DrawingLine(from: CGPoint(x: plot.minX, y: y), to: CGPoint(x: plot.maxX, y: y))
        case .verticalLine(let time):
            let x = transform.x(for: time)
            return DrawingLine(from: CGPoint(x: x, y: plot.minY), to: CGPoint(x: x, y: plot.maxY))
        }
    }
}
