// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

// MARK: - Particles

/// The theme's pieces drifting over the screen, some small and dim behind and some larger and soft in front, and for
/// some themes a string of lights along the top.
///
/// Doesn't take touches, and draws nothing with Reduce Motion on.
struct ThemeParticles: View {
    /// Which of the pieces this draws. The soft, near ones go behind the screen's content and the sharp ones in front,
    /// each layer being its own screen-sized view.
    enum Layer {
        case back, front
    }

    let effect: ThemeEffect
    /// How far down the screen the content starts, so the lights hang just below the bars.
    var topInset: CGFloat = 0
    var layer: Layer = .front

    @State private var simulation = ParticleSimulation()
    @State private var isVisible = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The size pieces are drawn at before each is scaled to its own size.
    static let pieceSize: CGFloat = 24

    var body: some View {
        if !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: scenePhase != .active || !isVisible)) { timeline in
                Canvas { context, size in
                    simulation.layer = layer
                    simulation.step(to: timeline.date, size: size, effect: effect)
                    simulation.draw(in: context, topInset: topInset)
                } symbols: {
                    // Each piece is drawn once here and reused for every particle that shows it: sharp, and softened
                    // for the ones passing in front, so nothing is blurred frame by frame. Padded so the blur isn't cut off.
                    ForEach(effect.pieces.indices, id: \.self) { index in
                        if layer == .front {
                            PieceView(piece: effect.pieces[index]).tag(index)
                        } else {
                            PieceView(piece: effect.pieces[index])
                                .padding(6)
                                .blur(radius: 2)
                                .tag(effect.pieces.count + index)
                        }
                    }
                }
            }
            .ignoresSafeArea()
            // Where its left edge is on the screen, which the string of lights is laid out from, so it's in the same place
            // however far the area runs past the screen's edge on either side.
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: { simulation.originX = $0 }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear { isVisible = true }
            .onDisappear { isVisible = false }
        }
    }
}

extension ThemeEffect.Motion {
    /// How many are on screen at once.
    fileprivate var count: Int {
        switch self {
        case .flutter: 20
        case .fall: 34
        case .drift: 28
        case .confetti: 32
        case .fly: 7
        }
    }

    /// The size, in points across, at middle depth.
    fileprivate var sizeRange: ClosedRange<CGFloat> {
        switch self {
        case .flutter: 13...18
        case .fall: 8...13
        case .drift: 13...18
        case .confetti: 7...10
        case .fly: 20...28
        }
    }

    /// Points per second downward at middle depth. For flying, how fast it climbs or sinks.
    fileprivate var fallRange: ClosedRange<Double> {
        switch self {
        case .flutter: 28...45
        case .fall: 22...40
        case .drift: -6...8
        case .confetti: 40...65
        case .fly: -5...5
        }
    }

    /// How far it sways from side to side (up and down, for flying).
    fileprivate var sway: Double {
        switch self {
        case .flutter: 26
        case .fall: 12
        case .drift: 18
        case .confetti: 10
        case .fly: 14
        }
    }

    /// Radians per second it can turn, either way.
    fileprivate var spin: Double {
        switch self {
        case .flutter: 1.5
        case .fall: 0.5
        case .drift: 0.3
        case .confetti: 2
        case .fly: 0
        }
    }

    fileprivate var opacity: Double {
        switch self {
        case .flutter: 0.65
        case .fall, .fly: 0.7
        case .confetti: 0.75
        case .drift: 0.9
        }
    }
}

extension ThemeEffect {
    /// How many pieces are on screen at once, across both layers. A few more bats than butterflies, which are bigger and
    /// busier.
    fileprivate var particleCount: Int {
        motion == .fly && pieces.contains { $0.art == .bat } ? 16 : motion.count
    }
}

/// Moves and draws the particles. Lives in the view's state and is stepped from the view's timeline; nothing in it is
/// observed, so stepping it never invalidates a view.
final class ParticleSimulation {
    /// Which layer's pieces this makes; set by the view that owns it.
    var layer: ThemeParticles.Layer = .front

    /// How far the drawing area's left edge is from the screen's, so the lights can be laid out from the screen's.
    var originX: CGFloat = 0

    /// How many of `effect`'s pieces this layer has: a third of them behind, the rest in front.
    private func count(for effect: ThemeEffect) -> Int {
        let behind = max(3, effect.particleCount / 3)
        return layer == .back ? behind : effect.particleCount - behind
    }

    fileprivate enum Depth {
        /// Small, dim and slow, behind.
        case far
        case mid
        /// Bigger, soft and quick, in front.
        case near

        /// The back layer has only the soft, near ones, and the front layer only the sharp ones.
        static func random(for layer: ThemeParticles.Layer) -> Depth {
            switch layer {
            case .back: .near
            case .front: Double.random(in: 0..<1) < 0.47 ? .far : .mid
            }
        }

        var scale: CGFloat {
            switch self {
            case .far: 0.6
            case .mid: 1
            case .near: 1.45
            }
        }

        var speed: Double {
            switch self {
            case .far: 0.6
            case .mid: 1
            case .near: 1.4
            }
        }

        var opacity: Double {
            switch self {
            case .far: 0.55
            case .mid: 1
            case .near: 0.9
            }
        }
    }

