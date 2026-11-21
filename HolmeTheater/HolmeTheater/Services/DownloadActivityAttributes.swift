// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(iOS)
import ActivityKit
import Foundation

/// What the downloads Live Activity shows. Shared by the app, which updates it, and the widget extension, which draws it:
/// this one file is a member of both targets.
nonisolated struct DownloadActivityAttributes: ActivityAttributes {
    /// The part that changes as downloads progress, sent with each update.
    nonisolated struct ContentState: Codable, Hashable {
        /// The one download's name, or e.g. "3 Downloads".
        var title: String

        /// A second line: an episode's show and number, or how many have finished.
        var subtitle: String?

        /// How many downloads are done, and how many there are in all.
        var completed: Int
        var total: Int

        /// How far along everything is, from 0 to 1.
        var fraction: Double

        /// Whether nothing is moving because the user paused it, or it failed.
        var isPaused: Bool

        /// Whether every download has finished.
        var isFinished: Bool
    }
}
#endif
