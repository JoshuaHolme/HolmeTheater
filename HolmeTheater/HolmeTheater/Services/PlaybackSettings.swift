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

    /// The account (``AppModel/cacheScope``) whose subtitle offsets are read and written. Set by the app model.
    @ObservationIgnored var scope = "" {
        didSet { adoptLegacyOffsets() }
    }

    @ObservationIgnored private let defaults: UserDefaults
    private static let autoPlayKey = "autoPlaysNextEpisode"
    private static let offsetsKey = "subtitleOffsets"

    /// Where earlier versions kept each item's offset, for every account at once.
    private static let legacyOffsetPrefix = "subtitleOffset."

    /// How many items' offsets an account keeps. Past this, the one set longest ago goes.
    private static let maxOffsetsPerAccount = 500

    /// One item's subtitle offset.
    private struct Offset: Codable {
        let itemID: String
        let seconds: TimeInterval
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // On, unless it's been turned off.
        autoPlaysNext = defaults.object(forKey: Self.autoPlayKey) as? Bool ?? true
    }

    // MARK: Subtitle offsets

    /// How many seconds later than the file says an item's subtitles show, for the signed-in account. 0 if never set.
    func subtitleOffset(for itemID: String) -> TimeInterval {
        offsets()[scope]?.last { $0.itemID == itemID }?.seconds ?? 0
    }

    /// Remembers an item's subtitle offset for the signed-in account, or forgets it with 0.
    func setSubtitleOffset(_ seconds: TimeInterval, for itemID: String) {
        guard !scope.isEmpty else { return }
        var all = offsets()
        var list = (all[scope] ?? []).filter { $0.itemID != itemID }
        if seconds != 0 { list.append(Offset(itemID: itemID, seconds: seconds)) }
        // Newest last, so the oldest are the ones dropped.
        all[scope] = list.isEmpty ? nil : Array(list.suffix(Self.maxOffsetsPerAccount))
        save(all)
    }

    /// Forgets the signed-in account's subtitle offsets, e.g. when signing out removes its data from the device.
    func removeSubtitleOffsets() {
        var all = offsets()
        guard all[scope] != nil else { return }
        all[scope] = nil
        save(all)
    }

    /// Every account's offsets, by scope, each list oldest first.
    private func offsets() -> [String: [Offset]] {
        defaults.data(forKey: Self.offsetsKey).flatMap { try? JSONDecoder().decode([String: [Offset]].self, from: $0) } ?? [:]
    }

    private func save(_ offsets: [String: [Offset]]) {
        if offsets.isEmpty {
            defaults.removeObject(forKey: Self.offsetsKey)
        } else if let data = try? JSONEncoder().encode(offsets) {
            defaults.set(data, forKey: Self.offsetsKey)
        }
    }

    /// Moves offsets kept the old way, one key per item and no account, to the first account signed in since, who is
    /// almost always whoever set them.
    private func adoptLegacyOffsets() {
        guard !scope.isEmpty else { return }
        let legacy = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix(Self.legacyOffsetPrefix) }
        guard !legacy.isEmpty else { return }
        for (key, value) in legacy {
            defaults.removeObject(forKey: key)
            if let seconds = value as? Double {
                setSubtitleOffset(seconds, for: String(key.dropFirst(Self.legacyOffsetPrefix.count)))
            }
        }
    }
}
