import SwiftUI

@MainActor
struct ProgressRing: View {
    let progress: Double
    let lineWidth: CGFloat
    var tint: Color = .stickerTeal
    var labelColor: Color = .stickerInk
    var label: String? = nil

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(
                    tint,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            Text(label ?? progress.formatted(.percent.precision(.fractionLength(0))))
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(labelColor)
        }
        .accessibilityLabel("Completion")
        .accessibilityValue(label ?? progress.formatted(.percent.precision(.fractionLength(0))))
    }
}
