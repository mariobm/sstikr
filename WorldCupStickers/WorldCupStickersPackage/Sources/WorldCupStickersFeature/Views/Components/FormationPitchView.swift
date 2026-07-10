import SwiftUI

/// Stylised vertical football pitch that overlays both teams' lineups as
/// formation rows. Home defends the bottom goal and attacks upward; away
/// defends the top goal and attacks downward — the classic lineup graphic.
struct FormationPitchView: View {
    let homeLineup: WorldCupLineupSide?
    let awayLineup: WorldCupLineupSide?
    let homeName: String
    let awayName: String
    let homeFlag: String?
    let awayFlag: String?
    let homeColor: Color
    let awayColor: Color

    var body: some View {
        VStack(spacing: 10) {
            if awayLineup.mapOrFalse({ !$0.starters.isEmpty }) {
                teamBanner(
                    name: awayName,
                    flag: awayFlag,
                    formation: awayLineup?.formation ?? "",
                    color: awayColor
                )
            }

            pitch
                .frame(maxWidth: .infinity)

            if homeLineup.mapOrFalse({ !$0.starters.isEmpty }) {
                teamBanner(
                    name: homeName,
                    flag: homeFlag,
                    formation: homeLineup?.formation ?? "",
                    color: homeColor
                )
            }
        }
    }

    private var pitch: some View {
        // Positions are fractional (0...1) and independent of the resolved
        // size, so compute the token arrays once per body instead of on
        // every GeometryReader invocation.
        let awayTokens = tokens(for: awayLineup, color: awayColor, side: .away)
        let homeTokens = tokens(for: homeLineup, color: homeColor, side: .home)

        return Color.clear
            .aspectRatio(0.70, contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    let W = geo.size.width
                    let H = geo.size.height
                    let tokenSize = min(max(min(W, H) * 0.085, 22), 38)

                    ZStack {
                        PitchSurface()

                        ForEach(awayTokens) { token in
                            PitchToken(
                                player: token.player,
                                color: token.color,
                                diameter: tokenSize,
                                labelAbove: true
                            )
                            .position(x: W * token.x, y: H * token.y)
                        }

                        ForEach(homeTokens) { token in
                            PitchToken(
                                player: token.player,
                                color: token.color,
                                diameter: tokenSize,
                                labelAbove: false
                            )
                            .position(x: W * token.x, y: H * token.y)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.hairline, lineWidth: 1)
            }
    }

    private func teamBanner(name: String, flag: String?, formation: String, color: Color) -> some View {
        HStack(spacing: 8) {
            if let flag {
                Text(flag)
                    .font(.system(size: 18))
                    .accessibilityHidden(true)
            }
            Text(name)
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .foregroundStyle(Color.stickerInk)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 10)
            if !formation.isEmpty {
                Text(formation)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(color, in: Capsule())
            }
        }
    }

    // MARK: - Placement

    private enum Side {
        case home
        case away
    }

    private struct PlacedPlayer: Identifiable {
        let id: String
        let player: WorldCupLineupPlayer
        let x: Double
        let y: Double
        let color: Color
    }

    /// Own goalkeeper Y, then outfield rows running from "nearest to own goal"
    /// to "nearest to the halfway line".
    private func zoneBounds(for side: Side) -> (gkY: Double, nearY: Double, farY: Double) {
        switch side {
        case .home:
            // Bottom of the pitch, attacking toward the centre at y = 0.5.
            return (0.93, 0.84, 0.56)
        case .away:
            // Top of the pitch, attacking toward the centre at y = 0.5.
            return (0.07, 0.16, 0.44)
        }
    }

