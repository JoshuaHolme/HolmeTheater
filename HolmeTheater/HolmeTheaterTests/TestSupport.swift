// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
@testable import HolmeTheater

/// Factories for the plain value types the tests exercise, so each test says only what it cares about.
enum Sample {
    /// A movie with just the fields a test names.
    static func movie(
        id: String = "m",
        title: String = "A Movie",
        year: Int? = 2020,
        runtime: TimeInterval? = 6000,
        playedFraction: Double? = nil,
        isPlayed: Bool = false,
        genres: [String] = [],
        network: String? = nil,
        officialRating: String? = nil,
        communityRating: Double? = nil,
        criticRating: Double? = nil,
        releaseDate: Date? = nil,
        lastPlayedDate: Date? = nil
    ) -> MediaItem {
        var item = MediaItem(
            id: id, title: title, kind: .movie, overview: nil, year: year, runtime: runtime,
            posterURL: nil, backdropURL: nil, playedFraction: playedFraction, isPlayed: isPlayed,
            seriesTitle: nil, seasonNumber: nil, episodeNumber: nil
        )
        item.genres = genres
        item.network = network
        item.officialRating = officialRating
        item.communityRating = communityRating
        item.criticRating = criticRating
        item.releaseDate = releaseDate
        item.lastPlayedDate = lastPlayedDate
        return item
    }

    /// An episode with the show, season and episode fields a test names.
    static func episode(
        id: String = "e",
        title: String = "An Episode",
        seriesID: String? = "series",
        seriesTitle: String? = "A Show",
        seasonID: String? = "season",
        seasonNumber: Int? = 1,
        episodeNumber: Int? = 1,
        isPlayed: Bool = false,
        playedFraction: Double? = nil
    ) -> MediaItem {
        var item = MediaItem(
            id: id, title: title, kind: .episode, overview: nil, year: 2020, runtime: 2640,
            posterURL: nil, backdropURL: nil, playedFraction: playedFraction, isPlayed: isPlayed,
            seriesTitle: seriesTitle, seasonNumber: seasonNumber, episodeNumber: episodeNumber
        )
        item.seriesID = seriesID
        item.seasonID = seasonID
        return item
    }

    /// A series with the run and rating fields a test names.
    static func series(
        id: String = "s",
        title: String = "A Show",
        year: Int? = 2019,
        endYear: Int? = nil,
        status: String? = nil,
        genres: [String] = [],
        network: String? = nil
    ) -> MediaItem {
        var item = MediaItem(
            id: id, title: title, kind: .series, overview: nil, year: year, runtime: nil,
            posterURL: nil, backdropURL: nil, playedFraction: nil, isPlayed: false,
            seriesTitle: nil, seasonNumber: nil, episodeNumber: nil
        )
        item.endYear = endYear
        item.status = status
        item.genres = genres
        item.network = network
        return item
    }

    /// A completed download record for `item`.
    static func record(_ item: MediaItem, state: DownloadState = .completed, scope: String = "scope", dateAdded: Date = .now) -> DownloadRecord {
        var record = DownloadRecord(item: item, scope: scope, state: state)
        record.dateAdded = dateAdded
        return record
    }
}
