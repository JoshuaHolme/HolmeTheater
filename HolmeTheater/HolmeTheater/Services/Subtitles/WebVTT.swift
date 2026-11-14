// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

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
            guard let start = SubtitleTimestamp.seconds(from: times[0]),
                  let end = endAndSettings.first.flatMap(SubtitleTimestamp.seconds(from:)) else { continue }

            // A subtitle file converted from another format keeps that format's tags in the text, such as "{\an8}"
            // to put a line at the top.
            let tags = OverrideTags(in: lines[(timingIndex + 1)...].joined(separator: "\n"), onlyTagBlocks: true)
            let text = plainText(of: tags.text)
            guard !text.isEmpty else { continue }

            let placement = placement(settings: endAndSettings.dropFirst())
                ?? tags.alignment.flatMap { SubtitlePlacement.aligned(keypad: $0, left: sideMargin, right: sideMargin, vertical: edgeMargin) }
            cues.append(SubtitleCue(start: start, end: end, text: text, placement: placement))
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// A cue's text without its markup: tags gone, the few entities WebVTT allows decoded.
    static func plainText(of markup: String) -> String {
        markup
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            // Last, so an escaped entity such as "&amp;lt;" isn't decoded a second time.
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Where a cue's settings (after its timing, e.g. "line:10% position:20% align:start") put it, or nil if they don't
    /// move it from the bottom.
    static func placement(settings: ArraySlice<String>) -> SubtitlePlacement? {
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
}
