// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreGraphics
import Foundation

/// One line of subtitles and when it shows.
nonisolated struct SubtitleCue: Hashable, Sendable {
    /// When it appears and disappears, in seconds from the start of the video.
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    /// Where the track puts it, or nil for the usual place along the bottom.
    var placement: SubtitlePlacement? = nil
}

/// Where on the picture a line of subtitles goes, for a track that puts some somewhere other than along the bottom: a
/// sign's translation next to the sign, say, or a line moved to the top so it doesn't cover something.
nonisolated struct SubtitlePlacement: Hashable, Sendable {
    /// Which side of the text sits on the point, or its middle.
    nonisolated enum Anchor: Hashable, Sendable {
        case start, center, end

        /// How far across (or down) the text the point is: 0, ½ or 1.
        var fraction: Double {
            switch self {
            case .start: 0
            case .center: 0.5
            case .end: 1
            }
        }
    }

    /// The point, as fractions of the picture's width and height from its top-left corner.
    let x: Double
    let y: Double
    /// Which part of the text is at the point: its left, middle or right, and its top, middle or bottom.
    let horizontal: Anchor
    let vertical: Anchor

    /// From a SubStation Alpha alignment, numbered as on a keypad (1 is bottom left, 9 top right), and the point it's at.
    fileprivate init(x: Double, y: Double, keypad: Int) {
        let column = (keypad - 1) % 3, row = (keypad - 1) / 3
        self.x = x
        self.y = y
        horizontal = [.start, .center, .end][column]
        vertical = [.end, .center, .start][row]
    }

    fileprivate init(x: Double, y: Double, horizontal: Anchor, vertical: Anchor) {
        (self.x, self.y, self.horizontal, self.vertical) = (x, y, horizontal, vertical)
    }

    /// For a keypad alignment with no point of its own: in that corner or at that edge of the picture, `margins` in from
    /// its sides (`horizontal`) and its top or bottom (`vertical`), as fractions of it. Nil for bottom center, the usual place.
    fileprivate static func aligned(keypad: Int, left: Double, right: Double, vertical: Double) -> SubtitlePlacement? {
        guard (1...9).contains(keypad), keypad != 2 else { return nil }
        let column = (keypad - 1) % 3, row = (keypad - 1) / 3
        let x = [left, (left + 1 - right) / 2, 1 - right][column]
        let y = [1 - vertical, 0.5, vertical][row]
        return SubtitlePlacement(x: x, y: y, keypad: keypad)
    }
}