    fileprivate struct Particle {
        var position: CGPoint
        var velocity: CGVector
        var size: CGFloat
        var depth: Depth
        var rotation: Double
        var spin: Double
        var phase: Double
        /// Which of the effect's pieces it shows.
        var piece: Int
        /// When it appeared, in the simulation's time, so it can fade in.
        var born: Double
    }

    private var particles: [Particle] = []
    private var effect: ThemeEffect?
    private var size: CGSize = .zero
    private var lastDate: Date?
    private var time: Double = 0

    // MARK: Stepping

    func step(to date: Date, size: CGSize, effect: ThemeEffect) {
        guard size.width > 0, size.height > 0, !effect.pieces.isEmpty else { return }
        // A new theme, or a new screen shape: start over, spread across the screen so it doesn't begin empty.
        if effect != self.effect || abs(size.width - self.size.width) > 1 || abs(size.height - self.size.height) > 1 {
            self.effect = effect
            self.size = size
            particles = (0..<count(for: effect)).map { _ in spawn(effect: effect, anywhere: true) }
        }
        // After a pause the timeline picks up where it was, rather than jumping.
        let dt = min(max(date.timeIntervalSince(lastDate ?? date), 0), 1.0 / 15)
        lastDate = date
        time += dt

        let motion = effect.motion
        let margin: CGFloat = 40
        for index in particles.indices {
            var p = particles[index]
            let swayRate = 0.8 + p.phase.truncatingRemainder(dividingBy: 0.6)
            let sway = cos(time * swayRate + p.phase) * motion.sway * swayRate * p.depth.speed
            if motion == .fly {
                // Bobbing up and down as it crosses.
                p.position.x += p.velocity.dx * dt
                p.position.y += (p.velocity.dy + sway) * dt
            } else {
                p.position.x += (p.velocity.dx + sway) * dt
                p.position.y += p.velocity.dy * dt
            }
            p.rotation += p.spin * dt
            // Off the screen: start again at the edge it comes in from.
            if p.position.y > size.height + margin || p.position.y < -margin * 2
                || p.position.x < -margin * 2 || p.position.x > size.width + margin * 2 {
                p = spawn(effect: effect, anywhere: false)
            }
            particles[index] = p
        }
    }

    /// A new particle, anywhere on screen to begin with, or else just off the edge it comes in from.
    private func spawn(effect: ThemeEffect, anywhere: Bool) -> Particle {
        let motion = effect.motion
        let depth = Depth.random(for: layer)
        let position: CGPoint
        let velocity: CGVector
        if motion == .fly {
            let direction: CGFloat = Bool.random() ? 1 : -1
            position = CGPoint(
                x: anywhere ? .random(in: 0...size.width) : (direction > 0 ? -30 : size.width + 30),
                y: .random(in: (size.height * 0.1)...(size.height * 0.75))
            )
            velocity = CGVector(dx: direction * .random(in: 30...55) * depth.speed, dy: .random(in: motion.fallRange))
        } else {
            // Drifting things barely move up or down, so starting at the top edge they'd never get on screen (or drift
            // straight back off it). They appear anywhere instead, fading in where they are.
            let onScreen = anywhere || motion == .drift
            position = CGPoint(x: .random(in: 0...size.width), y: onScreen ? .random(in: 0...size.height) : -30)
            velocity = CGVector(dx: .random(in: -6...6), dy: Double.random(in: motion.fallRange) * depth.speed)
        }
        let piece = Self.randomPiece(of: effect)
        return Particle(
            position: position,
            velocity: velocity,
            size: .random(in: motion.sizeRange) * depth.scale * ThemeEffect.sizeScale(of: effect.pieces[piece].art),
            depth: depth,
            rotation: motion == .fly ? 0 : .random(in: 0..<(.pi * 2)),
            spin: motion.spin == 0 ? 0 : .random(in: -motion.spin...motion.spin),
            phase: .random(in: 0..<(.pi * 2)),
            piece: piece,
            born: time
        )
    }

    /// A piece of `effect`, the more common ones more often.
    private static func randomPiece(of effect: ThemeEffect) -> Int {
        var roll = Int.random(in: 0..<max(effect.pieces.reduce(0) { $0 + $1.weight }, 1))
        for (index, piece) in effect.pieces.enumerated() {
            if roll < piece.weight { return index }
            roll -= piece.weight
        }
        return 0
    }

    // MARK: Drawing

