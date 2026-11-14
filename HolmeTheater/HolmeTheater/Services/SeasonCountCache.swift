// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation

/// How many seasons each show has, learned as screens load. A show with a single season is treated as a mini
/// series, with no season page, so a menu needs to know before it offers "Go to Season".
///
/// It's observable, so a menu built in a view's body is rebuilt when a count arrives.
@MainActor @Observable
final class SeasonCountCache {
    static let shared = SeasonCountCache()

    private var counts: [String: Int] = [:]

    /// The shows being fetched. Not observed: it changes while a menu is being built in a view's body, and no view
    /// shows it.
    @ObservationIgnored private var loading: Set<String> = []

    /// The show's season count, or nil if it isn't known yet.
    func count(ofSeries id: String) -> Int? { counts[id] }

    /// Forgets every count, e.g. on sign-out, so the next account starts with none of the last one's.
    func removeAll() {
        counts = [:]
        loading = []
    }

    /// Remembers a count a screen already has.
    func record(_ count: Int?, ofSeries id: String) {
        if let count { counts[id] = count }
    }

    /// Fetches a show's count in the background if it isn't known and isn't already being fetched.
    func prefetch(seriesID id: String, service: any MediaService) {
        guard counts[id] == nil, !loading.contains(id) else { return }
        loading.insert(id)
        Task {
            if let count = try? await service.seasonCount(ofSeries: id) {
                counts[id] = count
            }
            loading.remove(id)
        }
    }
}
