import SwiftUI
import UIKit

/// User-selected appearance. Default is dark, with an explicit system option.
enum AppAppearanceMode: String, CaseIterable, Identifiable {
    case system, dark, light, black, gray

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .dark: return "深色"
        case .black: return "纯黑"
        case .gray: return "纯灰"
        case .light: return "浅色"
        }
    }
    var icon: String {
        switch self {
        case .system: return "iphone.gen3"
        case .dark: return "moon.fill"
        case .black: return "circle.fill"
        case .gray: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark, .black, .gray: return .dark
        case .light: return .light
        }
    }
}

struct AppearanceSettingsView: View {
    private var backgroundStyle = MarketBackgroundStyle()
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
            .background(backgroundStyle.surface.ignoresSafeArea())
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

/// Independent display preferences: no changes to indicator parameters,
/// trading colors, quotes, history, or real-time chart data.
enum CandleAppearance {
    static let hollowKey = "qihui.chart.rising-hollow.v1"
    static let upKey = "qihui.chart.candle-up-rgb.v1"
    static let downKey = "qihui.chart.candle-down-rgb.v1"
    static let dojiKey = "qihui.chart.candle-doji-rgb.v1"
    static let automatic = -1

    static var defaultDoji: Color {
        Color(uiColor: UIColor { traits in traits.userInterfaceStyle == .dark ? .white : .black })
    }
    static func color(_ rgb: Int, fallback: Color) -> Color {
        guard (0...0xFFFFFF).contains(rgb) else { return fallback }
        return Color(red: Double((rgb >> 16) & 255)/255,
                     green: Double((rgb >> 8) & 255)/255,
                     blue: Double(rgb & 255)/255)
    }
    static func rgb(_ color: Color) -> Int? {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha),
              [red,green,blue].allSatisfy({$0.isFinite}) else { return nil }
        func byte(_ v: CGFloat) -> Int { Int((min(1,max(0,v))*255).rounded()) }
        return (byte(red)<<16) | (byte(green)<<8) | byte(blue)
    }
}

struct CandleAppearanceView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(CandleAppearance.hollowKey) private var hollow = true
    @AppStorage(CandleAppearance.upKey) private var up = CandleAppearance.automatic
    @AppStorage(CandleAppearance.downKey) private var down = CandleAppearance.automatic
    @AppStorage(CandleAppearance.dojiKey) private var doji = CandleAppearance.automatic

    var body: some View {
        NavigationStack {
            Form { CandleAppearanceFields() }
                .navigationTitle("K线样式").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }.tint(MarketPalette.accent)
    }
}

struct CandleAppearanceFields: View {
    @AppStorage(CandleAppearance.hollowKey) private var hollow = true
    @AppStorage(CandleAppearance.upKey) private var up = CandleAppearance.automatic
    @AppStorage(CandleAppearance.downKey) private var down = CandleAppearance.automatic
    @AppStorage(CandleAppearance.dojiKey) private var doji = CandleAppearance.automatic
    var body: some View {
        Group {
                Section("K线样式") {
                    Picker("上涨实体", selection: $hollow) {
                        Text("空心").tag(true)
                        Text("实心").tag(false)
                    }
                    .pickerStyle(.segmented)
                    ColorPicker("上涨颜色", selection: colorBinding($up, fallback: MarketPalette.up), supportsOpacity: false)
                    ColorPicker("下跌颜色", selection: colorBinding($down, fallback: MarketPalette.down), supportsOpacity: false)
                    ColorPicker("十字星颜色", selection: colorBinding($doji, fallback: CandleAppearance.defaultDoji), supportsOpacity: false)
                }
                Section {
                    HStack(spacing: 22) {
                        sample("上涨", color: CandleAppearance.color(up, fallback: MarketPalette.up), outlined: hollow)
                        sample("下跌", color: CandleAppearance.color(down, fallback: MarketPalette.down), outlined: false)
                        sample("十字星", color: CandleAppearance.color(doji, fallback: CandleAppearance.defaultDoji), outlined: false, isDoji: true)
                    }
                    .frame(maxWidth: .infinity)
                    Button("恢复默认") {
                        hollow = true
                        up = CandleAppearance.automatic
                        down = CandleAppearance.automatic
                        doji = CandleAppearance.automatic
                    }
                } footer: {
                    Text("只改变K线外观，自动保存。可随时切回原版实心样式。")
                }

        }
    }

    private func colorBinding(_ value: Binding<Int>, fallback: Color) -> Binding<Color> {
        Binding(get: { CandleAppearance.color(value.wrappedValue, fallback: fallback) },
                set: { if let rgb = CandleAppearance.rgb($0) { value.wrappedValue = rgb } })
    }

    private func sample(_ title: String, color: Color, outlined: Bool, isDoji: Bool = false) -> some View {
        VStack(spacing: 6) {
            VStack(spacing: 0) {
                Rectangle().fill(color).frame(width: 1.5,height: 9)
                if isDoji {
                    Rectangle().fill(color).frame(width: 15,height: 1.5)
                } else if outlined {
                    Rectangle().strokeBorder(color,lineWidth: 1.5).frame(width: 12,height: 22)
                } else {
                    Rectangle().fill(color).frame(width: 12,height: 22)
                }
                Rectangle().fill(color).frame(width: 1.5,height: 9)
            }.frame(height: 42)
            Text(title).font(.caption).foregroundStyle(MarketPalette.muted)
        }.frame(maxWidth: .infinity)
    }
}