    func draw(in context: GraphicsContext, topInset: CGFloat) {
        guard let effect else { return }
        let motion = effect.motion
        // Resolved once a frame, not once a particle: the sharp pieces, then the softened ones.
        let symbols = (0..<(effect.pieces.count * 2)).map { context.resolveSymbol(id: $0) }

        for p in particles {
            guard let symbol = symbols[p.depth == .near ? effect.pieces.count + p.piece : p.piece] else { continue }
            var opacity = motion.opacity * p.depth.opacity
            // Faded in at the top and out at the bottom, so nothing pops in or crowds the tab bar, and faded in as it
            // appears, for the ones that appear on screen.
            opacity *= min(max((p.position.y + 30) / 70, 0), 1) * min(max((size.height - p.position.y) / 90, 0), 1)
            opacity *= min((time - p.born) / 1.5, 1)
            if motion == .drift {
                opacity *= 0.3 + 0.7 * (0.5 + 0.5 * sin(time * (1.2 + p.phase * 0.3) + p.phase))
            }
            guard opacity > 0.01 else { continue }

            var ctx = context
            ctx.opacity = opacity
            ctx.translateBy(x: p.position.x, y: p.position.y)
            ctx.rotate(by: .radians(p.rotation))

            var scale = (x: p.size / ThemeParticles.pieceSize, y: p.size / ThemeParticles.pieceSize)
            switch motion {
            case .flutter:
                // Turning over as it falls, so it narrows and widens.
                scale.x *= max(abs(cos(time * 1.3 + p.phase)), 0.3)
            case .confetti:
                scale.y *= max(abs(cos(time * 4 + p.phase)), 0.15)
            case .fly:
                // Flapping: a bat's wings go up and down, a butterfly's open and close.
                let flap = 0.3 + 0.7 * abs(sin(time * (effect.pieces[p.piece].art == .butterfly ? 7 : 9) + p.phase))
                if effect.pieces[p.piece].art == .butterfly { scale.x *= flap } else { scale.y *= flap }
            case .fall, .drift:
                break
            }
            ctx.scaleBy(x: scale.x, y: scale.y)
            ctx.draw(symbol, at: .zero, anchor: .center)
        }

        // The lights hang in front, over the top of the screen.
        if effect.hasLights, layer == .front { drawLights(in: context, top: topInset) }
    }

    /// Bulbs in four colors, twinkling, on a wire that swags across the top of the screen.
    private func drawLights(in context: GraphicsContext, top: CGFloat) {
        let colors: [Color] = [
            Color(red: 0.95, green: 0.25, blue: 0.25), Color(red: 0.25, green: 0.80, blue: 0.40),
            Color(red: 1, green: 0.80, blue: 0.30), Color(red: 0.35, green: 0.55, blue: 1)
        ]
        // The swags are a fixed width, laid out from the screen's left edge, not the drawing area's: the area can run past the
        // screen on either side, by a different amount before and after the page has loaded. A bulb's place, color and twinkle
        // come from where it is on the screen, so the string looks the same whatever the area is.
        let span: CGFloat = 156
        let anchorY = top - 12
        let sag: CGFloat = 18
        let bulbsPerSwag = max(4, Int(span / 26))
        let firstSwag = Int((originX / span).rounded(.down)) - 1
        let lastSwag = Int(((originX + size.width) / span).rounded(.up)) + 1

        var wire = Path()
        for swag in firstSwag...lastSwag {
            let start = CGPoint(x: CGFloat(swag) * span - originX, y: anchorY)
            let end = CGPoint(x: start.x + span, y: anchorY)
            // A quadratic's control point sits twice as deep as the curve dips.
            let control = CGPoint(x: start.x + span / 2, y: anchorY + sag * 2)
            if swag == firstSwag { wire.move(to: start) }
            wire.addQuadCurve(to: end, control: control)

            for step in 1...bulbsPerSwag {
                let t = CGFloat(step) / CGFloat(bulbsPerSwag + 1)
                let point = CGPoint(
                    x: (1 - t) * (1 - t) * start.x + 2 * (1 - t) * t * control.x + t * t * end.x,
                    y: (1 - t) * (1 - t) * start.y + 2 * (1 - t) * t * control.y + t * t * end.y
                )
                let bulb = swag * bulbsPerSwag + (step - 1)
                let color = colors[((bulb % colors.count) + colors.count) % colors.count]
                let glow = 0.55 + 0.45 * sin(time * 1.6 + Double(bulb) * 1.7)
                var ctx = context
                ctx.translateBy(x: point.x, y: point.y + 4)
                ctx.fill(Path(ellipseIn: CGRect(x: -9, y: -9, width: 18, height: 18)),
                         with: .radialGradient(Gradient(colors: [color.opacity(0.45 * glow), color.opacity(0)]), center: .zero, startRadius: 0, endRadius: 9))
                ctx.opacity = 0.6 + 0.4 * glow
                ctx.fill(Path(ellipseIn: CGRect(x: -2.5, y: -3, width: 5, height: 7)), with: .color(color))
            }
        }
        context.stroke(wire, with: .color(Color(red: 0.15, green: 0.30, blue: 0.18).opacity(0.8)), lineWidth: 1.2)
    }
}
