// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// The shows and movies whose files this device couldn't show a picture from when the server sent them as they are.
///
/// A file the device can't decode (HEVC tagged `hev1` rather than `hvc1`, say) plays its sound and keeps time with a
/// black screen, and the player reports no error. When that's found out, the player asks for a stream the device can show
/// instead (see ``PlaybackSession``), and the show is noted here so its other episodes start that way, without the black
/// screen first. Episodes of a show are usually encoded alike, so the show is what's remembered, not the episode.
///
/// Entries lapse after a while, so a file fixed on the server is tried as it is again.
nonisolated enum DirectPlayFailures {
    private static let storageKey = "directPlayFailures"

    /// How long a note stays, in seconds.
    static let lifetime: TimeInterval = 30 * 24 * 60 * 60

    /// What a note is filed under: the show for an episode, otherwise the item itself.
    static func key(for item: MediaItem) -> String {
        item.seriesID ?? item.id
    }

    /// Whether `item` has been found to need something other than the original file.
    static func contains(_ item: MediaItem, defaults: UserDefaults = .standard, now: Date = .now) -> Bool {
        guard let noted = notes(in: defaults)[key(for: item)] else { return false }
        return now.timeIntervalSince(noted) < lifetime
    }

    /// Notes that `item` needs something other than the original file.
    static func record(_ item: MediaItem, defaults: UserDefaults = .standard, now: Date = .now) {
        var all = notes(in: defaults).filter { now.timeIntervalSince($0.value) < lifetime }
        all[key(for: item)] = now
        if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: storageKey)
        }
    }

    /// When each was noted, by key.
    private static func notes(in defaults: UserDefaults) -> [String: Date] {
        defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) } ?? [:]
    }
}