/// Reads the WebVTT the server converts most text subtitle tracks to.
nonisolated enum WebVTT {
    /// The edges the server leaves around lines it places by alignment alone, as fractions of the picture: the same as
    /// the usual place along the bottom.
    private static let sideMargin = 0.08, edgeMargin = 0.06

    static func parse(_ source: String) -> [SubtitleCue] {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [SubtitleCue] = []

        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.components(separatedBy: "\n")
            // A cue may start with an identifier line before its timing line.
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let times = lines[timingIndex].components(separatedBy: "-->")
            let endAndSettings = times.count == 2 ? times[1].split(separator: " ").map(String.init) : []
            guard let start = seconds(from: times[0]), let end = endAndSettings.first.flatMap(seconds(from:)) else { continue }

            // A subtitle file converted from another format keeps that format's tags in the text, such as "{\an8}"
            // to put a line at the top.
            let tags = OverrideTags(in: lines[(timingIndex + 1)...].joined(separator: "\n"), onlyTagBlocks: true)
            let text = tags.text
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&nbsp;", with: " ")
                // Last, so an escaped entity such as "&amp;lt;" isn't decoded a second time.
                .replacingOccurrences(of: "&amp;", with: "&")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let placement = placement(settings: endAndSettings.dropFirst())
                ?? tags.alignment.flatMap { SubtitlePlacement.aligned(keypad: $0, left: sideMargin, right: sideMargin, vertical: edgeMargin) }
            cues.append(SubtitleCue(start: start, end: end, text: text, placement: placement))
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// Where a cue's settings (after its timing, e.g. "line:10% position:20% align:start") put it, or nil if they don't
    /// move it from the bottom.
    private static func placement(settings: ArraySlice<String>) -> SubtitlePlacement? {
        var line: (value: Double, isPercent: Bool, anchor: SubtitlePlacement.Anchor?)?
        var position: (value: Double, anchor: SubtitlePlacement.Anchor?)?
        var align: SubtitlePlacement.Anchor = .center

        /// "start", "center" and "end", and their other names.
        func anchor(_ name: Substring?) -> SubtitlePlacement.Anchor? {
            switch name {
            case "start", "left", "line-left": .start
            case "center", "middle": .center
            case "end", "right", "line-right": .end
            default: nil
            }
        }

        for setting in settings {
            let parts = setting.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let (name, value) = (parts[0], parts[1].split(separator: ",", maxSplits: 1))
            guard let first = value.first else { continue }
            let isPercent = first.hasSuffix("%")
            let number = Double(isPercent ? first.dropLast() : first)
            switch name {
            case "line": if let number { line = (number, isPercent, anchor(value.dropFirst().first)) }
            case "position": if let number, isPercent { position = (number / 100, anchor(value.dropFirst().first)) }
            case "align": align = anchor(first) ?? .center
            default: break
            }
        }

        // A line number counts lines from the top, or from the bottom if negative, where -1 is the usual place. About
        // eighteen fit on the picture.
        let lineHeight = (1 - 2 * edgeMargin) / 17
        var y = 1 - edgeMargin, vertical = SubtitlePlacement.Anchor.end
        if let line {
            if line.isPercent {
                (y, vertical) = (line.value / 100, line.anchor ?? .start)
            } else if line.value >= 0 {
                (y, vertical) = (edgeMargin + line.value * lineHeight, .start)
            } else if line.value < -1 {
                y = 1 - edgeMargin - (-line.value - 1) * lineHeight
            }
        }
        let x = position?.value ?? 0.5
        let horizontal = position?.anchor ?? (position == nil ? .center : align)

        guard y != 1 - edgeMargin || vertical != .end || x != 0.5 || horizontal != .center else { return nil }
        return SubtitlePlacement(x: x, y: min(max(y, 0), 1), horizontal: horizontal, vertical: vertical)
    }

    /// "01:02:03.456", "02:03.456" or with a comma before the milliseconds.
    fileprivate static func seconds(from timestamp: String) -> TimeInterval? {
        let parts = timestamp.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var total: TimeInterval = 0
        for part in parts {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }
}

/// Reads SubStation Alpha (`.ass` and `.ssa`) subtitles as they are, rather than converted to WebVTT, which loses the
/// size of the picture positions are measured on and the alignment each style gives its lines.
nonisolated enum SubStationAlpha {
    private struct Style {
        /// Numbered as on a keypad.
        var alignment = 2
        var marginLeft: Double = 0, marginRight: Double = 0, marginVertical: Double = 0
    }

    static func parse(_ source: String) -> [SubtitleCue] {
        var section = ""
        var width: Double?, height: Double?
        var styleFormat: [String] = []
        // As the format says it is when a file doesn't say.
        var eventFormat = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
        var styles: [String: Style] = [:]
        var events: [[String: String]] = []

        for rawLine in source.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\u{FEFF}")))
            if line.hasPrefix("[") {
                section = line.lowercased()
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

            /// The fields of a line in the order `format` lists them, the last taking the rest (the text may have commas).
            func fields(_ format: [String]) -> [String: String] {
                let values = value.split(separator: ",", maxSplits: max(format.count - 1, 0), omittingEmptySubsequences: false)
                return Dictionary(zip(format, values.map { $0.trimmingCharacters(in: .whitespaces) }), uniquingKeysWith: { first, _ in first })
            }

            switch key {
            case "playresx" where section == "[script info]": width = Double(value)
            case "playresy" where section == "[script info]": height = Double(value)
            case "format" where section.hasSuffix("styles]"):
                styleFormat = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            case "style" where section.hasSuffix("styles]"):
                let style = fields(styleFormat)
                guard let name = style["name"] else { continue }
                // The older format numbers its alignments differently.
                let alignment = Int(style["alignment"] ?? "").map { section == "[v4 styles]" ? keypad(fromLegacy: $0) : $0 } ?? 2
                styles[name.lowercased()] = Style(
                    alignment: (1...9).contains(alignment) ? alignment : 2,
                    marginLeft: Double(style["marginl"] ?? "") ?? 0,
                    marginRight: Double(style["marginr"] ?? "") ?? 0,
                    marginVertical: Double(style["marginv"] ?? "") ?? 0
                )
            case "format" where section == "[events]":
                eventFormat = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            case "dialogue" where section == "[events]":
                events.append(fields(eventFormat))
            default:
                break
            }
        }

        // The size positions are measured on. A file that leaves it out means the format's default, and one that gives
        // only one side means a 4:3 picture, as players have always taken it.
        let (playWidth, playHeight): (Double, Double) = switch (width, height) {
        case let (width?, height?) where width > 0 && height > 0: (width, height)
        case let (width?, _) where width > 0: (width, width == 1280 ? 1024 : width * 3 / 4)
        case let (_, height?) where height > 0: (height == 1024 ? 1280 : height * 4 / 3, height)
        default: (384, 288)
        }

        let cues = events.compactMap { event -> SubtitleCue? in
            guard let start = event["start"].flatMap(WebVTT.seconds(from:)),
                  let end = event["end"].flatMap(WebVTT.seconds(from:)), end > start else { return nil }
            let tags = OverrideTags(in: event["text"] ?? "", onlyTagBlocks: false)
            // Drawn shapes, whose "text" is the outline's coordinates.
            guard !tags.isDrawing else { return nil }
            let text = tags.text
                .replacingOccurrences(of: "\\N", with: "\n")
                // A line break only if the file wraps no lines itself, which is rare: a space otherwise.
                .replacingOccurrences(of: "\\n", with: " ")
                .replacingOccurrences(of: "\\h", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }

            // Some files mark the default style's name with a star.
            let styleName = (event["style"] ?? "").lowercased()
            let style = styles[styleName.hasPrefix("*") ? String(styleName.dropFirst()) : styleName] ?? styles["default"] ?? Style()
            /// A margin the line sets for itself (anything but 0), else its style's.
            func margin(_ key: String, _ fallback: Double) -> Double {
                Double(event[key] ?? "").flatMap { $0 == 0 ? nil : $0 } ?? fallback
            }
            let alignment = tags.alignment ?? style.alignment
            let placement: SubtitlePlacement? = if let position = tags.position {
                SubtitlePlacement(x: position.x / playWidth, y: position.y / playHeight, keypad: alignment)
            } else {
                SubtitlePlacement.aligned(
                    keypad: alignment,
                    left: margin("marginl", style.marginLeft) / playWidth,
                    right: margin("marginr", style.marginRight) / playWidth,
                    vertical: margin("marginv", style.marginVertical) / playHeight
                )
            }
            return SubtitleCue(start: start, end: end, text: text, placement: placement)
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// The older format's alignment as a keypad number: 1–3 along the bottom, 5–7 along the top, 9–11 in the middle.
    fileprivate static func keypad(fromLegacy alignment: Int) -> Int {
        switch alignment {
        case 1...3: alignment
        case 5...7: alignment + 2
        case 9...11: alignment - 5
        default: 2
        }
    }
}

/// The SubStation Alpha tags in a line of subtitles, such as `{\an8}` or `{\pos(320,50)}`, which say how it's drawn; and
/// the line without them. Only where a line goes is kept: the rest (fonts, colours, effects) is left to the app's style.
private nonisolated struct OverrideTags {
    private(set) var text = ""
    /// Numbered as on a keypad.
    private(set) var alignment: Int?
    /// On the picture the file measures positions on.
    private(set) var position: (x: Double, y: Double)?
    /// Whether the line draws a shape rather than text.
    private(set) var isDrawing = false

    /// - Parameter onlyTagBlocks: Whether to leave braces that don't start with a tag, as a format with no tags of its
    ///   own may well mean them as text. SubStation Alpha hides anything in braces.
    init(in line: String, onlyTagBlocks: Bool) {
        var rest = Substring(line)
        while let open = rest.firstIndex(of: "{") {
            guard let close = rest[open...].firstIndex(of: "}") else { break }
            let block = rest[rest.index(after: open)..<close]
            if onlyTagBlocks && !block.hasPrefix("\\") {
                text += rest[...open]
                rest = rest[rest.index(after: open)...]
                continue
            }
            text += rest[..<open]
            rest = rest[rest.index(after: close)...]
            for tag in block.split(separator: "\\") { read(tag) }
        }
        text += rest
    }

    private mutating func read(_ tag: Substring) {
        /// The numbers in a tag's brackets, e.g. those of "pos(320,50)".
        func arguments(after name: String) -> [Double] {
            tag.dropFirst(name.count).trimmingCharacters(in: CharacterSet(charactersIn: "() "))
                .split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        }

        if tag.hasPrefix("an"), let value = Int(tag.dropFirst(2)), (1...9).contains(value) {
            alignment = alignment ?? value
        } else if tag.hasPrefix("a"), let value = Int(tag.dropFirst()) {
            alignment = alignment ?? SubStationAlpha.keypad(fromLegacy: value)
        } else if tag.hasPrefix("pos(") {
            let values = arguments(after: "pos")
            if values.count >= 2, position == nil { position = (values[0], values[1]) }
        } else if tag.hasPrefix("move(") {
            // Where it starts out: the app doesn't move it.
            let values = arguments(after: "move")
            if values.count >= 4, position == nil { position = (values[0], values[1]) }
        } else if tag.hasPrefix("p"), let level = Int(tag.dropFirst()), level > 0 {
            isDrawing = true
        }
    }
}

/// One picture of an image-based subtitle track, and when it shows. Its pixels stay compressed until it's on screen
/// (see ``image()``): an episode has hundreds, which decoded would take hundreds of megabytes.
nonisolated struct PictureSubtitleCue: Sendable {
    /// When it appears and disappears, in seconds from the start of the video.
    let start: TimeInterval
    fileprivate(set) var end: TimeInterval

    /// The picture the positions are measured on, usually the video's own size (1920 × 1080 on a Blu-ray).
    let canvas: CGSize

    fileprivate let placements: [PGS.Placement]

    /// Colours by number, as premultiplied RGBA packed big-endian. All 256, the ones the track doesn't set transparent.
    fileprivate let palette: [UInt32]

    /// Draws the picture: everything in it, cut down to the part of the canvas it covers.
    func image() -> PictureSubtitle? {
        let rects = placements.map(\.rect)
        guard let bounds = rects.first.map({ rects.dropFirst().reduce($0) { $0.union($1) } }),
              bounds.width > 0, bounds.height > 0 else { return nil }
        let width = Int(bounds.width), height = Int(bounds.height)
        var pixels = [UInt32](repeating: 0, count: width * height)
        for placement in placements {
            placement.draw(into: &pixels, width: width, origin: (Int(bounds.minX), Int(bounds.minY)), palette: palette)
        }

        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              )
        else { return nil }
        return PictureSubtitle(image: image, rect: bounds, canvas: canvas)
    }
}

/// A subtitle picture ready to draw, and where it goes.
nonisolated struct PictureSubtitle {
    let image: CGImage
    /// Where it goes on ``canvas``, in its pixels.
    let rect: CGRect
    let canvas: CGSize

    /// Where it goes on the screen, given where the video is on it (`video`) and the screen's own bounds.
    func rect(onVideo video: CGRect, within screen: CGRect) -> CGRect {
        let canvasFrame = Self.canvasFrame(canvas, onVideo: video)
        let scaleX = canvasFrame.width / canvas.width, scaleY = canvasFrame.height / canvas.height
        var placed = CGRect(x: canvasFrame.minX + rect.minX * scaleX, y: canvasFrame.minY + rect.minY * scaleY,
                            width: rect.width * scaleX, height: rect.height * scaleY)
        // On a screen narrower than the canvas, a cropped video's lines along the bottom of the canvas (its black bars,
        // once) could be off the bottom: they're moved up just enough to show. A picture inside the video never moves.
        if placed.width <= screen.width { placed.origin.x = min(max(placed.minX, screen.minX), screen.maxX - placed.width) }
        if placed.height <= screen.height { placed.origin.y = min(max(placed.minY, screen.minY), screen.maxY - placed.height) }
        return placed
    }

    /// Where the canvas goes, given where the video is.
    ///
    /// Usually just the video's frame: the canvas is the video's size (or the shape it's shown at, for one stored
    /// squeezed, as DVD-sized pictures often are). But a Blu-ray's video is a 16:9 frame with the film in it, black bars
    /// and all, which a rip may crop down to the film; its subtitles still measure positions on the whole frame. So a
    /// 16:9 high-definition canvas on a video of another shape is drawn at the video's scale and centered on it, as the
    /// frame was, rather than stretched to the video's shape.
    static func canvasFrame(_ canvas: CGSize, onVideo video: CGRect) -> CGRect {
        guard canvas.width > 0, canvas.height > 0, video.width > 0, video.height > 0 else { return video }
        let canvasAspect = canvas.width / canvas.height, videoAspect = video.width / video.height
        let isHDFrame = abs(canvasAspect - 16.0 / 9) < 0.01 && canvas.height >= 720
        guard isHDFrame, abs(canvasAspect - videoAspect) / videoAspect > 0.02 else { return video }
        // Cropped top and bottom (wider than the frame), the widths match; cropped at the sides, the heights do.
        let scale = max(video.width / canvas.width, video.height / canvas.height)
        let size = CGSize(width: canvas.width * scale, height: canvas.height * scale)
        return CGRect(x: video.midX - size.width / 2, y: video.midY - size.height / 2, width: size.width, height: size.height)
    }
}

extension [PictureSubtitleCue] {
    /// The index of the cue showing at `time`, if any. The cues are in order and never overlap.
    func index(at time: TimeInterval) -> Int? {
        var low = 0, high = count
        // The first cue starting after `time`; the one before it is the only one that can be showing.
        while low < high {
            let middle = (low + high) / 2
            if self[middle].start <= time { low = middle + 1 } else { high = middle }
        }
        guard low > 0, time < self[low - 1].end else { return nil }
        return low - 1
    }
}

/// Reads the Presentation Graphic Stream subtitles of Blu-ray discs: a series of "display sets", each of which replaces
/// what's on screen with some run-length-encoded pictures in a palette of up to 256 colours.
nonisolated enum PGS {
    /// A picture of the track, still compressed.
    fileprivate struct Object: Sendable {
        let width: Int
        let height: Int
        let rle: [UInt8]
    }

    /// A picture placed on the canvas, maybe only part of it.
    fileprivate struct Placement: Sendable {
        let object: Object
        /// Where its top-left corner (or its cropped part's) goes on the canvas.
        let x: Int
        let y: Int
        /// The part of it that shows, in its own pixels.
        let crop: (x: Int, y: Int, width: Int, height: Int)

        var rect: CGRect { CGRect(x: x, y: y, width: crop.width, height: crop.height) }

        /// Decodes the picture into `pixels`, a buffer `width` wide whose top-left corner is at `origin` on the canvas.
        func draw(into pixels: inout [UInt32], width: Int, origin: (x: Int, y: Int), palette: [UInt32]) {
            let rle = object.rle
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
                if pixel != 0, row >= crop.y, row < cropMaxY {
                    let start = max(column, crop.x), end = min(column + run, cropMaxX, object.width)
                    if start < end {
                        let base = (row + offsetY) * width + offsetX
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

    private static func cues(in bytes: [UInt8]) -> [PictureSubtitleCue] {
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
    private static func rgba(y: UInt8, cr: UInt8, cb: UInt8, alpha: UInt8, isHD: Bool) -> UInt32 {
        let luma = 1.164 * (Double(y) - 16), red = Double(cr) - 128, blue = Double(cb) - 128
        let (r, g, b) = isHD
            ? (luma + 1.793 * red, luma - 0.213 * blue - 0.533 * red, luma + 2.112 * blue) // BT.709
            : (luma + 1.596 * red, luma - 0.392 * blue - 0.813 * red, luma + 2.017 * blue) // BT.601
        let a = Double(alpha) / 255
        func byte(_ value: Double) -> UInt32 { UInt32(min(max(value, 0), 255) * a) }
        return (byte(r) << 24 | byte(g) << 16 | byte(b) << 8 | UInt32(alpha)).bigEndian
    }
}
