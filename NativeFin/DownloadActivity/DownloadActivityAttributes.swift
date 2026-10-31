// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ActivityKit
import Foundation

/// What the downloads Live Activity shows.
///
/// This is a copy of `NativeFin/Services/DownloadActivityAttributes.swift`, which the app updates the activity with.
/// ActivityKit passes the state between the two as Codable, so the two copies must keep the same name and fields.
struct DownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var subtitle: String?
        var completed: Int
        var total: Int
        var fraction: Double
        var isPaused: Bool
        var isFinished: Bool
    }
}