/// Quote colors are intentionally independent of candle/indicator colors.
enum QuoteAppearance {
    static let lightUpKey = "qihui.quote.light-up-rgb.v1"
    static let lightDownKey = "qihui.quote.light-down-rgb.v1"
    static let darkUpKey = "qihui.quote.dark-up-rgb.v1"
    static let darkDownKey = "qihui.quote.dark-down-rgb.v1"

    // Use the existing detail-header colors as the shared defaults.
    static let lightUp = 0xD43B4A
    static let lightDown = 0x0F9166
    static let darkUp = 0xFF5B5B
    static let darkDown = 0x23C6C8

    static func color(_ rgb: Int, fallback: Int) -> Color {
        CandleAppearance.color(rgb, fallback: CandleAppearance.color(fallback, fallback: .primary))
    }
}

struct QuoteAppearanceStyle: DynamicProperty {
    @Environment(\.colorScheme) private var scheme
    @AppStorage(QuoteAppearance.lightUpKey) private var lightUp = CandleAppearance.automatic
    @AppStorage(QuoteAppearance.lightDownKey) private var lightDown = CandleAppearance.automatic
    @AppStorage(QuoteAppearance.darkUpKey) private var darkUp = CandleAppearance.automatic
    @AppStorage(QuoteAppearance.darkDownKey) private var darkDown = CandleAppearance.automatic

    func movement(_ change: Double?, neutral: Color = MarketPalette.muted) -> Color {
        guard let change, change.isFinite, change != 0 else { return neutral }
        if scheme == .dark {
            return change > 0
                ? QuoteAppearance.color(darkUp, fallback: QuoteAppearance.darkUp)
                : QuoteAppearance.color(darkDown, fallback: QuoteAppearance.darkDown)
        }
        return change > 0
            ? QuoteAppearance.color(lightUp, fallback: QuoteAppearance.lightUp)
            : QuoteAppearance.color(lightDown, fallback: QuoteAppearance.lightDown)
    }
}

struct QuoteAppearanceFields: View {
    @AppStorage(QuoteAppearance.lightUpKey) private var lightUp = CandleAppearance.automatic
    @AppStorage(QuoteAppearance.lightDownKey) private var lightDown = CandleAppearance.automatic
    @AppStorage(QuoteAppearance.darkUpKey) private var darkUp = CandleAppearance.automatic
    @AppStorage(QuoteAppearance.darkDownKey) private var darkDown = CandleAppearance.automatic

    var body: some View {
        Group {
            Section("行情配色 · 深色") {
                ColorPicker("上涨／资金流入", selection: binding($darkUp, fallback: QuoteAppearance.darkUp), supportsOpacity: false)
                ColorPicker("下跌／资金流出", selection: binding($darkDown, fallback: QuoteAppearance.darkDown), supportsOpacity: false)
            }
            Section {
                ColorPicker("上涨／资金流入", selection: binding($lightUp, fallback: QuoteAppearance.lightUp), supportsOpacity: false)
                ColorPicker("下跌／资金流出", selection: binding($lightDown, fallback: QuoteAppearance.lightDown), supportsOpacity: false)
                Button("恢复行情默认配色") {
                    lightUp = CandleAppearance.automatic
                    lightDown = CandleAppearance.automatic
                    darkUp = CandleAppearance.automatic
                    darkDown = CandleAppearance.automatic
                }
            } header: {
                Text("行情配色 · 浅色")
            } footer: {
                Text("首页与合约详情报价、资金流向统一配色。深浅主题分别保存，不影响K线和指标。")
            }
        }
    }

    private func binding(_ value: Binding<Int>, fallback: Int) -> Binding<Color> {
        Binding(get: { QuoteAppearance.color(value.wrappedValue, fallback: fallback) },
                set: { if let rgb = CandleAppearance.rgb($0) { value.wrappedValue = rgb } })
    }
}


/// Background roles only; never changes quote, candle or indicator colors.
struct MarketBackgroundStyle: DynamicProperty {
    @AppStorage("qihui.appearance.mode.v1") private var mode = AppAppearanceMode.dark.rawValue
    @Environment(\.colorScheme) private var scheme

    var isCustom: Bool { scheme == .dark && (mode == AppAppearanceMode.black.rawValue || mode == AppAppearanceMode.gray.rawValue) }

    private func role(_ original: Color, black: Int, gray: Int) -> Color {
        guard isCustom else { return original }
        return CandleAppearance.color(mode == AppAppearanceMode.black.rawValue ? black : gray, fallback: original)
    }
    var surface: Color { role(MarketPalette.surface, black: 0x000000, gray: 0x242424) }
    var raised: Color { role(MarketPalette.raised, black: 0x101010, gray: 0x303030) }
    var divider: Color { role(MarketPalette.divider, black: 0x242424, gray: 0x414141) }
}
