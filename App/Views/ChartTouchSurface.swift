import SwiftUI
import UIKit

/// A transparent, touch-count-aware gesture surface for the K-line chart.
/// Single-finger pan, single-finger long press and two-finger pinch are independent.
struct ChartTouchSurface: UIViewRepresentable {
    var onPan: (CGFloat, Bool) -> Void
    var onCrosshair: (CGFloat, Bool) -> Void
    var onPinch: (CGFloat, Bool) -> Void
    var onTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        tap.numberOfTapsRequired = 1
        tap.numberOfTouchesRequired = 1
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)

        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.35
        hold.numberOfTouchesRequired = 1
        hold.allowableMovement = 7
        hold.delegate = context.coordinator
        view.addGestureRecognizer(hold)
        tap.require(toFail: hold)
        pan.require(toFail: hold)

        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
        pinch.delegate = context.coordinator
        view.addGestureRecognizer(pinch)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: ChartTouchSurface
        private var holding = false
        private var pinching = false
        init(_ parent: ChartTouchSurface) { self.parent = parent }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        @objc func tap(_ gesture: UITapGestureRecognizer) {
            if gesture.state == .ended && !holding && !pinching { parent.onTap() }
        }

        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            guard !holding && !pinching else { return }
            switch gesture.state {
            case .began, .changed:
                parent.onPan(gesture.translation(in: gesture.view).x, false)
            case .ended, .cancelled, .failed:
                parent.onPan(gesture.translation(in: gesture.view).x, true)
            default: break
            }
        }

        @objc func hold(_ gesture: UILongPressGestureRecognizer) {
            guard !pinching else { return }
            switch gesture.state {
            case .began, .changed:
                holding = true
                parent.onCrosshair(gesture.location(in: gesture.view).x, false)
            case .ended, .cancelled, .failed:
                holding = false
                parent.onCrosshair(gesture.location(in: gesture.view).x, true)
            default: break
            }
        }

        @objc func pinch(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began, .changed:
                pinching = true
                holding = false
                parent.onPinch(gesture.scale, false)
            case .ended, .cancelled, .failed:
                parent.onPinch(gesture.scale, true)
                pinching = false
            default: break
            }
        }
    }
}
