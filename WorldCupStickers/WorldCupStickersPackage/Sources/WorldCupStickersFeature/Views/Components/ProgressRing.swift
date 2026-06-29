import SwiftUI

@MainActor
struct ProgressRing: View {
    let progress: Double
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(.secondary.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(
                    AngularGradient(
                        colors: [.stickerTeal, .stickerOrange, .stickerTeal],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            Text(progress.formatted(.percent.precision(.fractionLength(0))))
                .font(.caption.weight(.bold))
                .monospacedDigit()
        }
        .accessibilityLabel("Completion")
        .accessibilityValue(progress.formatted(.percent.precision(.fractionLength(0))))
    }
}
