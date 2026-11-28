import SwiftUI

private struct QihuiInPageStackKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var qihuiInPageStack: Bool {
        get { self[QihuiInPageStackKey.self] }
        set { self[QihuiInPageStackKey.self] = newValue }
    }
}

/// A full page reuses its parent's navigation stack. Legacy modal entries
/// still own an independent stack, so they remain functional during migration.
struct QihuiPageStack<Content: View>: View {
    @Environment(\.qihuiInPageStack) private var inStack
    @ViewBuilder let content: () -> Content
    var body: some View {
        if inStack {
            content().toolbar(.visible,for:.navigationBar)
        } else {
            NavigationStack {
                content().environment(\.qihuiInPageStack,true)
            }
        }
    }
}
