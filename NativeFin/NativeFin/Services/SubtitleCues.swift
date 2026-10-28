// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// One line of subtitles and when it shows.
nonisolated struct SubtitleCue: Hashable, Sendable {
    /// When it appears and disappears, in seconds from the start of the video.
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

/// Reads the WebVTT the server converts every text subtitle track to.
nonisolated enum WebVTT {
    static func parse(_ source: String) -> [SubtitleCue] {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [SubtitleCue] = []

        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.components(separatedBy: "\n")
            // A cue may start with an identifier line before its timing line.
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let times = lines[timingIndex].components(separatedBy: "-->")
            guard times.count == 2,
                  let start = seconds(from: times[0]),
                  let end = seconds(from: times[1].split(separator: " ").first.map(String.init) ?? "")
            else { continue }

            let text = lines[(timingIndex + 1)...]
                .joined(separator: "\n")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\{\\\\[^}]*\\}", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { cues.append(SubtitleCue(start: start, end: end, text: text)) }
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// "01:02:03.456", "02:03.456" or with a comma before the milliseconds.
    private static func seconds(from timestamp: String) -> TimeInterval? {
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
