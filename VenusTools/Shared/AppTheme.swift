import SwiftUI

enum AppTheme {
    static let canvas = Color(hex: 0xF5F2E9)
    static let surface = Color(hex: 0xFFFDF7)
    static let pine = Color(hex: 0x315744)
    static let pineDark = Color(hex: 0x213D30)
    static let sage = Color(hex: 0xE4EBE2)
    static let amber = Color(hex: 0xD99542)
    static let ink = Color(hex: 0x26352C)
    static let secondary = Color(hex: 0x7B8177)
    static let line = Color(hex: 0xE8E3D8)
    static let terracotta = Color(hex: 0xB76D52)
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
