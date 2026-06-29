import SwiftUI

extension View {
    func stickerGlass(cornerRadius: CGFloat = 24) -> some View {
        modifier(StickerGlassModifier(cornerRadius: cornerRadius))
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

extension Color {
    static let stickerCanvas = Color(red: 0.965, green: 0.968, blue: 0.956)
    static let stickerMist = Color(red: 0.89, green: 0.94, blue: 0.95)
    static let stickerTeal = Color(red: 0.00, green: 0.49, blue: 0.50)
    static let stickerInk = Color(red: 0.07, green: 0.08, blue: 0.10)
    static let stickerOrange = Color(red: 0.91, green: 0.25, blue: 0.08)
    static let stickerGold = Color(red: 0.93, green: 0.67, blue: 0.12)
    static let stickerBlue = Color(red: 0.10, green: 0.28, blue: 0.64)
    static let stickerBerry = Color(red: 0.76, green: 0.12, blue: 0.29)

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
                    Color.stickerMist,
                    Color.white.opacity(0.52),
                    Color.stickerGold.opacity(0.18)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            LinearGradient(
                colors: [
                    Color.stickerBlue.opacity(0.16),
                    Color.clear,
                    Color.stickerOrange.opacity(0.14)
                ],
                startPoint: .topTrailing,
                endPoint: .bottomLeading
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
