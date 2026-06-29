import SwiftUI

@MainActor
struct StickerTile: View {
    let definition: StickerDefinition
    let owned: OwnedSticker?
    let team: TeamDefinition?
    let onAdd: () -> Void
    let onRemove: () -> Void

    init(
        definition: StickerDefinition,
        owned: OwnedSticker?,
        team: TeamDefinition? = nil,
        onAdd: @escaping () -> Void,
        onRemove: @escaping () -> Void
    ) {
        self.definition = definition
        self.owned = owned
        self.team = team
        self.onAdd = onAdd
        self.onRemove = onRemove
    }

    private var quantity: Int {
        owned?.quantity ?? 0
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            tileBackground
            tileArtwork
            if quantity > 0 {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.55)],
                    startPoint: .center,
                    endPoint: .bottom
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    CountryBadge(team: team, fallbackCode: definition.teamCode, compact: true)
                    Spacer(minLength: 4)
                    Text("\(definition.number)")
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(quantity > 0 ? Color.white : Color.stickerInk)
                }

                Spacer(minLength: 0)

                Text(definition.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(quantity > 0 ? Color.white : Color.stickerInk)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
            }
            .padding(10)

            editControls
        }
        .aspectRatio(0.72, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            if quantity == 0 {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.hairline, lineWidth: 1)
            }
        }
        .overlay(alignment: .topTrailing) {
            if quantity > 1 {
                Text("×\(quantity)")
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.stickerOrange, in: Capsule())
                    .foregroundStyle(Color.white)
                    .padding(7)
                    .accessibilityHidden(true)
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: quantity)
        .accessibilityLabel("\(definition.displayCode), \(accessibilityState)")
        .accessibilityIdentifier("stickerTile_\(definition.id)")
    }

    @ViewBuilder
    private var tileArtwork: some View {
        if quantity > 0 {
            CachedAsyncImage(url: definition.imageURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure:
                    ownedPlaceholder
                case .empty:
                    Color.clear
                        .overlay { ProgressView().tint(.white) }
                @unknown default:
                    ownedPlaceholder
                }
            }
        } else {
            Color.clear
        }
    }

    private var tileBackground: some View {
        Group {
            if quantity > 0 {
                team?.accentGradient ?? LinearGradient(
                    colors: [.stickerTeal, .stickerBlue],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            } else {
                LinearGradient(
                    colors: [
                        Color.cardSurface,
                        (team?.accentColor ?? Color.stickerTeal).opacity(0.07)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
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

    private var accessibilityState: String {
        switch quantity {
        case 0: "missing"
        case 1: "owned"
        default: "\(quantity) copies"
        }
    }

    private var editControls: some View {
        HStack(spacing: 6) {
            if quantity > 0 {
                TileIconButton(
                    systemImage: "minus",
                    style: .translucent,
                    accessibilityLabel: "Remove \(definition.displayCode)"
                ) {
                    onRemove()
                }
            }
            TileIconButton(
                systemImage: "plus",
                style: quantity == 0 ? .filled : .translucent,
                accessibilityLabel: "Add \(definition.displayCode)"
            ) {
                onAdd()
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .accessibilityElement(children: .contain)
    }
}

@MainActor
private struct TileIconButton: View {
    enum Style {
        case filled
        case translucent
    }

    let systemImage: String
    let style: Style
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 28, height: 28)
                .foregroundStyle(Color.white)
                .background(circleFill)
                .overlay {
                    if case .translucent = style {
                        Circle().strokeBorder(Color.white.opacity(0.4), lineWidth: 1)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var circleFill: AnyView {
        switch style {
        case .filled:
            AnyView(Circle().fill(Color.stickerTeal))
        case .translucent:
            AnyView(Circle().fill(Color.white.opacity(0.22)))
        }
    }
}
