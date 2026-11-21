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
    /// Pass `-MockLatencyMilliseconds 8000` at launch to stretch it, to look at loading states.
    var latency: Duration = .milliseconds(UserDefaults.standard.object(forKey: "MockLatencyMilliseconds") as? Int ?? 300)

    /// What every simulated network call throws, for tests of what happens when the server can't be reached or
    /// refuses the session. Nil, the usual, lets them succeed.
    var failure: (any Error)? = nil

    /// The server every ``connect(to:)`` "succeeds" against, whatever address is typed.
    private static let server = ServerInfo(id: "mock-server", name: "Home Server", url: .exampleServer)

    /// The session every sign-in method returns.
    private static let session = UserSession(
        server: server,
        userID: "mock-user",
        username: "demo",
        accessToken: "mock-token"
    )

    private static let movieLibrary = Library(id: "lib-movies", name: "Movies", kind: .movies)
    private static let showLibrary = Library(id: "lib-shows", name: "TV Shows", kind: .tvShows)

    // The catalog is made up, and its artwork is drawn by ``MockArtwork``, so screens and App Store screenshots look
    // real without showing anyone's actual films.

    /// A movie or show in the made-up catalog.
    private struct Title {
        let name: String
        let year: Int
        let genres: [String]
        let rating: String
        let score: Double
        let tagline: String
        let overview: String
    }

    private static let movieTitles: [Title] = [
        Title(name: "Paper Lanterns", year: 2024, genres: ["Drama", "Romance"], rating: "PG-13", score: 7.8,
              tagline: "Some lights are only meant to be followed.",
              overview: "On the last night of a riverside festival, two strangers trade lanterns by mistake and spend the night trying to find each other again."),
        Title(name: "The Cartographer's Daughter", year: 2023, genres: ["Adventure", "Family"], rating: "PG", score: 7.4,
              tagline: "Every map leaves something out.",
              overview: "When her father vanishes on an expedition, a young mapmaker follows his unfinished charts into a valley no one has drawn before."),
        Title(name: "Static Bloom", year: 2025, genres: ["Sci-Fi", "Thriller"], rating: "R", score: 7.1,
              tagline: "The signal is growing.",
              overview: "A radio astronomer picks up a pattern that changes every time she listens, and the plants around the observatory start to answer."),
        Title(name: "Halfway to Juniper", year: 2022, genres: ["Comedy"], rating: "PG-13", score: 6.9,
              tagline: "Same car. Same playlist. No turning back.",
              overview: "Three estranged siblings drive their late grandmother's camper across the desert to scatter her ashes, if they can survive each other."),
        Title(name: "Low Tide at Marrow Bay", year: 2021, genres: ["Mystery", "Thriller"], rating: "R", score: 7.6,
              tagline: "The sea gives back what it takes.",
              overview: "A detective returns to her coastal hometown when a decades-old shipwreck surfaces at low tide, along with secrets the town buried with it."),
        Title(name: "Neon Orchard", year: 2024, genres: ["Sci-Fi", "Crime"], rating: "R", score: 7.3,
              tagline: "In a city of light, the truth grows in the dark.",
              overview: "In a city that farms its food in glowing towers, a courier stumbles onto a harvest no one was supposed to see."),
        Title(name: "Winter Ledger", year: 2020, genres: ["Drama"], rating: "PG-13", score: 7.9,
              tagline: "Some debts are paid in years.",
              overview: "A small-town bookkeeper discovers that her family's store has been quietly keeping the whole town afloat, and that the money is running out."),
        Title(name: "Kites Over Calder", year: 2023, genres: ["Family", "Comedy"], rating: "G", score: 7.0,
              tagline: "Look up.",
              overview: "A shy kid enters the town's kite festival with a homemade design and a plan to win back his best friend."),
        Title(name: "Second Sunrise", year: 2025, genres: ["Sci-Fi", "Drama"], rating: "PG-13", score: 8.1,
              tagline: "Home is a long way back.",
              overview: "Waking early from a century-long voyage, an engineer has one year to decide whether to wake the rest of the crew."),
        Title(name: "The Glass Archive", year: 2022, genres: ["Mystery"], rating: "PG-13", score: 7.2,
              tagline: "Everything is on record. Almost.",
              overview: "An archivist cataloguing a reclusive inventor's estate finds a room that isn't on any blueprint, and a recording of her own voice."),
        Title(name: "Velvet Hours", year: 2021, genres: ["Romance", "Music"], rating: "PG-13", score: 6.8,
              tagline: "One last set.",
              overview: "A jazz pianist and a sound engineer have one summer to save the late-night club where they both learned to listen."),
        Title(name: "Embervale", year: 2024, genres: ["Fantasy", "Adventure"], rating: "PG-13", score: 7.5,
              tagline: "The last fire must not go out.",
              overview: "In a valley lit by a single ancient flame, an apprentice keeper must carry it across the mountains before winter falls.")
    ]

    private static let showTitles: [(title: Title, network: String, isEnded: Bool, episodes: [String])] = [
        (Title(name: "Northbound", year: 2022, genres: ["Drama"], rating: "TV-14", score: 8.2,
               tagline: "Keep going.",
               overview: "Strangers on an overnight train across the north discover that each of them is running from the same town."),
         "Meridian", false,
         ["Departure", "The Dining Car", "Snowbound", "Platform Nine", "Signals", "Border Crossing", "The Long Tunnel", "Arrivals"]),
        (Title(name: "The Quiet Engine", year: 2021, genres: ["Sci-Fi", "Drama"], rating: "TV-14", score: 8.0,
               tagline: "It's listening.",
               overview: "A crew of engineers maintains a machine that keeps a city running, but nobody remembers who built it, or why it hums at night."),
         "Harbor", true,
         ["Maintenance", "Blueprints", "The Night Shift", "Resonance", "Override", "Silence", "Load Bearing", "Restart"]),
        (Title(name: "Saltwater Kitchen", year: 2023, genres: ["Comedy"], rating: "TV-PG", score: 7.6,
               tagline: "Family recipe. Family drama.",
               overview: "A chef inherits her uncle's failing seafood shack and the eccentric staff who came with it."),
         "Meridian", false,
         ["Opening Night", "The Critic", "Catch of the Day", "Brunch", "Health Inspection", "Storm Season", "The Regulars", "Last Call"]),
        (Title(name: "Hollow Pines", year: 2020, genres: ["Mystery", "Thriller"], rating: "TV-MA", score: 7.9,
               tagline: "Nobody leaves the woods the same.",
               overview: "When a hiker goes missing near a sleepy mountain town, a park ranger uncovers a pattern going back fifty years."),
         "Lantern", true,
         ["Trailhead", "The Search Party", "Ranger Station", "Old Growth", "Cold Case", "The Clearing", "Firewatch", "Hollow"]),
        (Title(name: "Orbitals", year: 2024, genres: ["Sci-Fi", "Comedy"], rating: "TV-PG", score: 7.4,
               tagline: "Space is big. The station isn't.",
               overview: "The overworked staff of a budget space station keep things running between tourist rushes, meteor showers, and each other."),
         "Harbor", false,
         ["Launch Day", "Zero-G Brunch", "Inspection", "The Leak", "Shore Leave", "Solar Flare", "Docking", "Re-entry"]),
        (Title(name: "The Understudies", year: 2023, genres: ["Comedy", "Drama"], rating: "TV-14", score: 7.7,
               tagline: "Waiting in the wings.",
               overview: "The backup cast of a struggling Broadway musical gets their big break when the leads come down with something mysterious."),
         "Lantern", false,
         ["Auditions", "Tech Week", "Previews", "The Lead Is Out", "Matinee", "Bad Reviews", "Closing Notice", "Curtain Call"])
    ]

    /// Made-up cast and crew, shared out across the catalog.
    private static let actorNames = [
        "Maya Okafor", "Daniel Reyes", "Iris Calloway", "Theo Lindqvist", "Priya Raman", "Samuel Achebe",
        "Elena Varga", "Jonah Whitfield", "Noor Haddad", "Lucas Moreau", "Hana Sato", "Gabriel Osei"
    ]
    private static let characterNames = [
        "Ada", "Marcus", "June", "Felix", "Rosa", "Eli", "Nadia", "Tobias", "Wren", "Oskar", "Lena", "Caleb"
    ]
    private static let directorNames = ["Clara Benedetti", "Arjun Mehta", "Sofia Lindgren", "Marcus Hale"]

    private static func people(for index: Int, creator: Bool = false) -> [MediaPerson] {
        let cast = (0..<6).map { offset in
            let person = (index * 5 + offset) % actorNames.count
            return MediaPerson(
                personID: "person-\(person)",
                role: .actor,
                name: actorNames[person],
                character: characterNames[(index + offset * 7) % characterNames.count],
                imageURL: MockArtwork.url(for: "person-\(person)", .portrait)
            )
        }
        let crew = MediaPerson(
            personID: "crew-\(index % directorNames.count)",
            role: creator ? .creator : .director,
            name: directorNames[index % directorNames.count],
            character: nil,
            imageURL: MockArtwork.url(for: "crew-\(index % directorNames.count)", .portrait)
        )
        return [crew] + cast
    }

    /// Twelve movies; every fourth is partly watched and every fifth is finished.
    private static let movies: [MediaItem] = movieTitles.enumerated().map { offset, title in
        let index = offset + 1
        let id = "movie-\(index)"
        let backdrop = MockArtwork.url(for: id, .backdrop)
        let runtime = TimeInterval(5400 + index * 420)
        var item = MediaItem(
            id: id,
            title: title.name,
            kind: .movie,
            overview: title.overview,
            year: title.year,
            runtime: runtime,
            posterURL: MockArtwork.url(for: id, .poster),
            backdropURL: backdrop,
            thumbnailURL: backdrop,
            playedFraction: index % 4 == 0 ? 0.4 : nil,
            isPlayed: index % 5 == 0,
            seriesTitle: nil,
            seasonNumber: nil,
            episodeNumber: nil,
            genres: title.genres,
            officialRating: title.rating,
            communityRating: title.score,
            criticRating: Double(60 + (index * 7) % 38),
            technicalLine: index % 3 == 0 ? "4K · Dolby Vision · Dolby Atmos" : "HD · 5.1",
            tagline: title.tagline,
            people: people(for: index)
        )
        item.chapters = (0..<6).map { chapter in
            MediaChapter(
                name: chapter == 0 ? "Opening" : "Chapter \(chapter + 1)",
                start: runtime / 6 * Double(chapter),
                imageURL: MockArtwork.url(for: "\(id)-chapter-\(chapter)", .still)
            )
        }
        return item
    }

    private static let shows: [MediaItem] = showTitles.enumerated().map { offset, show in
        let index = offset + 1
        let id = "series-\(index)"
        return MediaItem(
            id: id,
            title: show.title.name,
            kind: .series,
            overview: show.title.overview,
            year: show.title.year,
            runtime: nil,
            posterURL: MockArtwork.url(for: id, .poster),
            backdropURL: MockArtwork.url(for: id, .backdrop),
            playedFraction: nil,
            isPlayed: false,
            seriesTitle: nil,
            seasonNumber: nil,
            episodeNumber: nil,
            episodeCount: show.episodes.count,
            seasonCount: 1,
            unwatchedEpisodeCount: show.episodes.count - 2,
            genres: show.title.genres,
            network: show.network,
            officialRating: show.title.rating,
            communityRating: show.title.score,
            status: show.isEnded ? "Ended" : "Continuing",
            endYear: show.isEnded ? show.title.year + 2 : nil,
            tagline: show.title.tagline,
            people: people(for: index + 12, creator: true)
        )
    }

    /// Each series' only season, which holds its episodes.
    private static func season(of series: MediaItem) -> MediaItem {
        MediaItem(
            id: "\(series.id)-s1",
            title: String(localized: "Season 1"),
            kind: .season,
            overview: series.overview,
            year: series.year,
            runtime: nil,
            posterURL: series.posterURL,
            backdropURL: series.backdropURL,
            playedFraction: nil,
            isPlayed: false,
            seriesTitle: series.title,
            seasonNumber: 1,
            episodeNumber: nil,
            seriesID: series.id,
            episodeCount: series.episodeCount,
            unwatchedEpisodeCount: series.unwatchedEpisodeCount
        )
    }

    /// Eight episodes, all in the series' one season.
    private static func episodes(of series: MediaItem) -> [MediaItem] {
        let names = showTitles.first { $0.title.name == series.title }?.episodes ?? []
        return (1...8).map { number in
            let id = "\(series.id)-s1e\(number)"
            return MediaItem(
                id: id,
                title: names.indices.contains(number - 1) ? names[number - 1] : "Episode \(number)",
                kind: .episode,
                overview: "Episode \(number) of \(series.title). \(series.overview ?? "")",
                year: series.year,
                runtime: 2640,
                posterURL: series.posterURL,
                backdropURL: series.backdropURL,
                thumbnailURL: MockArtwork.url(for: id, .still),
                playedFraction: number == 3 ? 0.6 : nil,
                isPlayed: number < 3,
                seriesTitle: series.title,
                seasonNumber: 1,
                episodeNumber: number,
                seriesID: series.id,
                seasonID: "\(series.id)-s1",
                seasonPosterURL: series.posterURL,
                officialRating: series.officialRating
            )
        }
    }

    private func simulateLatency() async throws {
        try await Task.sleep(for: latency)
        if let failure { throw failure }
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
        // The first unfinished episode of each sample show, as the show's own Resume button picks.
        let next = Self.shows.compactMap { show in
            Self.episodes(of: show).first { !$0.isPlayed }
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
        let all = Self.movies + Self.shows + Self.shows.map { Self.season(of: $0) } + Self.shows.flatMap { Self.episodes(of: $0) }
        return all.filter { ids.contains($0.id) }
    }

    func item(id: String) async throws -> MediaItem {
        try await simulateLatency()
        let all = Self.movies + Self.shows + Self.shows.map { Self.season(of: $0) } + Self.shows.flatMap { Self.episodes(of: $0) }
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
        return 1
    }

    func setFavorite(_ isFavorite: Bool, itemID: String) async throws {
        try await simulateLatency()
    }

    func children(of item: MediaItem) async throws -> [MediaItem] {
        try await simulateLatency()
        switch item.kind {
        case .series:
            return [Self.season(of: item)]
        case .season:
            guard let series = Self.shows.first(where: { $0.id == item.seriesID }) else { return [] }
            return Self.episodes(of: series)
        default:
            return []
        }
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
