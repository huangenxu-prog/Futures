import UIKit

/// Resign UIKit-backed editors and numeric fields as well as SwiftUI focus.
enum IndicatorKeyboard {
    @MainActor
    static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),to:nil,from:nil,for:nil)
    }
}
