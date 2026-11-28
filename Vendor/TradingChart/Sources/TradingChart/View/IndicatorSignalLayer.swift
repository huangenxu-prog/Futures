import SwiftUI
import TradingChartCore

/// Only present for indicators that emit drawing primitives. The native
/// price chart, scrolling, crosshair and gesture layers stay unchanged.
@available(iOS 17.0, *)
struct IndicatorSignalLayer: View {
    let outputs: [IndicatorOutput]
    let visible: ClosedRange<Date>
    let domain: ClosedRange<Double>
    let candleWidth: CGFloat
    @Environment(\.tradingChartTheme) private var theme

    var body: some View {
        Canvas { context,size in
            let span = visible.upperBound.timeIntervalSince(visible.lowerBound)
            guard span > 0, size.width > 0, size.height > 0 else { return }
            let mapping = YMapping(domain:domain,height:size.height)
            func x(_ time: Date) -> CGFloat {
                CGFloat(time.timeIntervalSince(visible.lowerBound)/span)*size.width
            }
            for output in outputs {
                for series in output.segmentSeries {
                    let color = series.style.color.map(Color.init) ?? theme.line
                    for segment in series.visible(in:visible) {
                        guard let (a,b) = segment.clipped(to:visible) else { continue }
                        let x1 = x(a.time), x2 = x(b.time)
                        let y1 = mapping.y(of:a.value), y2 = mapping.y(of:b.value)
                        guard [x1,x2,y1,y2].allSatisfy(\.isFinite) else { continue }
                        var path = Path()
                        path.move(to:CGPoint(x:x1,y:y1))
                        path.addLine(to:CGPoint(x:x2,y:y2))
                        context.stroke(path,with:.color(color),style:StrokeStyle(lineWidth:CGFloat(series.style.width),lineCap:.round,dash:series.style.dash.map { CGFloat($0) }))
                    }
                }
                let margin = Double(candleWidth)/Double(size.width)*span
                let from = visible.lowerBound.addingTimeInterval(-margin)
                let to = visible.upperBound.addingTimeInterval(margin)
                let lo = output.sticks.partitionPoint { $0.time >= from }
                let hi = output.sticks.partitionPoint { $0.time > to }
                for stick in output.sticks[lo..<max(lo,hi)] {
                    let px = x(stick.time), y1 = mapping.y(of:stick.start), y2 = mapping.y(of:stick.end)
                    guard px.isFinite,y1.isFinite,y2.isFinite,stick.width.isFinite else { continue }
                    let color = stick.color.map(Color.init) ?? theme.line
                    let width = max(1,candleWidth*CGFloat(min(10,max(0,stick.width)))/10)
                    let rect = CGRect(x:px-width/2,y:min(y1,y2),width:width,height:max(1,abs(y2-y1)))
                    if stick.hollow && width > 1 {
                        context.stroke(Path(rect),with:.color(color),lineWidth:1)
                    } else {
                        context.fill(Path(rect),with:.color(color))
                    }
                }
                let first = output.signals.partitionPoint { $0.time >= visible.lowerBound }
                let end = output.signals.partitionPoint { $0.time > visible.upperBound }
                for signal in output.signals[first..<max(first,end)] {
                    let px = x(signal.time), py = mapping.y(of:signal.value)
                    guard px.isFinite,py.isFinite else { continue }
                    let color = signal.color.map(Color.init) ?? theme.line
                    let text = Text(signal.text).font(.system(size:CGFloat(signal.fontSize),weight:.semibold)).foregroundColor(color)
                    context.draw(text,at:CGPoint(x:px,y:py),anchor:.center)
                }
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
