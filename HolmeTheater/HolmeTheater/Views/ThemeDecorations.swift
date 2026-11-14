// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// What drifts across the Home screen for a theme: which pieces, in which colors, and how they move.
struct ThemeEffect: Hashable {
    enum Motion: Hashable {
        /// Falls gently and turns over, side to side, like a leaf.
        case flutter
        /// Falls slowly and steadily, like snow.
        case fall
        /// Wanders and twinkles, like a firefly.
        case drift
        /// Falls quickly, spinning and flipping over.
        case confetti
        /// Flies across the screen, flapping.
        case fly
    }

    /// What a piece looks like.
    enum Art: Hashable {
        case symbol(String)
        case confetti
        case firefly
        case clover
        case egg(EggPattern)
        case bat
        case butterfly
    }

    enum EggPattern: Hashable {
        case stripes, zigzag
    }

    /// How much bigger than its motion's usual size a piece is drawn, for the ones with detail that needs room.
    static func sizeScale(of art: Art) -> CGFloat {
        switch art {
        case .egg: 1.5
        case .butterfly: 1.3
        default: 1
        }
    }

    /// One thing that drifts.
    struct Piece: Hashable {
        let art: Art
        let color: Color
        /// How often it comes up compared with the effect's other pieces.
        var weight = 1
    }

    let motion: Motion
    let pieces: [Piece]
    /// Whether a string of twinkling lights hangs across the top of the screen.
    var hasLights = false
}

// MARK: - Glyph and wash

/// The theme's symbol, shown beside the Home heading in the theme's color.
struct ThemeGlyph: View {
    let theme: AppTheme

    var body: some View {
        Group {
            if theme == .independenceDay {
                // The real flag, rather than the symbol's plain one.
                Text(verbatim: "🇺🇸")
            } else {
                Image(systemName: theme.symbolName)
                    // Solid, like the heading beside it; hierarchical would fade parts of the symbol.
                    .symbolRenderingMode(theme.hasMulticolorSymbol ? .multicolor : .monochrome)
                    .foregroundStyle(theme.accent)
            }
        }
        .font(.title2)
        .accessibilityHidden(true)
    }
}

