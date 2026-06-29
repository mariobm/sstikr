import SwiftUI

@MainActor
struct TeamCompletionSplash: View {
    let team: TeamDefinition
    let sticker: StickerDefinition?
    let onDismiss: () -> Void

    @State private var overlayOpacity: Double = 0
    @State private var burstScale: CGFloat = 0.3
    @State private var burstOpacity: Double = 0
    @State private var cardRotationY: Double = 90
    @State private var cardRotationX: Double = -12
    @State private var cardScale: CGFloat = 0.5
    @State private var cardOpacity: Double = 0
    @State private var sparklesScale: CGFloat = 0.3
    @State private var sparklesOpacity: Double = 0
    @State private var labelOpacity: Double = 0
    @State private var hapticTrigger = 0

    var body: some View {
        ZStack {
            Color.black
                .opacity(overlayOpacity)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            lightBurst
            sparkleRing

            card
                .scaleEffect(cardScale)
                .rotation3DEffect(
                    .degrees(cardRotationY),
                    axis: (x: 0, y: 1, z: 0),
                    perspective: 0.3
                )
                .rotation3DEffect(
                    .degrees(cardRotationX),
                    axis: (x: 1, y: 0, z: 0),
                    perspective: 0.3
                )
                .opacity(cardOpacity)

            VStack {
                Spacer()
                VStack(spacing: 4) {
                    Text("Collection Complete")
                        .font(.system(.title3, design: .rounded, weight: .bold))
                    Text(team.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .foregroundStyle(.white)
                .opacity(labelOpacity)
                .padding(.bottom, 60)
            }
        }
        .task {
            await playSequence()
        }
        .sensoryFeedback(.success, trigger: hapticTrigger)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Collection complete for \(team.name)")
        .accessibilityAddTraits(.isModal)
    }

    private var lightBurst: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        team.accentColor.opacity(0.5),
                        team.secondaryAccentColor.opacity(0.2),
                        .clear
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: 180
                )
            )
            .frame(width: 360, height: 360)
            .scaleEffect(burstScale)
            .opacity(burstOpacity)
            .blur(radius: 20)
    }

    private var sparkleRing: some View {
        ZStack {
            ForEach(0..<6, id: \.self) { i in
                let angle = Double(i) / 6.0 * .pi * 2
                Image(systemName: "sparkle")
                    .font(.title)
                    .foregroundStyle(.white.opacity(0.6))
                    .offset(
                        x: cos(angle) * 150 * sparklesScale,
                        y: sin(angle) * 150 * sparklesScale
                    )
            }
        }
        .opacity(sparklesOpacity)
    }

    private var card: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(team.accentGradient)

            VStack(spacing: 0) {
                HStack {
                    HStack(spacing: 6) {
                        Text(team.flag).font(.title2)
                        Text(team.code)
                            .font(.subheadline.weight(.bold))
                            .monospaced()
                    }
                    Spacer()
                    Text("#1")
                        .font(.title2.weight(.bold))
                        .monospacedDigit()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)

                stickerImage
                    .frame(maxHeight: .infinity)
                    .padding(.horizontal, 20)

                VStack(spacing: 3) {
                    Text(sticker?.name ?? "Team Crest")
                        .font(.subheadline.weight(.semibold))
                    Text("COMPLETE")
                        .font(.caption.weight(.semibold))
                        .tracking(3)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .foregroundStyle(.white)
                .padding(.bottom, 18)
                .padding(.top, 8)
            }
        }
        .frame(width: 260, height: 360)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(.white.opacity(0.2), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.5), radius: 30, y: 15)
    }

    @ViewBuilder
    private var stickerImage: some View {
        if let sticker {
            AsyncImage(url: sticker.imageURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFit()
                } else {
                    Text(team.flag).font(.system(size: 72))
                }
            }
        } else {
            Text(team.flag).font(.system(size: 72))
        }
    }

    private func playSequence() async {
        try? await Task.sleep(for: .seconds(0.8))

        withAnimation(.easeOut(duration: 0.35)) {
            overlayOpacity = 0.85
        }

        withAnimation(.easeOut(duration: 0.7)) {
            burstScale = 2.2
            burstOpacity = 1
        }
        withAnimation(.easeOut(duration: 0.6)) {
            sparklesScale = 1.0
            sparklesOpacity = 1
        }

        hapticTrigger += 1
        withAnimation(.spring(duration: 0.9, bounce: 0.35)) {
            cardRotationY = 0
            cardRotationX = 0
            cardScale = 1
            cardOpacity = 1
        }

        try? await Task.sleep(for: .seconds(0.5))

        withAnimation(.easeOut(duration: 0.6)) {
            burstOpacity = 0
            sparklesOpacity = 0.4
        }

        withAnimation(.easeIn(duration: 0.4)) {
            labelOpacity = 1
        }

        try? await Task.sleep(for: .seconds(1.8))

        withAnimation(.easeInOut(duration: 0.6)) {
            cardRotationY = -90
            cardScale = 0.5
            cardOpacity = 0
            labelOpacity = 0
            sparklesOpacity = 0
            overlayOpacity = 0
        }

        try? await Task.sleep(for: .seconds(0.6))
        onDismiss()
    }
}
