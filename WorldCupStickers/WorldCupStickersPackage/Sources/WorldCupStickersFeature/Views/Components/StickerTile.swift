import SwiftUI

@MainActor
struct StickerTile: View {
    let definition: StickerDefinition
    let owned: OwnedSticker?
    let team: TeamDefinition?
    let index: Int
    let cleanMode: Bool
    let onAdd: () -> Void
    let onRemove: () -> Void

    init(
        definition: StickerDefinition,
        owned: OwnedSticker?,
        team: TeamDefinition? = nil,
        index: Int = 0,
        cleanMode: Bool = false,
        onAdd: @escaping () -> Void,
        onRemove: @escaping () -> Void
    ) {
        self.definition = definition
        self.owned = owned
        self.team = team
        self.index = index
        self.cleanMode = cleanMode
        self.onAdd = onAdd
        self.onRemove = onRemove
    }

    private var quantity: Int {
        owned?.quantity ?? 0
    }

    private var stripOverlayInfo: Bool {
        cleanMode && quantity > 0
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

            if quantity > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        stickerNumberBadge
                        Spacer(minLength: 4)
                    }

                    Spacer(minLength: 0)

                    if !stripOverlayInfo {
                        Text(definition.name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.white)
                            .lineLimit(2)
                            .minimumScaleFactor(0.82)
                    }
                }
                .padding(10)
            }

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
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
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
            missingArtwork
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
                        missingAccentColor.opacity(0.82),
                        missingSecondaryColor.opacity(0.68)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }

    private var missingArtwork: some View {
        ZStack {
            Text("26")
                .font(.system(size: 118, weight: .black, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.18))
                .minimumScaleFactor(0.7)
                .offset(y: -8)

            Rectangle()
                .fill(missingSecondaryColor.opacity(0.22))
                .rotationEffect(.degrees(-18))
                .frame(height: 72)
                .offset(y: -28)

            VStack(spacing: 14) {
                Spacer(minLength: 4)

                VStack(spacing: 2) {
                    Text(team?.code ?? definition.teamCode)
                        .font(.title3.weight(.black))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                    Text("\(definition.number)")
                        .font(.system(.title, design: .rounded, weight: .black))
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .foregroundStyle(missingAccentColor)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)
                .padding(.vertical, 14)
                .background(Color.white.opacity(0.86), in: RoundedRectangle(cornerRadius: 24, style: .continuous))

                Spacer(minLength: 0)

                Text(definition.name)
                    .font(.caption.weight(.heavy))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.68)
                    .foregroundStyle(missingAccentColor)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 11)
                    .background(Color.white.opacity(0.86), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .padding(.bottom, 34)
            }
            .padding(14)
        }
    }

    private var missingAccentColor: Color {
        team?.accentColor ?? .stickerTeal
    }

    private var missingSecondaryColor: Color {
        team?.secondaryAccentColor ?? .stickerBlue
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

    private var stickerNumberBadge: some View {
        Text("#\(definition.number)")
            .font(.caption.weight(.bold))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(quantity > 0 ? Color.white : Color.stickerInk)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                quantity > 0
                    ? Color.black.opacity(0.42)
                    : Color.cardSurface.opacity(0.92),
                in: Capsule()
            )
            .accessibilityHidden(true)
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