/// A wash of the theme's color over the whole screen, strongest at the top. Light mode needs more of it to show.
struct ThemeWash: View {
    let color: Color
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let strength = colorScheme == .dark ? 1.0 : 1.25
        LinearGradient(
            stops: [
                .init(color: color.opacity(0.36 * strength), location: 0),
                .init(color: color.opacity(0.22 * strength), location: 0.45),
                .init(color: color.opacity(0.12 * strength), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A faint wash of the theme's color behind a page, so the theme doesn't stop at the Home screen. Much lighter than Home's.
private struct ThemeWashModifier: ViewModifier {
    let strength: Double
    @Environment(AppModel.self) private var appModel

    func body(content: Content) -> some View {
        content.background {
            if let theme = appModel.themeSettings.activeTheme {
                ThemeWash(color: theme.accent).opacity(strength)
            }
        }
    }
}

extension View {
    /// Puts a faint wash of the theme's color behind the page, if a theme is showing.
    func themeWash(_ strength: Double = 0.45) -> some View {
        modifier(ThemeWashModifier(strength: strength))
    }
}

extension Color {
    /// Black with a little of `accent` in it, for the fades over artwork, so they lean toward the theme rather than going
    /// to pure black.
    static func themedBlack(_ accent: Color?) -> Color {
        guard let accent else { return .black }
        return Color.black.mix(with: accent, by: 0.14)
    }
}

/// A holiday's greeting in a small glass pill, for Apple TV, whose Home screen has no heading to carry it.
struct ThemeBadge: View {
    let theme: AppTheme
    let greeting: String

    var body: some View {
        HStack(spacing: 12) {
            ThemeGlyph(theme: theme)
            Text(greeting)
                .font(.callout.weight(.semibold))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Pieces

/// A piece, drawn at ``ThemeParticles/pieceSize`` points across. The particles scale it to their own size.
struct PieceView: View {
    let piece: ThemeEffect.Piece

    var body: some View {
        let size = ThemeParticles.pieceSize
        switch piece.art {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size))
                .foregroundStyle(piece.color)
        case .confetti:
            Rectangle()
                .fill(piece.color)
                .frame(width: size, height: size * 0.6)
        case .firefly:
            ZStack {
                Circle().fill(RadialGradient(colors: [piece.color.opacity(0.5), piece.color.opacity(0)], center: .center, startRadius: 0, endRadius: size / 2))
                Circle().fill(piece.color).frame(width: size * 0.28, height: size * 0.28)
            }
            .frame(width: size, height: size)
        case .clover:
            FourLeafClover(size: size)
                .foregroundStyle(piece.color)
        case .egg(let pattern):
            EasterEgg(pattern: pattern, color: piece.color)
                .frame(width: size * 0.75, height: size)
        case .bat:
            BatShape()
                .fill(piece.color)
                .frame(width: size, height: size * 0.55)
        case .butterfly:
            Butterfly(color: piece.color)
                .frame(width: size, height: size * 0.9)
        }
    }
}

/// A four-leaf clover: four hearts with their points together.
private struct FourLeafClover: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            ForEach(0..<4, id: \.self) { leaf in
                Image(systemName: "heart.fill")
                    .font(.system(size: size * 0.5))
                    .offset(y: -size * 0.22)
                    .rotationEffect(.degrees(Double(leaf) * 90))
            }
        }
        .frame(width: size, height: size)
    }
}

/// An egg, narrower at the top.
nonisolated private struct EggShape: Shape {
    func path(in r: CGRect) -> Path {
        let (w, h) = (r.width, r.height)
        var path = Path()
        path.move(to: CGPoint(x: r.midX, y: r.minY))
        path.addCurve(to: CGPoint(x: r.maxX, y: r.minY + h * 0.62),
                      control1: CGPoint(x: r.midX + w * 0.42, y: r.minY), control2: CGPoint(x: r.maxX, y: r.minY + h * 0.3))
        path.addCurve(to: CGPoint(x: r.midX, y: r.maxY),
                      control1: CGPoint(x: r.maxX, y: r.minY + h * 0.88), control2: CGPoint(x: r.midX + w * 0.28, y: r.maxY))
        path.addCurve(to: CGPoint(x: r.minX, y: r.minY + h * 0.62),
                      control1: CGPoint(x: r.midX - w * 0.28, y: r.maxY), control2: CGPoint(x: r.minX, y: r.minY + h * 0.88))
        path.addCurve(to: CGPoint(x: r.midX, y: r.minY),
                      control1: CGPoint(x: r.minX, y: r.minY + h * 0.3), control2: CGPoint(x: r.midX - w * 0.42, y: r.minY))
        return path
    }
}

/// A zigzag line across the middle of its frame.
nonisolated private struct Zigzag: Shape {
    func path(in r: CGRect) -> Path {
        var path = Path()
        let steps = 6
        for step in 0...steps {
            let point = CGPoint(x: r.minX + r.width * CGFloat(step) / CGFloat(steps), y: step.isMultiple(of: 2) ? r.minY : r.maxY)
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

/// A painted Easter egg.
private struct EasterEgg: View {
    let pattern: ThemeEffect.EggPattern
    let color: Color

    var body: some View {
        EggShape()
            .fill(color)
            .overlay {
                GeometryReader { proxy in
                    let (w, h) = (proxy.size.width, proxy.size.height)
                    switch pattern {
                    case .stripes:
                        VStack(spacing: h * 0.1) {
                            Rectangle().frame(height: h * 0.09)
                            Rectangle().frame(height: h * 0.09)
                        }
                        .position(x: w / 2, y: h * 0.58)
                    case .zigzag:
                        Zigzag()
                            .stroke(style: StrokeStyle(lineWidth: h * 0.07, lineJoin: .round))
                            .frame(width: w, height: h * 0.14)
                            .position(x: w / 2, y: h * 0.55)
                    }
                }
                .foregroundStyle(.white.opacity(0.8))
                .clipShape(EggShape())
            }
    }
}

/// A bat with its wings spread, in a frame about twice as wide as it is tall.
nonisolated private struct BatShape: Shape {
    func path(in r: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y) }
        // The left side mirrors the right.
        func m(_ x: CGFloat, _ y: CGFloat) -> CGPoint { p(1 - x, y) }
        var path = Path()
        path.move(to: p(0.5, 0.3))
        path.addLine(to: p(0.545, 0.08))
        path.addLine(to: p(0.57, 0.3))
        path.addQuadCurve(to: p(0.64, 0.34), control: p(0.6, 0.3))
        // The top of the wing out to its tip, then the scalloped edge back in.
        path.addQuadCurve(to: p(0.99, 0.06), control: p(0.8, 0.12))
        path.addQuadCurve(to: p(0.86, 0.58), control: p(0.96, 0.36))
        path.addQuadCurve(to: p(0.74, 0.66), control: p(0.81, 0.5))
        path.addQuadCurve(to: p(0.6, 0.82), control: p(0.65, 0.58))
        path.addQuadCurve(to: p(0.5, 0.92), control: p(0.56, 0.74))
        path.addQuadCurve(to: m(0.6, 0.82), control: m(0.56, 0.74))
        path.addQuadCurve(to: m(0.74, 0.66), control: m(0.65, 0.58))
        path.addQuadCurve(to: m(0.86, 0.58), control: m(0.81, 0.5))
        path.addQuadCurve(to: m(0.99, 0.06), control: m(0.96, 0.36))
        path.addQuadCurve(to: m(0.64, 0.34), control: m(0.8, 0.12))
        path.addQuadCurve(to: m(0.57, 0.3), control: m(0.6, 0.3))
        path.addLine(to: m(0.545, 0.08))
        path.closeSubpath()
        return path
    }
}

/// A butterfly seen from above, wings open.
private struct Butterfly: View {
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let (w, h) = (proxy.size.width, proxy.size.height)
            ZStack {
                ForEach([-1.0, 1.0], id: \.self) { side in
                    // Upper wing.
                    Ellipse()
                        .fill(color)
                        .frame(width: w * 0.5, height: h * 0.62)
                        .rotationEffect(.degrees(side * 25))
                        .position(x: w / 2 + side * w * 0.24, y: h * 0.34)
                    // Lower wing.
                    Ellipse()
                        .fill(color.opacity(0.8))
                        .frame(width: w * 0.36, height: h * 0.44)
                        .rotationEffect(.degrees(side * -20))
                        .position(x: w / 2 + side * w * 0.17, y: h * 0.72)
                }
                Capsule()
                    .fill(.black.opacity(0.55))
                    .frame(width: w * 0.07, height: h * 0.7)
                    .position(x: w / 2, y: h / 2)
            }
        }
    }
}


/// A theme's wash, glyph and effects over a plain screen.
private struct ThemePreview: View {
    let theme: AppTheme

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(theme.greeting(on: .now) ?? String(localized: "Home"))
                    .font(.largeTitle.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                ThemeGlyph(theme: theme)
            }
            .padding()
            .padding(.top, 50)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { ThemeWash(color: theme.accent) }
        .overlay { ThemeParticles(effect: theme.effect, topInset: 60) }
        .tint(theme.accent)
    }
}

#Preview("Christmas") { ThemePreview(theme: .christmas) }
#Preview("Halloween") { ThemePreview(theme: .halloween) }
#Preview("Spring") { ThemePreview(theme: .spring) }
#Preview("Easter") { ThemePreview(theme: .easter) }
#Preview("New Year's") { ThemePreview(theme: .newYears) }
#Preview("Summer") { ThemePreview(theme: .summer) }
#Preview("4th of July") { ThemePreview(theme: .independenceDay) }
