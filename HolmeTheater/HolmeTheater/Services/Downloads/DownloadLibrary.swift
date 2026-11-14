// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Organizes finished downloads the way the Downloads page shows them: movies by name, and shows with their episodes
/// grouped under them. Pure, so the page can stay about layout and this can be tested on its own.
nonisolated enum DownloadLibrary {
    /// One downloaded show on the Downloads page: its ID, its name, and its episodes in order.
    struct Show: Equatable {
        let id: String
        let title: String
        let episodes: [DownloadRecord]
    }

    /// One downloaded season within a show: its ID and its episodes in order.
    struct Season: Equatable {
        let id: String
        let episodes: [DownloadRecord]
    }

    /// The finished downloaded movies, by name.
    static func movies(from records: [DownloadRecord]) -> [DownloadRecord] {
        records
            .filter { $0.isComplete && $0.item.kind == .movie }
            .sorted { $0.item.title.localizedStandardCompare($1.item.title) == .orderedAscending }
    }

    /// The shows with finished downloaded episodes, by name.
    ///
    /// - Parameter title: The show's display name for an ID, which the caller looks up from the store's saved shows.
    ///   When there's none, the episodes' own series name stands in.
    static func shows(from records: [DownloadRecord], title: (String) -> String?) -> [Show] {
        let episodes = records.filter { $0.isComplete && $0.item.kind == .episode }
        return Dictionary(grouping: episodes) { $0.item.seriesID ?? $0.item.seriesTitle ?? $0.id }
            .map { id, records in
                Show(id: id, title: title(id) ?? records.first?.item.seriesTitle ?? "", episodes: records.sorted(by: DownloadRecord.episodeOrder))
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// The finished downloaded episodes of a show, grouped into their seasons, in season order.
    static func seasons(ofSeries seriesID: String, from records: [DownloadRecord]) -> [Season] {
        let episodes = records.filter { $0.isComplete && $0.item.seriesID == seriesID }
        return Dictionary(grouping: episodes) { $0.item.seasonID ?? "" }
            .map { Season(id: $0.key, episodes: $0.value.sorted(by: DownloadRecord.episodeOrder)) }
            .sorted { ($0.episodes.first?.item.seasonNumber ?? 0) < ($1.episodes.first?.item.seasonNumber ?? 0) }
    }

    /// The finished downloaded episodes of a season, in order.
    static func episodes(ofSeason seasonID: String, from records: [DownloadRecord]) -> [DownloadRecord] {
        records
            .filter { $0.isComplete && $0.item.seasonID == seasonID }
            .sorted(by: DownloadRecord.episodeOrder)
    }
}
