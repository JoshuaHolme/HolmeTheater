// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Formats a playback position as a clock, shared by the player's controls.
nonisolated enum TimeCode {
    /// "M:SS" under an hour, "H:MM:SS" at or over one. Negative or non-finite values read as zero.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds.rounded())) : 0
        let (hours, minutes, secs) = (total / 3600, total % 3600 / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }
}

/// Formats a subtitle timing offset, shared by the iOS and tvOS timing panels.
nonisolated enum SubtitleOffset {
    /// "+1.5 s", "−0.25 s" or "0 s". The minus is a true minus sign, not a hyphen.
    static func text(_ offset: TimeInterval) -> String {
        let sign = offset > 0 ? "+" : offset < 0 ? "−" : ""
        return "\(sign)\(abs(offset).formatted(.number.precision(.fractionLength(0...1)))) s"
    }
}

extension MediaSegment.Kind {
    /// The Skip button's title for this kind of marked stretch, e.g. "Skip Intro".
    var skipActionTitle: String {
        switch self {
        case .intro: String(localized: "Skip Intro")
        case .outro: String(localized: "Skip Outro")
        case .recap: String(localized: "Skip Recap")
        case .preview: String(localized: "Skip Preview")
        case .commercial: String(localized: "Skip Commercial")
        case .unknown: String(localized: "Skip")
        }
    }
}
