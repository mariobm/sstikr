import SwiftUI

@MainActor
struct StickerTile: View {
    let definition: StickerDefinition
    let owned: OwnedSticker?
    let team: TeamDefinition?

    init(definition: StickerDefinition, owned: OwnedSticker?, team: TeamDefinition? = nil) {
        self.definition = definition
        self.owned = owned
        self.team = team
    }

    private var quantity: Int {
        owned?.quantity ?? 0
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            tileBackground
            tileArtwork
            LinearGradient(
                colors: [
                    .black.opacity(quantity > 0 ? 0.04 : 0),
                    .black.opacity(quantity > 0 ? 0.72 : 0)
                ],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    CountryBadge(team: team, fallbackCode: definition.teamCode, compact: true)
                    Spacer(minLength: 4)
                    Text("\(definition.number)")
                        .font(.headline.weight(.black))
                        .monospacedDigit()
                        .foregroundStyle(quantity > 0 ? Color.white : Color.stickerInk)
                }

                Spacer(minLength: 42)

                VStack(alignment: .leading, spacing: 4) {
                    Text(definition.name)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(quantity > 0 ? Color.white : Color.stickerInk)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)

                    HStack(spacing: 5) {
                        Image(systemName: quantity > 0 ? "checkmark.seal.fill" : "seal")
                            .imageScale(.small)
                        Text(quantityDescription)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(quantity > 0 ? Color.white.opacity(0.88) : Color.secondary)
                }
            }
            .padding(10)
        }
        .aspectRatio(0.72, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tileBorder, lineWidth: quantity > 0 ? 0 : 1)
        }
        .overlay(alignment: .topTrailing) {
            if quantity > 1 {
                Label("\(quantity)", systemImage: "square.stack.3d.up.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2.weight(.black))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.94), in: Capsule())
                    .foregroundStyle(Color.stickerOrange)
                    .padding(7)
            }
        }
        .accessibilityLabel("\(definition.displayCode), \(quantityDescription)")
        .accessibilityIdentifier("stickerTile_\(definition.id)")
    }

    @ViewBuilder
    private var tileArtwork: some View {
        if quantity > 0 {
            AsyncImage(url: definition.imageURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure:
                    ownedPlaceholder
                case .empty:
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                @unknown default:
                    ownedPlaceholder
                }
            }
        } else {
            missingPlaceholder
        }
    }

    private var tileBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(
                team?.accentGradient ?? LinearGradient(
                    colors: [.stickerTeal, .stickerBlue],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }

    private var ownedPlaceholder: some View {
        ZStack {
            team?.accentGradient ?? LinearGradient(
                colors: [.stickerTeal, .stickerInk],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(team?.flag ?? definition.teamCode)
                .font(.largeTitle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var missingPlaceholder: some View {
        ZStack {
            Color.white.opacity(0.76)
            VStack(spacing: 8) {
                Text(team?.flag ?? definition.teamCode)
                    .font(.system(size: 34))
                    .frame(height: 42)
                Text(definition.displayCode)
                    .font(.headline.weight(.black))
                    .monospacedDigit()
                    .foregroundStyle(team?.accentColor ?? Color.stickerTeal)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var tileBorder: Color {
        quantity > 0 ? .clear : (team?.accentColor ?? .stickerTeal).opacity(0.22)
    }

    private var quantityDescription: String {
        switch quantity {
        case 0: "missing"
        case 1: "owned once"
        default: "\(quantity) copies"
        }
    }
}
