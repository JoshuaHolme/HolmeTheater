// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

extension URL {
    /// The placeholder server address used by ``MockMediaService`` and SwiftUI previews.
    ///
    /// It's on the reserved `example.com` domain, so nothing real is ever contacted. `URL(string:)` can't fail
    /// for this literal; the file-URL fallback exists only so the constant needs no force unwrap.
    nonisolated static let exampleServer = URL(string: "https://jellyfin.example.com") ?? URL(filePath: "/")
}

/// Canned data for building and previewing UI without a Jellyfin server.
///
/// Every call succeeds after a short simulated delay. Run the app with the `-UseMockService`
/// launch argument to use it in place of a real server.
nonisolated struct MockMediaService: MediaService {
    /// How long each simulated network call takes.
    var latency: Duration = .milliseconds(300)

    /// The server every ``connect(to:)`` "succeeds" against, whatever address is typed.
    private static let server = ServerInfo(id: "mock-server", name: "Mock Server", url: .exampleServer)

    /// The session every sign-in method returns.
    private static let session = UserSession(
        server: server,
        userID: "mock-user",
        username: "demo",
        accessToken: "mock-token"
    )

    private static let movieLibrary = Library(id: "lib-movies", name: "Movies", kind: .movies)
    private static let showLibrary = Library(id: "lib-shows", name: "TV Shows", kind: .tvShows)

    /// Twelve movies; every fourth is partly watched and every fifth is finished.
    private static let movies: [MediaItem] = (1...12).map { index in
        MediaItem(
            id: "movie-\(index)",
            title: "Sample Movie \(index)",
            kind: .movie,
            overview: "A placeholder synopsis for sample movie \(index).",
            year: 2000 + index,
            runtime: TimeInterval(5400 + index * 120),
            posterURL: nil,
            backdropURL: nil,
            playedFraction: index % 4 == 0 ? 0.4 : nil,
            isPlayed: index % 5 == 0,
            seriesTitle: nil,
            seasonNumber: nil,
            episodeNumber: nil
        )
    }

    private static let shows: [MediaItem] = (1...6).map { index in
        MediaItem(
            id: "series-\(index)",
            title: "Sample Show \(index)",
            kind: .series,
            overview: "A placeholder synopsis for sample show \(index).",
            year: 2015 + index,
            runtime: nil,
            posterURL: nil,
            backdropURL: nil,
            playedFraction: nil,
            isPlayed: false,
            seriesTitle: nil,
            seasonNumber: nil,
            episodeNumber: nil,
            genres: ["Drama", "Mystery"],
            network: "Sample Network"
        )
    }

    /// Eight episodes (the mock has one season per series, so a series' children are episodes directly).
    private static func episodes(of series: MediaItem) -> [MediaItem] {
        (1...8).map { number in
            MediaItem(
                id: "\(series.id)-s1e\(number)",
                title: "Episode \(number)",
                kind: .episode,
                overview: "A placeholder synopsis for episode \(number).",
                year: series.year,
                runtime: 2640,
                posterURL: nil,
                backdropURL: nil,
                playedFraction: number == 3 ? 0.6 : nil,
                isPlayed: number < 3,
                seriesTitle: series.title,
                seasonNumber: 1,
                episodeNumber: number,
                seriesID: series.id
            )
        }
    }

    private func simulateLatency() async throws {
        try await Task.sleep(for: latency)
    }

    // MARK: Connection & auth

    func connect(to address: String) async throws -> ServerInfo {
        try await simulateLatency()
        return Self.server
    }

    func serverBranding() async -> ServerBranding? {
        ServerBranding(loginDisclaimer: "Authorized users only. Ask the admin for an account.", splashscreenURL: nil)
    }

    func signIn(username: String, password: String) async throws -> UserSession {
        try await simulateLatency()
        return Self.session
    }

    /// Shows the code `123456`, then "approves" it after three seconds.
    func quickConnect() -> AsyncThrowingStream<QuickConnectEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Task.sleep(for: .milliseconds(300))
                    continuation.yield(.code("123456"))
                    try await Task.sleep(for: .seconds(3))
                    continuation.yield(.signedIn(Self.session))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Accepts any code but `000000`, which is treated as wrong.
    func authorizeQuickConnect(code: String) async throws {
        try await simulateLatency()
        if code == "000000" { throw MediaServiceError.underlying(String(localized: "That code isn't right, or it has expired.")) }
    }

    func restore(_ session: UserSession) async {}

    func signOut() async {}

    func refreshProfile() async throws -> UserSession {
        try await simulateLatency()
        return Self.session
    }

    // MARK: Browsing

    func libraries() async throws -> [Library] {
        try await simulateLatency()
        return [Self.movieLibrary, Self.showLibrary]
    }

    func items(in library: Library) async throws -> [MediaItem] {
        try await simulateLatency()
        return library.kind == .tvShows ? Self.shows : Self.movies
    }

    func resumeItems(offset: Int, limit: Int, libraryIDs: [String]?) async throws -> [MediaItem] {
        try await simulateLatency()
        return Array(Self.movies.filter { $0.playedFraction != nil }.dropFirst(offset).prefix(limit))
    }

    func nextUpItems(offset: Int, limit: Int, libraryIDs: [String]?) async throws -> [MediaItem] {
        try await simulateLatency()
        // The first unwatched episode of each sample show.
        let next = Self.shows.compactMap { show in
            Self.episodes(of: show).first { !$0.isPlayed && $0.playedFraction == nil }
        }
        return Array(next.dropFirst(offset).prefix(limit))
    }

    func recentlyAddedItems(in library: Library) async throws -> [MediaItem] {
        try await simulateLatency()
        return Array((library.kind == .tvShows ? Self.shows : Self.movies).prefix(8))
    }

    func recentlyAddedPage(in library: Library, offset: Int, limit: Int) async throws -> [MediaItem] {
        try await simulateLatency()
        // Episodes for TV libraries, movies otherwise. The sample shows have 48 episodes between them,
        // so paging has something to do.
        let all = library.kind == .tvShows ? Self.shows.flatMap { Self.episodes(of: $0) } : Self.movies
        return Array(all.dropFirst(offset).prefix(limit))
    }

    func randomItems(in library: Library, limit: Int) async throws -> [MediaItem] {
        try await simulateLatency()
        let all = library.kind == .tvShows ? Self.shows : Self.movies
        return Array(all.shuffled().prefix(limit))
    }

    func recentlyReleasedPage(in library: Library, offset: Int, limit: Int) async throws -> [MediaItem] {
        try await simulateLatency()
        let all = library.kind == .tvShows ? Self.shows.flatMap { Self.episodes(of: $0) } : Self.movies
        return Array(all.reversed().dropFirst(offset).prefix(limit))
    }

    func itemsOnThisDay(libraryIDs: [String]?) async throws -> [MediaItem] {
        try await simulateLatency()
        return Array(Self.movies.prefix(4))
    }

    func items(withIDs ids: [String]) async throws -> [MediaItem] {
        try await simulateLatency()
        let all = Self.movies + Self.shows + Self.shows.flatMap { Self.episodes(of: $0) }
        return all.filter { ids.contains($0.id) }
    }

    func item(id: String) async throws -> MediaItem {
        try await simulateLatency()
        let all = Self.movies + Self.shows + Self.shows.flatMap { Self.episodes(of: $0) }
        guard let item = all.first(where: { $0.id == id }) else { throw MediaServiceError.itemNotFound }
        return item
    }

    func details(ofPerson personID: String) async throws -> PersonDetails {
        try await simulateLatency()
        return PersonDetails()
    }

    func items(featuring personID: String) async throws -> [PersonCredit] {
        try await simulateLatency()
        return []
    }

    func similarItems(to item: MediaItem) async throws -> [MediaItem] {
        try await simulateLatency()
        return []
    }

    func specialFeatures(of item: MediaItem) async throws -> [MediaItem] {
        try await simulateLatency()
        return []
    }

    func seasonCount(ofSeries id: String) async throws -> Int? {
        try await simulateLatency()
        return nil
    }

    func setFavorite(_ isFavorite: Bool, itemID: String) async throws {
        try await simulateLatency()
    }

    func children(of item: MediaItem) async throws -> [MediaItem] {
        try await simulateLatency()
        return item.kind == .series ? Self.episodes(of: item) : []
    }

    func nextEpisode(in series: MediaItem) async throws -> MediaItem? {
        try await simulateLatency()
        // The partly watched episode, or the first unwatched one, else the first.
        let episodes = Self.episodes(of: series)
        return episodes.first { $0.playedFraction != nil || !$0.isPlayed } ?? episodes.first
    }

    func search(_ query: String) async throws -> [MediaItem] {
        try await simulateLatency()
        return (Self.movies + Self.shows).filter {
            $0.title.localizedStandardContains(query)
        }
    }

    func genres() async throws -> [Genre] {
        try await simulateLatency()
        return ["Comedy", "Drama", "Horror", "Sci-Fi"].map {
            Genre(id: "genre-\($0)", name: $0, imageURL: nil)
        }
    }

    func items(in genre: Genre) async throws -> [MediaItem] {
        try await simulateLatency()
        return Self.movies + Self.shows
    }

    // MARK: Playback

    func segments(for item: MediaItem) async -> [MediaSegment] {
        [
            MediaSegment(kind: .recap, start: 0, end: 20),
            MediaSegment(kind: .intro, start: 20, end: 60),
            MediaSegment(kind: .outro, start: 400, end: 600)
        ]
    }

    func playbackInfo(for item: MediaItem, options: PlaybackOptions) async throws -> PlaybackInfo {
        try await simulateLatency()
        // Apple's public HLS sample stream stands in for a Jellyfin transcode URL.
        guard let url = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8") else {
            throw MediaServiceError.itemNotPlayable
        }
        let resume = (item.playedFraction ?? 0) * (item.runtime ?? 0)
        return PlaybackInfo(
            url: url,
            resumePosition: resume,
            playSessionID: "mock-play-session",
            mediaSourceID: nil,
            method: .transcode,
            audioTracks: [
                MediaTrack(index: 1, title: "English - AAC - Stereo", isExternal: false),
                MediaTrack(index: 2, title: "English - Commentary", isExternal: false)
            ],
            subtitleTracks: [MediaTrack(index: 3, title: "English - SRT", isExternal: true)],
            audioIndex: options.audioIndex ?? 1,
            subtitleIndex: options.subtitleIndex.flatMap { $0 == PlaybackOptions.noSubtitles ? nil : $0 },
            sourceBitrate: 20_000_000,
            sourceHeight: 1080,
            maxBitrate: options.maxBitrate
        )
    }

    func report(_ event: PlaybackEvent, for item: MediaItem, info: PlaybackInfo, position: TimeInterval, isPaused: Bool) async {}

    // MARK: Watch state

    // The canned data is immutable, so these only simulate the round trip.

    func markWatched(itemID: String) async throws {
        try await simulateLatency()
    }

    func markUnwatched(itemID: String) async throws {
        try await simulateLatency()
    }

    func removeFromContinueWatching(_ item: MediaItem) async throws {
        try await simulateLatency()
    }
}
