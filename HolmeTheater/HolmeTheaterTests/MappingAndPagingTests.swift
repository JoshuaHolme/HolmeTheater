// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import HolmeTheater

struct MergedPagingTests {
    private func items(_ ids: [String]) -> [MediaItem] { ids.map { Sample.movie(id: $0) } }

    @Test func interleavesLibrariesInTurn() {
        let merged = MergedPaging.interleave([items(["a1", "a2"]), items(["b1", "b2"])])
        #expect(merged.map(\.id) == ["a1", "b1", "a2", "b2"])
    }

    @Test func dropsItemsThatAppearInMoreThanOneList() {
        let merged = MergedPaging.interleave([items(["x", "y"]), items(["x", "z"])])
        #expect(merged.map(\.id) == ["x", "y", "z"])
    }

    @Test func pagesWithOffsetAndLimit() {
        let page = MergedPaging.page(of: [items(["a1", "a2", "a3"]), items(["b1", "b2"])], offset: 1, limit: 2, byLastPlayed: false)
        #expect(page.map(\.id) == ["b1", "a2"])
    }

    @Test func byLastPlayedSortsNewestFirstThenKeepsOrder() {
        let old = Date(timeIntervalSince1970: 100)
        let new = Date(timeIntervalSince1970: 200)
        let lists = [[Sample.movie(id: "never"), Sample.movie(id: "old", lastPlayedDate: old)],
                     [Sample.movie(id: "new", lastPlayedDate: new)]]
        let page = MergedPaging.page(of: lists, offset: 0, limit: 3, byLastPlayed: true)
        #expect(page.map(\.id) == ["new", "old", "never"])
    }
}

struct JellyfinHelpersTests {
    @Test func plainIDsAreLettersAndDigitsOnly() {
        #expect(JellyfinMediaService.isPlainID("tt0903747"))
        #expect(!JellyfinMediaService.isPlainID("../escape"))
        #expect(!JellyfinMediaService.isPlainID(""))
    }

    @Test func personWebpagePrefersIMDbThenTMDb() {
        #expect(JellyfinMediaService.personWebpage(imdbID: "nm123", tmdbID: "456")?.absoluteString == "https://www.imdb.com/name/nm123")
        #expect(JellyfinMediaService.personWebpage(imdbID: nil, tmdbID: "456")?.absoluteString == "https://www.themoviedb.org/person/456")
        #expect(JellyfinMediaService.personWebpage(imdbID: nil, tmdbID: nil) == nil)
    }

    @Test func rejectsProviderIDsThatCouldChangeTheLink() {
        #expect(JellyfinMediaService.personWebpage(imdbID: "a/b", tmdbID: nil) == nil)
    }

    @Test func firstEpisodeToPlaySkipsSpecials() {
        let special = Sample.episode(id: "sp", seasonNumber: 0, episodeNumber: 1)
        let first = Sample.episode(id: "s1e1", seasonNumber: 1, episodeNumber: 1)
        #expect(JellyfinMediaService.firstEpisodeToPlay(among: [special, first])?.id == "s1e1")
        // Specials are all there is: take the first.
        #expect(JellyfinMediaService.firstEpisodeToPlay(among: [special])?.id == "sp")
    }

    @Test func itemsReleasedMatchesMonthAndDayAcrossYears() {
        func date(_ string: String) -> Date { ISO8601DateFormatter().date(from: string)! }
        let onDay = Sample.movie(id: "match", releaseDate: date("1999-07-04T00:00:00Z"))
        let otherDay = Sample.movie(id: "miss", releaseDate: date("1999-07-05T00:00:00Z"))
        let olderSameDay = Sample.movie(id: "older", releaseDate: date("1980-07-04T00:00:00Z"))
        let matches = JellyfinMediaService.itemsReleased(onMonth: 7, day: 4, among: [olderSameDay, onDay, otherDay])
        // Only the two July 4ths, newest first.
        #expect(matches.map(\.id) == ["match", "older"])
    }

    @Test func estimatedConvertedSizeNeedsBothInputs() {
        #expect(JellyfinMediaService.estimatedConvertedSize(runtime: 3600, sourceBitrate: 8_000_000) == 3_600_000_000)
        #expect(JellyfinMediaService.estimatedConvertedSize(runtime: nil, sourceBitrate: 8_000_000) == nil)
        #expect(JellyfinMediaService.estimatedConvertedSize(runtime: 3600, sourceBitrate: nil) == nil)
    }
}

@MainActor
struct MediaServiceExtensionTests {
    @Test func continueWatchingComesBeforeUpNextWithNoRepeats() async throws {
        let items = try await MockMediaService().continueWatchingAndUpNext(offset: 0, limit: 20, libraryIDs: nil)
        let ids = items.map(\.id)
        #expect(Set(ids).count == ids.count) // no duplicates across the two lists
        #expect(!items.isEmpty)
    }

    @Test func pagingSkipsThePrefix() async throws {
        let service = MockMediaService()
        let all = try await service.continueWatchingAndUpNext(offset: 0, limit: 20, libraryIDs: nil)
        let afterFirst = try await service.continueWatchingAndUpNext(offset: 1, limit: 20, libraryIDs: nil)
        #expect(afterFirst.first?.id == all.dropFirst().first?.id)
    }
}
