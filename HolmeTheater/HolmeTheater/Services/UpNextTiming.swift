// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// When the "Up Next" card appears near the end of an episode. Pure, so both players share it and it can be tested.
nonisolated enum UpNextTiming {
    /// With no credits marked by the server, the card appears this long before the end: longer than the countdown, so
    /// the countdown has time to run, with a little to spare.
    static let fallbackLead: TimeInterval = 45

    /// The card never appears later than this before the very end.
    static let latestLead: TimeInterval = 10

    /// When the card should appear, in seconds from the start: where the server says the credits start, if that's in the
    /// second half, else a fixed lead before the end. Never later than ``latestLead`` from the end.
    ///
    /// - Parameter outroStart: The start of a credits ("outro") marker past the halfway point, if the server gave one.
    static func appearance(duration: TimeInterval, outroStart: TimeInterval?) -> TimeInterval {
        let latest = duration - latestLead
        if let outroStart, outroStart > duration / 2 {
            return min(outroStart, latest)
        }
        return min(duration - fallbackLead, latest)
    }

    /// Whether the card is showing at `position`: from its appearance to just past the end.
    static func isShowing(position: TimeInterval, duration: TimeInterval, outroStart: TimeInterval?) -> Bool {
        guard duration > 60 else { return false }
        return position >= appearance(duration: duration, outroStart: outroStart) && position < duration + 1
    }
}
