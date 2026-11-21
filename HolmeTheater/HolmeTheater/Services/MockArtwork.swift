// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Abstract artwork for ``MockMediaService``: soft gradients and blurred shapes, with no text or imagery, so screens
/// and App Store screenshots look finished without using anyone's real posters.
///
/// Each image is drawn once from its name, so the same item always gets the same art, and saved as a PNG in Caches.
/// ``ImageCache`` reads `file:` URLs directly, so the rest of the app loads these like any other artwork.
nonisolated enum MockArtwork {
    /// The shapes an image can take, with the size it's drawn at.
    enum Shape {
        case poster, backdrop, still, portrait

        var size: (width: Int, height: Int) {
            switch self {
            case .poster: (600, 900)
            case .backdrop: (1920, 1080)
            case .still: (960, 540)
            case .portrait: (400, 400)
            }
        }
    }

    /// Color pairs that read as cinematic together: a base and an accent.
    private static let palettes: [(base: [CGFloat], accent: [CGFloat])] = [
        ([0.05, 0.16, 0.28], [0.95, 0.55, 0.25]),   // teal night and amber
        ([0.18, 0.07, 0.26], [0.93, 0.35, 0.55]),   // plum and rose
        ([0.04, 0.20, 0.18], [0.55, 0.85, 0.65]),   // deep green and mint
        ([0.25, 0.08, 0.06], [0.98, 0.70, 0.30]),   // ember and gold
        ([0.06, 0.08, 0.24], [0.40, 0.65, 1.00]),   // midnight and sky
        ([0.22, 0.17, 0.10], [0.95, 0.85, 0.60]),   // umber and cream
        ([0.10, 0.05, 0.20], [0.35, 0.90, 0.95]),   // violet and cyan
        ([0.20, 0.10, 0.16], [1.00, 0.62, 0.45]),   // wine and peach
        ([0.03, 0.12, 0.14], [0.85, 0.95, 0.55]),   // ink and lime
        ([0.14, 0.14, 0.18], [0.75, 0.70, 1.00])    // slate and lavender
    ]

    /// Where the artwork is saved.
    private static let directory = URL.cachesDirectory.appending(path: "MockArtwork", directoryHint: .isDirectory)

    /// The artwork for `name` in `shape`, drawing and saving it first if it isn't there yet.
    ///
    /// - Returns: A `file:` URL to the PNG, or `nil` if it couldn't be saved.
    static func url(for name: String, _ shape: Shape) -> URL? {
        let url = directory.appending(path: "\(name)-\(shape).png")
        if FileManager.default.fileExists(atPath: url.path()) { return url }
        guard let image = draw(seed: stableHash(name), shape: shape) else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? url : nil
    }

    /// Draws one image: a diagonal wash between the palette's colors, a few soft glows, and a darkened lower edge so
    /// the app's text over backdrops stays readable.
    private static func draw(seed: UInt64, shape: Shape) -> CGImage? {
        var random = SeededRandom(seed: seed)
        let (width, height) = shape.size
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        let paletteIndex = Int(random.next() % UInt64(palettes.count))
        let palette = palettes[paletteIndex]
        // A second accent from another palette, so pictures sharing a palette still differ.
        let otherAccent = palettes[(paletteIndex + 1 + Int(random.next() % UInt64(palettes.count - 1))) % palettes.count].accent
        let w = CGFloat(width), h = CGFloat(height)

        // A wash from the base color to a darker or lighter take on it, at a random angle.
        let shift = random.unit() * 0.5 - 0.15
        let second = palette.base.map { min(max($0 + shift * 0.4, 0), 1) }
        if let wash = CGGradient(colorSpace: space, colorComponents: palette.base + [1] + second + [1], locations: [0, 1], count: 2) {
            let angle = random.unit() * .pi * 2
            let center = CGPoint(x: w / 2, y: h / 2), reach = max(w, h) * 0.7
            context.drawLinearGradient(
                wash,
                start: CGPoint(x: center.x - cos(angle) * reach, y: center.y - sin(angle) * reach),
                end: CGPoint(x: center.x + cos(angle) * reach, y: center.y + sin(angle) * reach),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }

        // Soft glows: the main accent, then the second one, then blends, each fading to nothing at its edge.
        let glowCount = 3 + Int(random.next() % 3)
        for index in 0..<glowCount {
            let accent = index == 1 ? otherAccent : palette.accent
            let mix = index < 2 ? 0 : random.unit() * 0.4
            let color = zip(accent, palette.base).map { $0 * (1 - mix) + $1 * mix }
            let alpha = index == 0 ? 0.95 : 0.5 + random.unit() * 0.35
            let radius = max(w, h) * (index == 0 ? 0.45 + random.unit() * 0.25 : 0.25 + random.unit() * 0.35)
            let center = CGPoint(x: w * random.unit(), y: h * (0.15 + random.unit() * 0.7))
            guard let glow = CGGradient(colorSpace: space, colorComponents: color + [alpha] + color + [0], locations: [0, 1], count: 2) else { continue }
            context.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
        }

        // A few faint bands crossing the image, like light through a window, for some structure.
        context.saveGState()
        context.setBlendMode(.softLight)
        let bandCount = 2 + Int(random.next() % 3)
        for _ in 0..<bandCount {
            context.setFillColor(CGColor(gray: 1, alpha: 0.05 + random.unit() * 0.08))
            let bandWidth = w * (0.04 + random.unit() * 0.12)
            let x = w * random.unit()
            let path = CGMutablePath()
            path.addLines(between: [
                CGPoint(x: x, y: h), CGPoint(x: x + bandWidth, y: h),
                CGPoint(x: x + bandWidth + w * 0.35, y: 0), CGPoint(x: x + w * 0.35, y: 0)
            ])
            context.addPath(path)
            context.fillPath()
        }
        context.restoreGState()

        // Darker toward the bottom (CoreGraphics' origin is bottom-left), where the app puts text over artwork.
        if let shade = CGGradient(colorSpace: space, colorComponents: [0, 0, 0, 0.45, 0, 0, 0, 0], locations: [0, 0.55], count: 2) {
            context.drawLinearGradient(shade, start: .zero, end: CGPoint(x: 0, y: h), options: [])
        }

        return context.makeImage()
    }

    /// FNV-1a, so a name hashes the same on every launch (Swift's `hashValue` changes between runs).
    private static func stableHash(_ string: String) -> UInt64 {
        string.utf8.reduce(0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
    }

    /// A small deterministic generator (SplitMix64), so each name always draws the same picture.
    private struct SeededRandom {
        var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9e37_79b9_7f4a_7c15
            var z = state
            z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
            z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
            return z ^ (z >> 31)
        }

        /// A value from 0 up to 1.
        mutating func unit() -> CGFloat { CGFloat(next() >> 11) / CGFloat(1 << 53) }
    }
}
