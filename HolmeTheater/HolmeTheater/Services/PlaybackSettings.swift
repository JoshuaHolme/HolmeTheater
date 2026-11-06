// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation

/// How playback behaves, kept on the device.
///
/// One of these is shared by the Account screen's settings and the player's own controls, so changing it in either shows
/// in the other.
@Observable
final class PlaybackSettings {
    /// Whether the next episode starts by itself when one ends, after the "Up Next" card has counted down. Off, the card
    /// doesn't show, and the player closes when the episode ends.
    var autoPlaysNext: Bool {
        didSet {
            guard autoPlaysNext != oldValue else { return }
            defaults.set(autoPlaysNext, forKey: Self.autoPlayKey)
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    private static let autoPlayKey = "autoPlaysNextEpisode"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // On, unless it's been turned off.
        autoPlaysNext = defaults.object(forKey: Self.autoPlayKey) as? Bool ?? true
    }
}
