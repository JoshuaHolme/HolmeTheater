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
    init(x: Double, y: Double, keypad: Int) {
        let column = (keypad - 1) % 3, row = (keypad - 1) / 3
        self.x = x
        self.y = y
        horizontal = [.start, .center, .end][column]
        vertical = [.end, .center, .start][row]
    }

    init(x: Double, y: Double, horizontal: Anchor, vertical: Anchor) {
        (self.x, self.y, self.horizontal, self.vertical) = (x, y, horizontal, vertical)
    }

    /// For a keypad alignment with no point of its own: in that corner or at that edge of the picture, `margins` in from
    /// its sides (`horizontal`) and its top or bottom (`vertical`), as fractions of it. Nil for bottom center, the usual place.
    static func aligned(keypad: Int, left: Double, right: Double, vertical: Double) -> SubtitlePlacement? {
        guard (1...9).contains(keypad), keypad != 2 else { return nil }
        let column = (keypad - 1) % 3, row = (keypad - 1) / 3
        let x = [left, (left + 1 - right) / 2, 1 - right][column]
        let y = [1 - vertical, 0.5, vertical][row]
        return SubtitlePlacement(x: x, y: y, keypad: keypad)
    }
}

/// How a subtitle timestamp is read, shared by the text formats.
nonisolated enum SubtitleTimestamp {
    /// "01:02:03.456", "02:03.456" or with a comma before the milliseconds. Nil for anything else.
    static func seconds(from timestamp: String) -> TimeInterval? {
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
