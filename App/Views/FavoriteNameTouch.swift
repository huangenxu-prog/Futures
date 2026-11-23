import SwiftUI
import UIKit

struct FavoriteNameTouch: UIViewRepresentable {
    let open: () -> Void
    let reveal: () -> Void
    let drag: (CGFloat, UIGestureRecognizer.State) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let target = context.coordinator
        let tap = UITapGestureRecognizer(target: target, action: #selector(Coordinator.tap))
        let swipe = UISwipeGestureRecognizer(target: target, action: #selector(Coordinator.swipe))
        swipe.direction = .right
        let hold = UILongPressGestureRecognizer(target: target, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.35
        tap.require(toFail: hold)
        tap.require(toFail: swipe)
        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(swipe)
        view.addGestureRecognizer(hold)
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.parent = self }

    final class Coordinator: NSObject {
        var parent: FavoriteNameTouch
        var start: CGPoint = .zero
        init(_ parent: FavoriteNameTouch) { self.parent = parent }
        @objc func tap() { parent.open() }
        @objc func swipe() { parent.reveal() }
        @objc func hold(_ sender: UILongPressGestureRecognizer) {
            let point = sender.location(in: nil)
            if sender.state == .began { start = point }
            if sender.state == .ended, point.x - start.x > 28, abs(point.y - start.y) < 17 {
                parent.drag(0, .cancelled)
                parent.reveal()
            } else {
                parent.drag(point.y - start.y, sender.state)
            }
        }
    }
}

final class Favorites: ObservableObject {
    @Published private(set) var ids: [String] {
        didSet { UserDefaults.standard.set(ids, forKey: "favorite-product-order") }
    }
    init() {
        ids = UserDefaults.standard.stringArray(forKey: "favorite-product-order") ?? FuturesInstrument.catalog.map(\.id)
    }
    func toggle(_ id: String) {
        if ids.contains(id) { ids.removeAll { $0 == id } } else { ids.append(id) }
    }
    func move(_ id: String, to index: Int) {
        guard let from = ids.firstIndex(of: id), ids.indices.contains(index), from != index else { return }
        ids.remove(at: from)
        ids.insert(id, at: index)
    }
}
