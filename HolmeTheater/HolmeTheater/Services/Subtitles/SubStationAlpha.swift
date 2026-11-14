// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

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

        let (playWidth, playHeight) = playResolution(width: width, height: height)

        let cues = events.compactMap { event -> SubtitleCue? in
            guard let start = event["start"].flatMap(SubtitleTimestamp.seconds(from:)),
                  let end = event["end"].flatMap(SubtitleTimestamp.seconds(from:)), end > start else { return nil }
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

    /// The size positions are measured on. A file that leaves it out means the format's default, and one that gives
    /// only one side means a 4:3 picture, as players have always taken it.
    static func playResolution(width: Double?, height: Double?) -> (width: Double, height: Double) {
        switch (width, height) {
        case let (width?, height?) where width > 0 && height > 0: (width, height)
        case let (width?, _) where width > 0: (width, width == 1280 ? 1024 : width * 3 / 4)
        case let (_, height?) where height > 0: (height == 1024 ? 1280 : height * 4 / 3, height)
        default: (384, 288)
        }
    }

    /// The older format's alignment as a keypad number: 1–3 along the bottom, 5–7 along the top, 9–11 in the middle.
    static func keypad(fromLegacy alignment: Int) -> Int {
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
nonisolated struct OverrideTags {
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
