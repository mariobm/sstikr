import SwiftUI

extension View {
    /// Liquid glass. Reserved for surfaces that earn translucency (over-camera overlays, hero imagery).
    func stickerGlass(cornerRadius: CGFloat = 20) -> some View {
        modifier(StickerGlassModifier(cornerRadius: cornerRadius))
    }

    /// Quiet opaque card with a hairline border. The default surface for grouped content.
    func stickerCard(cornerRadius: CGFloat = 16) -> some View {
        modifier(StickerCardModifier(cornerRadius: cornerRadius))
    }
}

private struct StickerGlassModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

private struct StickerCardModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.cardSurface)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.hairline, lineWidth: 1)
            }
    }
}

extension Color {
    static let stickerCanvas = Color(red: 0.965, green: 0.968, blue: 0.956)
    static let stickerMist = Color(red: 0.89, green: 0.94, blue: 0.95)
    static let stickerTeal = Color(red: 0.00, green: 0.49, blue: 0.50)
    static let stickerInk = Color(red: 0.07, green: 0.08, blue: 0.10)
    static let stickerOrange = Color(red: 0.91, green: 0.25, blue: 0.08)
    static let stickerGold = Color(red: 0.93, green: 0.67, blue: 0.12)
    static let stickerBlue = Color(red: 0.10, green: 0.28, blue: 0.64)
    static let stickerBerry = Color(red: 0.76, green: 0.12, blue: 0.29)

    /// Card surface: a shade brighter than the canvas so cards read as a quiet raised layer.
    static let cardSurface = Color(red: 0.992, green: 0.994, blue: 0.984)
    /// Hairline border for cards.
    static let hairline = Color.stickerInk.opacity(0.07)

    init(hex: String, fallback: Color = .stickerTeal) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6, let value = UInt64(cleaned, radix: 16) else {
            self = fallback
            return
        }

        self = Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

@MainActor
struct StickerBackdrop: View {
    var body: some View {
        ZStack {
            Color.stickerCanvas
            LinearGradient(
                colors: [
                    Color.stickerMist.opacity(0.55),
                    Color.stickerCanvas.opacity(0)
                ],
                startPoint: .top,
                endPoint: .center
            )
        }
        .ignoresSafeArea()
    }
}

extension TeamDefinition {
    var accentColor: Color {
        Color(hex: primaryColor)
    }

    var secondaryAccentColor: Color {
        Color(hex: secondaryColor, fallback: .stickerOrange)
    }

    var accentGradient: LinearGradient {
        LinearGradient(
            colors: [accentColor, secondaryAccentColor],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
