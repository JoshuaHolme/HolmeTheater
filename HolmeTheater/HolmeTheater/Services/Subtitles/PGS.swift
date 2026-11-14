// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreGraphics
import Foundation

/// Reads the Presentation Graphic Stream subtitles of Blu-ray discs: a series of "display sets", each of which replaces
/// what's on screen with some run-length-encoded pictures in a palette of up to 256 colours.
nonisolated enum PGS {
    /// A picture of the track, still compressed.
    struct Object: Sendable {
        let width: Int
        let height: Int
        let rle: [UInt8]
    }

    /// A picture placed on the canvas, maybe only part of it.
    struct Placement: Sendable {
        let object: Object
        /// Where its top-left corner (or its cropped part's) goes on the canvas.
        let x: Int
        let y: Int
        /// The part of it that shows, in its own pixels.
        let crop: (x: Int, y: Int, width: Int, height: Int)

        var rect: CGRect { CGRect(x: x, y: y, width: crop.width, height: crop.height) }

        /// Decodes the picture into `pixels`, a buffer of `size` whose top-left corner is at `origin` on the canvas. What
        /// falls outside the buffer is left out.
        func draw(into pixels: inout [UInt32], size: (width: Int, height: Int), origin: (x: Int, y: Int), palette: [UInt32]) {
            let rle = object.rle
            let width = size.width
            let offsetX = x - crop.x - origin.x, offsetY = y - crop.y - origin.y
            let (cropMaxX, cropMaxY) = (crop.x + crop.width, crop.y + crop.height)
            var i = 0, column = 0, row = 0

            // Each run is a colour and how many pixels of it: a lone byte is one pixel of that colour, and a zero
            // starts a longer form (or, followed by another zero, ends the line).
            while i < rle.count, row < object.height {
                var colour = rle[i]
                var run = 1
                i += 1
                if colour == 0 {
                    guard i < rle.count else { break }
                    let flags = rle[i]
                    i += 1
                    if flags == 0 {
                        column = 0
                        row += 1
                        continue
                    }
                    run = Int(flags & 0x3F)
                    if flags & 0x40 != 0 {
                        guard i < rle.count else { break }
                        run = run << 8 | Int(rle[i])
                        i += 1
                    }
                    if flags & 0x80 != 0 {
                        guard i < rle.count else { break }
                        colour = rle[i]
                        i += 1
                    }
                }

                let pixel = palette[Int(colour)]
                let targetRow = row + offsetY
                if pixel != 0, row >= crop.y, row < cropMaxY, targetRow >= 0, targetRow < size.height {
                    // Within the crop, the picture and the buffer.
                    let start = max(column, crop.x, -offsetX)
                    let end = min(column + run, cropMaxX, object.width, width - offsetX)
                    if start < end {
                        let base = targetRow * width + offsetX
                        for column in start..<end { pixels[base + column] = pixel }
                    }
                }
                column += run
            }
        }
    }

    /// The pictures in `data`, a `.sup` file, in order. Empty if it isn't one.
    @concurrent static func parse(_ data: Data) async -> [PictureSubtitleCue] {
        cues(in: [UInt8](data))
    }

    /// The pictures in a `.sup` file's bytes, in order. Empty if it isn't one. Synchronous, for callers already off the
    /// main thread, such as tests.
    static func cues(in bytes: [UInt8]) -> [PictureSubtitleCue] {
        func u16(_ at: Int) -> Int { Int(bytes[at]) << 8 | Int(bytes[at + 1]) }
        func u32(_ at: Int) -> Int { u16(at) << 16 | u16(at + 2) }

        /// What a display set's opening segment says to show.
        struct Composition {
            let start: TimeInterval
            let canvas: CGSize
            let paletteID: UInt8
            let placements: [(objectID: Int, x: Int, y: Int, crop: (x: Int, y: Int, width: Int, height: Int)?)]
        }

        var cues: [PictureSubtitleCue] = []
        // What's been defined so far in the current "epoch": a display set may reuse the pictures and palettes of
        // earlier ones, e.g. changing only the palette to fade a picture out.
        var palettes: [UInt8: [UInt32]] = [:]
        var objects: [Int: Object] = [:]
        var partialObjects: [Int: (width: Int, height: Int, rle: [UInt8])] = [:]
        var composition: Composition?

        var at = 0
        // Each segment: "PG", the time it shows (90 kHz ticks), the time it's decoded, its type and its length.
        while at + 13 <= bytes.count, bytes[at] == 0x50, bytes[at + 1] == 0x47 {
            let time = TimeInterval(u32(at + 2)) / 90_000
            let type = bytes[at + 10]
            let body = at + 13
            let end = body + u16(at + 11)
            guard end <= bytes.count else { break }
            at = end

            switch type {
            case 0x16 where end - body >= 11: // Presentation composition: what to show, and where.
                // The start of an epoch: nothing from before carries over.
                if bytes[body + 7] & 0x80 != 0 {
                    palettes = [:]
                    objects = [:]
                    partialObjects = [:]
                }
                var placements: [(objectID: Int, x: Int, y: Int, crop: (x: Int, y: Int, width: Int, height: Int)?)] = []
                var p = body + 11
                for _ in 0..<bytes[body + 10] {
                    guard p + 8 <= end else { break }
                    let isCropped = bytes[p + 3] & 0x80 != 0
                    var crop: (x: Int, y: Int, width: Int, height: Int)?
                    if isCropped {
                        guard p + 16 <= end else { break }
                        crop = (u16(p + 8), u16(p + 10), u16(p + 12), u16(p + 14))
                    }
                    placements.append((u16(p), u16(p + 4), u16(p + 6), crop))
                    p += isCropped ? 16 : 8
                }
                composition = Composition(
                    start: time,
                    canvas: CGSize(width: u16(body), height: u16(body + 2)),
                    paletteID: bytes[body + 9],
                    placements: placements
                )

            case 0x14 where end - body >= 2: // Palette: colours by number, in YCbCr.
                // HD pictures use the HD colour space's conversion, as the video does.
                let isHD = (composition?.canvas.height ?? 1080) > 576
                var palette = palettes[bytes[body]] ?? [UInt32](repeating: 0, count: 256)
                var p = body + 2
                while p + 5 <= end {
                    palette[Int(bytes[p])] = rgba(y: bytes[p + 1], cr: bytes[p + 2], cb: bytes[p + 3], alpha: bytes[p + 4], isHD: isHD)
                    p += 5
                }
                palettes[bytes[body]] = palette

            case 0x15 where end - body >= 4: // Object: a picture, maybe split over several segments.
                let id = u16(body)
                let sequence = bytes[body + 3]
                if sequence & 0x80 != 0 {
                    // The first carries the picture's size (after the length of all its data, which isn't needed).
                    guard end - body >= 11 else { break }
                    partialObjects[id] = (u16(body + 7), u16(body + 9), Array(bytes[(body + 11)..<end]))
                } else {
                    partialObjects[id]?.rle.append(contentsOf: bytes[(body + 4)..<end])
                }
                if sequence & 0x40 != 0, let done = partialObjects.removeValue(forKey: id) {
                    objects[id] = Object(width: done.width, height: done.height, rle: done.rle)
                }

            case 0x80: // End of the display set: it takes over the screen.
                guard let shown = composition else { break }
                composition = nil
                // Whatever was showing goes, even if this shows nothing (as most do every other time, to clear the screen).
                if let last = cues.indices.last, cues[last].end > shown.start {
                    cues[last].end = shown.start
                }
                let placements = shown.placements.compactMap { placed -> Placement? in
                    guard let object = objects[placed.objectID], object.width > 0, object.height > 0 else { return nil }
                    // A crop is kept within the picture, so drawing never goes outside the space made for it.
                    let crop = placed.crop.map { crop in
                        let x = min(crop.x, object.width), y = min(crop.y, object.height)
                        return (x, y, min(crop.width, object.width - x), min(crop.height, object.height - y))
                    } ?? (0, 0, object.width, object.height)
                    return Placement(object: object, x: placed.x, y: placed.y, crop: crop)
                }
                guard !placements.isEmpty, shown.canvas.width > 0, shown.canvas.height > 0,
                      let palette = palettes[shown.paletteID] else { break }
                // Until the next display set replaces it.
                cues.append(PictureSubtitleCue(start: shown.start, end: .infinity, canvas: shown.canvas, placements: placements, palette: palette))

            default: // Window definitions, which only say where the pictures may go, and malformed segments.
                break
            }
        }

        // A last picture nothing clears shows for a while, not for the rest of the video.
        if let last = cues.indices.last, cues[last].end == .infinity {
            cues[last].end = cues[last].start + 5
        }
        return cues
    }

    /// A palette colour (studio-range YCbCr) as premultiplied RGBA, packed in the order of the bytes in memory.
    static func rgba(y: UInt8, cr: UInt8, cb: UInt8, alpha: UInt8, isHD: Bool) -> UInt32 {
        let luma = 1.164 * (Double(y) - 16), red = Double(cr) - 128, blue = Double(cb) - 128
        let (r, g, b) = isHD
            ? (luma + 1.793 * red, luma - 0.213 * blue - 0.533 * red, luma + 2.112 * blue) // BT.709
            : (luma + 1.596 * red, luma - 0.392 * blue - 0.813 * red, luma + 2.017 * blue) // BT.601
        let a = Double(alpha) / 255
        func byte(_ value: Double) -> UInt32 { UInt32(min(max(value, 0), 255) * a) }
        return (byte(r) << 24 | byte(g) << 16 | byte(b) << 8 | UInt32(alpha)).bigEndian
    }
}