    private func tokens(
        for lineup: WorldCupLineupSide?,
        color: Color,
        side: Side
    ) -> [PlacedPlayer] {
        guard let lineup, !lineup.starters.isEmpty else { return [] }
        let rows = FormationLayout.rows(
            starters: lineup.starters,
            formation: lineup.formation
        )
        let bounds = zoneBounds(for: side)
        let fieldRows = max(0, rows.count - 1)
        var result: [PlacedPlayer] = []

        for (ri, row) in rows.enumerated() {
            let y: Double
            if ri == 0 {
                y = bounds.gkY
            } else {
                let t = fieldRows > 1 ? Double(ri - 1) / Double(fieldRows - 1) : 0
                y = bounds.nearY + (bounds.farY - bounds.nearY) * t
            }

            let count = max(1, row.count)
            for (ci, player) in row.enumerated() {
                let x = FormationLayout.rowX(index: ci, count: count)
                result.append(
                    PlacedPlayer(
                        id: "\(side)-\(ri)-\(ci)-\(player.id)",
                        player: player,
                        x: x,
                        y: y,
                        color: color
                    )
                )
            }
        }
        return result
    }
}

// MARK: - Pitch surface

private struct PitchSurface: View {
    var body: some View {
        ZStack {
            // Base gradient.
            LinearGradient(
                stops: [
                    .init(color: Color(red: 0.20, green: 0.55, blue: 0.28), location: 0),
                    .init(color: Color(red: 0.27, green: 0.62, blue: 0.33), location: 0.5),
                    .init(color: Color(red: 0.20, green: 0.52, blue: 0.26), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // Mowing stripes as hard-stop gradient bands so the whole surface
            // is one GPU layer instead of a live Canvas that re-renders.
            LinearGradient(
                stops: stripeStops(),
                startPoint: .top,
                endPoint: .bottom
            )

            PitchMarkings()
                .stroke(Color.white.opacity(0.82), lineWidth: 1.5)
        }
        // The pitch artwork is fully static: rasterise it once into a Metal
        // texture so it never re-rasters while the enclosing scroll view moves.
        .drawingGroup()
    }

    private func stripeStops() -> [Gradient.Stop] {
        let bands = 9
        let light = Color.white.opacity(0.045)
        let dark = Color.black.opacity(0.05)
        var stops: [Gradient.Stop] = []
        for index in 0..<bands {
            let top = Double(index) / Double(bands)
            let bottom = Double(index + 1) / Double(bands)
            let tint = index.isMultiple(of: 2) ? light : dark
            stops.append(.init(color: tint, location: top))
            stops.append(.init(color: tint, location: bottom))
        }
        return stops
    }
}

private struct PitchMarkings: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let inset = min(rect.width, rect.height) * 0.025
        let field = rect.insetBy(dx: inset, dy: inset)
        let w = field.width
        let h = field.height
        let midX = field.midX
        let midY = field.midY

        // Boundary.
        path.addRect(field)

        // Halfway line.
        path.move(to: CGPoint(x: field.minX, y: midY))
        path.addLine(to: CGPoint(x: field.maxX, y: midY))

        // Centre circle + spot.
        let centreRadius = min(w, h) * 0.13
        path.addEllipse(in: CGRect(
            x: midX - centreRadius,
            y: midY - centreRadius,
            width: centreRadius * 2,
            height: centreRadius * 2
        ))
        path.addEllipse(in: CGRect(
            x: midX - 1.5,
            y: midY - 1.5,
            width: 3,
            height: 3
        ))

        // Top (away) and bottom (home) boxes share the same geometry, mirrored.
        let penW = w * 0.66
        let penDepth = h * 0.16
        let areaW = w * 0.32
        let areaDepth = h * 0.066
        let penSpot = h * 0.11
        let spotRadius = CGFloat(2.5)

        // Top.
        path.addRect(CGRect(
            x: midX - areaW / 2,
            y: field.minY,
            width: areaW,
            height: areaDepth
        ))
        path.addRect(CGRect(
            x: midX - penW / 2,
            y: field.minY,
            width: penW,
            height: penDepth
        ))
        path.addEllipse(in: CGRect(
            x: midX - spotRadius,
            y: field.minY + penSpot - spotRadius,
            width: spotRadius * 2,
            height: spotRadius * 2
        ))

        // Bottom.
        path.addRect(CGRect(
            x: midX - areaW / 2,
            y: field.maxY - areaDepth,
            width: areaW,
            height: areaDepth
        ))
        path.addRect(CGRect(
            x: midX - penW / 2,
            y: field.maxY - penDepth,
            width: penW,
            height: penDepth
        ))
        path.addEllipse(in: CGRect(
            x: midX - spotRadius,
            y: field.maxY - penSpot - spotRadius,
            width: spotRadius * 2,
            height: spotRadius * 2
        ))

        return path
    }
}

// MARK: - Player token

private struct PitchToken: View {
    let player: WorldCupLineupPlayer
    let color: Color
    let diameter: CGFloat
    let labelAbove: Bool

