// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
#if canImport(UIKit)
import UIKit
#endif
@testable import HolmeTheater

@MainActor
struct SessionLifecycleTests {
    private func signedInModel(failure: (any Error)?, store: InMemorySessionStore) -> AppModel {
        AppModel(service: MockMediaService(latency: .zero, failure: failure), state: .signedIn(.preview), sessionStore: store)
    }

    @Test func aRefusedSessionSignsOut() async throws {
        let store = InMemorySessionStore(session: .preview)
        let app = signedInModel(failure: MediaServiceError.sessionExpired, store: store)
        await app.refreshProfile()
        #expect(app.session == nil)
        // The useless token isn't restored at the next launch.
        #expect(try store.load() == nil)
    }

    @Test func anUnreachableServerKeepsTheUserSignedIn() async throws {
        let store = InMemorySessionStore(session: .preview)
        let app = signedInModel(failure: MediaServiceError.serverUnreachable, store: store)
        await app.refreshProfile()
        #expect(app.session == .preview)
        #expect(try store.load() == .preview)
    }

    @Test func launchingTwiceDoesItOnce() async {
        let app = AppModel(
            service: MockMediaService(latency: .zero),
            state: .launching,
            sessionStore: InMemorySessionStore(session: .preview)
        )
        await app.launch(watchingPurchases: false)
        #expect(app.session != nil)

        // A second window appearing after the user signed out doesn't sign them back in.
        await app.signOut()
        await app.launch(watchingPurchases: false)
        #expect(app.session == nil)
    }
}

struct OfflineFallbackTests {
    private func store(with movie: MediaItem) -> DownloadStore {
        let store = DownloadStore(root: FileManager.default.temporaryDirectory.appending(path: "OfflineFallbackTests-\(UUID().uuidString)"))
        store.scope = "scope"
        store.save(Sample.record(movie))
        return store
    }

    @Test func answersFromDownloadsWhenTheServerCantBeReached() async throws {
        let movie = Sample.movie(id: "downloaded", title: "Saved Copy")
        let service = OfflineFallbackMediaService(
            base: MockMediaService(latency: .zero, failure: MediaServiceError.serverUnreachable),
            store: store(with: movie)
        )
        #expect(try await service.item(id: "downloaded").title == "Saved Copy")
    }

    @Test func passesTheServersErrorOnWhenNothingIsSaved() async {
        let service = OfflineFallbackMediaService(
            base: MockMediaService(latency: .zero, failure: MediaServiceError.serverUnreachable),
            store: store(with: Sample.movie(id: "downloaded"))
        )
        await #expect(throws: MediaServiceError.self) { try await service.item(id: "something-else") }
    }

    @Test func aCancelledRequestStaysCancelled() async {
        // Cancelling isn't the server failing: a screen that's gone shouldn't be handed the saved copy.
        let service = OfflineFallbackMediaService(
            base: MockMediaService(latency: .zero, failure: CancellationError()),
            store: store(with: Sample.movie(id: "downloaded"))
        )
        await #expect(throws: CancellationError.self) { try await service.item(id: "downloaded") }
    }
}

@MainActor
struct DownloadManagerStatusTests {
    private static func season(id: String = "season", episodes: Int) -> MediaItem {
        var item = MediaItem(
            id: id, title: "Season 1", kind: .season, overview: nil, year: nil, runtime: nil,
            posterURL: nil, backdropURL: nil, playedFraction: nil, isPlayed: false,
            seriesTitle: "A Show", seasonNumber: 1, episodeNumber: nil
        )
        item.seriesID = "series"
        item.episodeCount = episodes
        return item
    }

    private static func playlist() -> MediaItem {
        MediaItem(
            id: "playlist", title: "Favourites", kind: .playlist, overview: nil, year: nil, runtime: nil,
            posterURL: nil, backdropURL: nil, playedFraction: nil, isPlayed: false,
            seriesTitle: nil, seasonNumber: nil, episodeNumber: nil
        )
    }

