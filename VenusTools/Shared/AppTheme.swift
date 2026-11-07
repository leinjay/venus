import SwiftUI

enum AppSkin: String, CaseIterable, Identifiable {
    case classic, sky
    var id: String { rawValue }
    var title: String { self == .sky ? "晴空蓝" : "松林绿" }
    static let storageKey = "venus.appearance.skin"
}

enum AppTheme {
    private static var sky: Bool { UserDefaults.standard.string(forKey: AppSkin.storageKey) == AppSkin.sky.rawValue }
    static var canvas: Color { Color(hex: sky ? 0xEEF7FE : 0xF5F2E9) }
    static var surface: Color { Color(hex: sky ? 0xFFFFFF : 0xFFFDF7) }
    static var pine: Color { Color(hex: sky ? 0x1879B5 : 0x315744) }
    static var pineDark: Color { Color(hex: sky ? 0x12557F : 0x213D30) }
    static var sage: Color { Color(hex: sky ? 0xDCEFFC : 0xE4EBE2) }
    static var amber: Color { Color(hex: sky ? 0xAD6A19 : 0xD99542) }
    static var ink: Color { Color(hex: sky ? 0x183C55 : 0x26352C) }
    static var secondary: Color { Color(hex: sky ? 0x58758A : 0x7B8177) }
    static var line: Color { Color(hex: sky ? 0xD0E5F3 : 0xE8E3D8) }
    static var terracotta: Color { Color(hex: sky ? 0xB25D48 : 0xB76D52) }
}

extension Color {
    init(hex: UInt) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

struct SurfaceCard: ViewModifier {
    var padding: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(AppTheme.line.opacity(0.8), lineWidth: 1)
            }
    }
}

extension View {
    func surfaceCard(padding: CGFloat = 18) -> some View {
        modifier(SurfaceCard(padding: padding))
    }
}

struct BrandHeader: View {
    let eyebrow: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(eyebrow.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.8)
                .foregroundStyle(AppTheme.pine)
            Text(title)
                .font(.system(size: 34, weight: .semibold, design: .serif))
                .foregroundStyle(AppTheme.ink)
            Text(subtitle)
                .font(.system(size: 15))
                .foregroundStyle(AppTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AccentLabel: View {
    let title: String
    var color: Color = AppTheme.pine

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.10), in: Capsule())
    }
}

#if os(iOS)
/// Cumulative stream updates stay visible while the remaining characters catch up.
struct AIReplyText: View {
    let text: String
    var generating = false
    var animate = true
    var replayID = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = ""
    @State private var lastReplayID = ""

    var body: some View {
        (Text(visible) + Text(generating || visible.count < text.count ? " ▍" : "").foregroundColor(AppTheme.pine))
            .textSelection(.enabled)
            .accessibilityLabel(text)
            .task(id: replayID + text) {
                if lastReplayID != replayID { lastReplayID = replayID; visible = "" }
                if reduceMotion || !animate { visible = text; return }
                if !text.hasPrefix(visible) { visible = "" }
                while visible.count < text.count && !Task.isCancelled {
                    let remaining = text.count - visible.count
                    let step = min(8, max(1, remaining / 20))
                    visible = String(text.prefix(visible.count + step))
                    do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                }
            }
    }
}

#endif