    var body: some View {
        VStack(spacing: 2) {
            if labelAbove {
                nameLabel
            }
            token
            if !labelAbove {
                nameLabel
            }
        }
        .frame(width: diameter * 1.9)
        .accessibilityHidden(true)
    }

    private var token: some View {
        ZStack {
            Circle()
                .fill(color)
            Circle()
                .strokeBorder(Color.white, lineWidth: 1.6)
            Text(player.jerseyNumber.map(String.init) ?? "–")
                .font(.system(size: diameter * 0.42, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
        .frame(width: diameter, height: diameter)
    }

    private var nameLabel: some View {
        let label = player.shortName.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = label.isEmpty ? player.name : label
        // Flat dark capsule keeps white text legible on the pitch without a
        // Gaussian-blur shadow (which was the main scroll-jank cost, x22).
        return Text(text)
            .font(.system(size: diameter * 0.30, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.55)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.black.opacity(0.34), in: Capsule())
            .frame(width: diameter * 1.9)
    }
}

// MARK: - Formation layout math

enum FormationLayout {
    static func parse(_ formation: String) -> [Int] {
        let parts = formation
            .split(whereSeparator: { "-,/".contains($0) })
            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 > 0 }) else { return [] }
        return parts
    }

    /// Splits starters into rows of players, with the goalkeeper (assumed first
    /// in the list) in its own row, followed by outfield lines derived from the
    /// formation string. Falls back to a balanced spread when the formation is
    /// missing or does not match the available players.
    static func rows(
        starters: [WorldCupLineupPlayer],
        formation: String
    ) -> [[WorldCupLineupPlayer]] {
        guard !starters.isEmpty else { return [] }
        var players = starters
        let keeper = players.removeFirst()
        var rows: [[WorldCupLineupPlayer]] = [[keeper]]

        let lines = parse(formation)
        let outfield = players

        if !lines.isEmpty, lines.reduce(0, +) == outfield.count {
            var index = 0
            for count in lines {
                let end = min(index + count, outfield.count)
                if index < end {
                    rows.append(Array(outfield[index..<end]))
                }
                index = end
            }
        } else if !outfield.isEmpty {
            var remaining = outfield
            for count in balancedRowCounts(outfield.count) {
                rows.append(Array(remaining.prefix(count)))
                remaining.removeFirst(count)
            }
        }
        return rows
    }

    static func rowX(index: Int, count: Int) -> Double {
        let margin = 0.09
        let usable = 1.0 - margin * 2
        let slot = usable / Double(max(1, count))
        return margin + (Double(index) + 0.5) * slot
    }

    /// Balanced row sizes aiming for ~3 players per line, with the earlier
    /// lines carrying any remainder so defenders usually read slightly fuller.
    private static func balancedRowCounts(_ count: Int) -> [Int] {
        guard count > 0 else { return [] }
        let rows = max(1, Int((Double(count) / 3.0).rounded(.up)))
        let capped = min(rows, count)
        let base = count / capped
        let remainder = count % capped
        return (0..<capped).map { index in
            base + (index < remainder ? 1 : 0)
        }
    }
}

// MARK: - Convenience

private extension Optional where Wrapped == WorldCupLineupSide {
    func mapOrFalse(_ transform: (WorldCupLineupSide) -> Bool) -> Bool {
        self.map(transform) ?? false
    }
}