    /// A manager showing `records`, with no background session and nothing started.
    private func manager(_ records: [DownloadRecord]) -> DownloadManager {
        let store = DownloadStore(root: FileManager.default.temporaryDirectory.appending(path: "DownloadManagerTests-\(UUID().uuidString)"))
        store.scope = "scope"
        for record in records { store.save(record) }
        let manager = DownloadManager(service: MockMediaService(latency: .zero), store: store, background: false)
        manager.refresh()
        return manager
    }

    @Test func aFinishedMovieIsDownloaded() {
        let movie = Sample.movie(id: "m")
        let downloads = manager([Sample.record(movie)])
        #expect(downloads.isDownloaded(movie))
        #expect(downloads.stage(of: movie) == .downloaded)
        #expect(downloads.status(of: movie) == .downloaded)
        #expect(!downloads.isDownloaded(Sample.movie(id: "other")))
    }

    @Test func aSeasonIsDownloadedOnceEveryEpisodeIs() {
        let first = Sample.episode(id: "e1", episodeNumber: 1)
        let second = Sample.episode(id: "e2", episodeNumber: 2)

        let partly = manager([Sample.record(first)])
        #expect(!partly.isDownloaded(Self.season(episodes: 2)))
        #expect(partly.stage(of: Self.season(episodes: 2)) == .partial)
        #expect(partly.hasEpisodesToDownload(Self.season(episodes: 2)))

        let fully = manager([Sample.record(first), Sample.record(second)])
        #expect(fully.isDownloaded(Self.season(episodes: 2)))
        #expect(fully.stage(of: Self.season(episodes: 2)) == .downloaded)
        #expect(!fully.hasEpisodesToDownload(Self.season(episodes: 2)))
    }

    @Test func aPausedEpisodeShowsOnItsSeasonAndShow() {
        let downloads = manager([Sample.record(Sample.episode(id: "e1"), state: .paused)])
        #expect(downloads.stage(of: Self.season(episodes: 2)) == .paused)
        #expect(downloads.status(of: Self.season(episodes: 2)) == .paused)
        #expect(downloads.stage(of: Sample.series(id: "series")) == .paused)
    }

    @Test func aPlaylistCountsAnItemItHoldsTwiceOnce() {
        let movie = Sample.movie(id: "m")
        let episode = Sample.episode(id: "e1")
        let playlist = Self.playlist()
        let downloads = manager([Sample.record(movie)])
        downloads.register([movie, movie, episode], asMembersOf: playlist)

        #expect(downloads.records(under: playlist).map(\.id) == ["m"])
        #expect(!downloads.isDownloaded(playlist))
        #expect(downloads.stage(of: playlist) == .partial)

        downloads.register([movie, movie], asMembersOf: playlist)
        #expect(downloads.isDownloaded(playlist))
        #expect(downloads.stage(of: playlist) == .downloaded)
    }

    @Test func aPlaylistNobodyHasOpenedIsntDownloaded() {
        #expect(!manager([]).isDownloaded(Self.playlist()))
    }
}

#if canImport(UIKit)
struct ImageCacheTests {
    /// A small picture saved as a file, as a download's artwork is.
    private func pictureFile() throws -> URL {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let file = FileManager.default.temporaryDirectory.appending(path: "ImageCacheTests-\(UUID().uuidString).png")
        try #require(image.pngData()).write(to: file)
        return file
    }

    @Test func emptyingTheCacheForgetsWhatWasLoaded() async throws {
        let file = try pictureFile()
        #expect(await ImageCache.shared.image(for: file) != nil)
        ImageCache.shared.removeAll()
        #expect(ImageCache.shared.cachedImage(for: file) == nil)
    }

    @Test func aLoadStillGoingWhenTheCacheIsEmptiedDoesntRefillIt() async throws {
        let file = try pictureFile()
        let load = Task { await ImageCache.shared.image(for: file) }
        // Signing out while the picture is on its way: the next person mustn't find it in the cache.
        ImageCache.shared.removeAll()
        _ = await load.value
        #expect(ImageCache.shared.cachedImage(for: file) == nil)
    }
}
#endif
