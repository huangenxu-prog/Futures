import SwiftUI

/// User-selected appearance. Default is dark, with an explicit system option.
enum AppAppearanceMode: String, CaseIterable, Identifiable {
    case system, dark, light

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .dark: return "深色"
        case .light: return "浅色"
        }
    }
    var icon: String {
        switch self {
        case .system: return "iphone.gen3"
        case .dark: return "moon.fill"
        case .light: return "sun.max.fill"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }
}

struct AppearanceSettingsView: View {
    @AppStorage("qihui.appearance.mode.v1") private var selectedMode = AppAppearanceMode.dark.rawValue
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(AppAppearanceMode.allCases) { mode in
                        Button {
                            selectedMode = mode.rawValue
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: mode.icon)
                                    .frame(width: 23)
                                    .foregroundStyle(MarketPalette.accent)
                                Text(mode.title)
                                    .foregroundStyle(MarketPalette.ink)
                                Spacer()
                                if selectedMode == mode.rawValue {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(MarketPalette.accent)
                                }
                            }
                            .frame(minHeight: 35)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selectedMode == mode.rawValue ? .isSelected : [])
                    }
                } header: {
                    Text("外观")
                } footer: {
                    Text("默认使用深色。切换立即生效，并会在下次启动时保持。")
                }
            }
            .scrollContentBackground(.hidden)
            .background(MarketPalette.background.ignoresSafeArea())
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .tint(MarketPalette.accent)
    }
}
