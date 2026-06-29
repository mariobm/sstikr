import SwiftUI

@MainActor
struct CountryBadge: View {
    let team: TeamDefinition?
    let fallbackCode: String
    var compact = false

    var body: some View {
        if compact {
            HStack(spacing: 4) {
                Text(team?.flag ?? fallbackCode)
                    .font(.system(size: 15))
                Text(team?.code ?? fallbackCode)
                    .font(.system(.caption2, design: .rounded, weight: .bold))
                    .monospaced()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(Color.cardSurface.opacity(0.92), in: Capsule())
            .foregroundStyle(Color.stickerInk)
            .accessibilityLabel(team?.name ?? fallbackCode)
        } else {
            HStack(spacing: 7) {
                Text(team?.flag ?? fallbackCode)
                    .font(.system(size: 22))
                Text(team?.code ?? fallbackCode)
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .monospaced()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(Color.stickerInk)
            .accessibilityLabel(team?.name ?? fallbackCode)
        }
    }
}
