import SwiftUI

@MainActor
struct CountryBadge: View {
    let team: TeamDefinition?
    let fallbackCode: String
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 4 : 7) {
            Text(team?.flag ?? fallbackCode)
                .font(.system(size: compact ? 15 : 22))
                .frame(width: compact ? 18 : 28, height: compact ? 18 : 28)

            Text(team?.code ?? fallbackCode)
                .font(.system(compact ? .caption2 : .subheadline, design: .rounded, weight: .black))
                .monospaced()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, compact ? 7 : 10)
        .padding(.vertical, compact ? 5 : 7)
        .background(.thinMaterial, in: Capsule())
        .foregroundStyle(Color.stickerInk)
    }
}
