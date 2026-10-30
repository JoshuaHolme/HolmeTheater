// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
// `Get` is the HTTP layer underneath the SDK; its `Request` and `APIError` types appear in the SDK's API.
import Get
import JellyfinAPI

/// `MediaService` backed by jellyfin-sdk-swift.
///
/// Holds the SDK client and current session; everything the UI sees is mapped into the plain
/// types in `MediaModels.swift`, so no SDK type leaks out of this file.
///
/// This is an actor because it owns mutable connection state (the client and session) that
/// is touched from several concurrent UI tasks.
actor JellyfinMediaService: MediaService {
    /// Jellyfin expresses durations in 100-nanosecond "ticks".
    private static let ticksPerSecond = 10_000_000.0

    /// Maximum artwork widths requested from the server, in pixels.
    ///
    /// Posters are shown at about 130 pt wide (220 pt on tvOS), so 450 px is sharp on a 3× phone screen.
    /// Asking for more only costs memory (a decoded image takes width × height × 4 bytes) and bandwidth.
    private static let posterWidth = 450
    private static let backdropWidth = 1280
    private static let logoWidth = 800

    /// How many similar titles to ask for.
    private static let similarLimit = 20

    /// How wide a person's portrait is asked for when it fills the screen.
    private static let largePortraitWidth = 1200

    private let identity: ClientIdentity

    /// Set by `connect(to:)` or `restore(_:)`; nil until then.
    private var client: JellyfinClient?
    private var server: ServerInfo?

    /// Set once signed in; nil while only connected.
    private var session: UserSession?

    init(identity: ClientIdentity) {
        self.identity = identity
    }

    // MARK: - Connection & auth

    func connect(to address: String) async throws -> ServerInfo {
        let candidates = Self.candidateURLs(from: address)
        guard !candidates.isEmpty else { throw MediaServiceError.invalidServerURL }

        // Keep every attempt's failure so the user sees why each URL didn't work.
        var failures: [String] = []

        for url in candidates {
            let candidate = makeClient(url: url, accessToken: nil)
            do {
                // The public info endpoint needs no authentication, so it doubles as a "is this Jellyfin?" check.
                let info = try await candidate.send(Paths.getPublicSystemInfo).value
                let server = ServerInfo(
                    id: info.id ?? "",
                    name: info.serverName ?? url.host() ?? "Jellyfin",
                    url: url
                )
                client = candidate
                self.server = server
                session = nil
                return server
            } catch {
                failures.append("\(url.absoluteString): \(error.localizedDescription)")
            }
        }

        throw MediaServiceError.underlying("Couldn't connect to a Jellyfin server.\n" + failures.joined(separator: "\n"))
    }

    func signIn(username: String, password: String) async throws -> UserSession {
        let client = try connectedClient()
        do {
            let result = try await client.signIn(username: username, password: password)
            return try storeSession(from: result, client: client)
        } catch {
            if case APIError.unacceptableStatusCode(let code) = error, code == 401 {
                throw MediaServiceError.invalidCredentials
            }
            throw Self.mapError(error)
        }
    }

    /// Wraps the SDK's Quick Connect flow, which yields the code and later the approval secret,
    /// and finishes by exchanging that secret for a session.
    nonisolated func quickConnect() -> AsyncThrowingStream<QuickConnectEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let client = try await self.connectedClient()
                    for try await event in client.quickConnect.connect() {
                        switch event {
                        case .polling(let code):
                            continuation.yield(.code(code))
                        case .authenticated(let secret):
                            let result = try await client.signIn(quickConnectSecret: secret)
                            let session = try await self.storeSession(from: result, client: client)
                            continuation.yield(.signedIn(session))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.mapError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func restore(_ session: UserSession) async {
        client = makeClient(url: session.server.url, accessToken: session.accessToken)
        server = session.server
        self.session = session
    }

    func signOut() async {
        // Revoke the token server-side, but clear local state even if that fails (e.g. offline).
        try? await client?.signOut()
        client = nil
        server = nil
        session = nil
    }

    func refreshProfile() async throws -> UserSession {
        let (client, session) = try signedIn()
        let user = try await send(Paths.getCurrentUser, with: client)

        let updated = UserSession(
            server: session.server,
            userID: session.userID,
            username: user.name ?? session.username,
            accessToken: session.accessToken,
            avatarURL: Self.avatarURL(userID: session.userID, tag: user.primaryImageTag, client: client)
        )
        self.session = updated
        return updated
    }

    // MARK: - Browsing

    func libraries() async throws -> [Library] {
        let (client, session) = try signedIn()
        let request = Paths.getUserViews(parameters: .init(userID: session.userID))
        let result = try await send(request, with: client)
        return (result.items ?? []).compactMap { dto in
            guard let id = dto.id, let name = dto.name else { return nil }
            let kind: Library.Kind = switch dto.collectionType {
            case .movies: .movies
            case .tvshows: .tvShows
            case .music: .music
            default: .other
            }
            return Library(id: id, name: name, kind: kind)
        }
    }

    func items(in library: Library) async throws -> [MediaItem] {
        let (client, session) = try signedIn()

        // Movie and TV libraries are flattened to their top-level items (movies, or series without
        // their episodes). Other kinds list only their immediate children.
        let includeTypes: [BaseItemKind]? = switch library.kind {
        case .movies: [.movie]
        case .tvShows: [.series]
        case .music, .other: nil
        }
        let request = Paths.getItems(parameters: .init(
            userID: session.userID,
            isRecursive: includeTypes != nil,
            sortOrder: [.ascending],
            parentID: library.id,
            fields: Self.itemFields,
            includeItemTypes: includeTypes,
            sortBy: [.sortName],
            enableUserData: true
        ))
        return try await mapItems(send(request, with: client), client: client)
    }

    func resumeItems(offset: Int, limit: Int) async throws -> [MediaItem] {
        let (client, session) = try signedIn()
        let request = Paths.getResumeItems(parameters: .init(
            userID: session.userID,
            startIndex: offset,
            limit: limit,
            fields: Self.itemFields,
            mediaTypes: [.video],
            enableUserData: true
        ))
        return try await mapItems(send(request, with: client), client: client)
    }

    func nextUpItems(offset: Int, limit: Int) async throws -> [MediaItem] {
        let (client, session) = try signedIn()
        let request = Paths.getNextUp(parameters: .init(
            userID: session.userID,
            startIndex: offset,
            limit: limit,
            fields: Self.itemFields,
            enableUserData: true,
            // Partly watched episodes already show under Continue Watching, and a show you've finished
            // shouldn't come back around.
            enableResumable: false,
            enableRewatching: false
        ))
        return try await mapItems(send(request, with: client), client: client)
    }

    func recentlyAddedItems(in library: Library) async throws -> [MediaItem] {
        let (client, session) = try signedIn()
        let request = Paths.getLatestMedia(parameters: .init(
            userID: session.userID,
            parentID: library.id,
            fields: Self.itemFields,
            enableUserData: true,
            limit: 16
        ))
        // Jellyfin calls this endpoint "latest media" but it returns what was added most recently, not what was
        // released most recently. Unlike the other endpoints, it returns a bare array rather than a query result.
        let dtos = try await send(request, with: client)
        return dtos.compactMap { Self.makeItem(from: $0, client: client) }
    }

    func recentlyAddedPage(in library: Library, offset: Int, limit: Int) async throws -> [MediaItem] {
        let (client, session) = try signedIn()

        // Flatten to the individual playable items (episodes or movies) rather than series.
        let includeTypes: [BaseItemKind]? = switch library.kind {
        case .movies: [.movie]
        case .tvShows: [.episode]
        case .music, .other: nil
        }
        let request = Paths.getItems(parameters: .init(
            userID: session.userID,
            startIndex: offset,
            limit: limit,
            isRecursive: includeTypes != nil,
            sortOrder: [.descending],
            parentID: library.id,
            fields: Self.itemFields,
            includeItemTypes: includeTypes,
            sortBy: [.dateCreated],
            enableUserData: true
        ))
        return try await mapItems(send(request, with: client), client: client)
    }

    func item(id: String) async throws -> MediaItem {
        let (client, session) = try signedIn()
        let request = Paths.getItems(parameters: .init(
            userID: session.userID,
            // The cast, and the streams that say what the picture and sound are, are big, so only a single item
            // asks for them, not every list.
            fields: Self.itemFields + [.people, .chapters, .mediaSources, .mediaStreams],
            enableUserData: true,
            ids: [id]
        ))
        guard let item = try await mapItems(send(request, with: client), client: client).first else {
            throw MediaServiceError.itemNotFound
        }
        return item
    }

    func details(ofPerson personID: String) async throws -> PersonDetails {
        let (client, session) = try signedIn()
        let dto = try await send(Paths.getItem(itemID: personID, userID: session.userID), with: client)

        func nonEmpty(_ text: String?) -> String? {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }

        // IMDb if the server knows it, otherwise TMDb.
        var webpage: URL?
        if let imdb = nonEmpty(dto.providerIDs?["Imdb"]), Self.isPlainID(imdb) {
            webpage = URL(string: "https://www.imdb.com/name/\(imdb)")
        } else if let tmdb = nonEmpty(dto.providerIDs?["Tmdb"]), Self.isPlainID(tmdb) {
            webpage = URL(string: "https://www.themoviedb.org/person/\(tmdb)")
        }

        return PersonDetails(
            biography: nonEmpty(dto.overview),
            birthDate: dto.premiereDate,
            deathDate: dto.endDate,
            birthplace: nonEmpty(dto.productionLocations?.first),
            webpage: webpage
        )
    }

    func items(featuring personID: String) async throws -> [PersonCredit] {
        let (client, session) = try signedIn()
        let request = Paths.getItems(parameters: .init(
            userID: session.userID,
            isRecursive: true,
            sortOrder: [.ascending],
            // Each item's cast tells what the person did on it. The list is small, so it's fine to ask for it.
            fields: Self.itemFields + [.people],
            includeItemTypes: [.movie, .series],
            sortBy: [.sortName],
            enableUserData: true,
            personIDs: [personID]
        ))
        return try await mapItems(send(request, with: client), client: client).map { item in
            var item = item
            let roles = item.people.filter { $0.personID == personID }
            // The cast isn't needed past this point.
            item.people = []
            return PersonCredit(item: item, roles: roles)
        }
    }

    func similarItems(to item: MediaItem) async throws -> [MediaItem] {
        let (client, session) = try signedIn()
        let request: Request<BaseItemDtoQueryResult>
        switch item.kind {
        case .series:
            request = Paths.getSimilarShows(itemID: item.id, parameters: .init(userID: session.userID, limit: Self.similarLimit, fields: Self.itemFields))
        case .movie:
            request = Paths.getSimilarMovies(itemID: item.id, parameters: .init(userID: session.userID, limit: Self.similarLimit, fields: Self.itemFields))
        default:
            return []
        }
        return try await mapItems(send(request, with: client), client: client).filter { $0.id != item.id }
    }

    func specialFeatures(of item: MediaItem) async throws -> [MediaItem] {
        let (client, session) = try signedIn()
        let features = try await send(Paths.getSpecialFeatures(itemID: item.id, userID: session.userID), with: client)
        return features.compactMap { Self.makeItem(from: $0, client: client, isExtra: true) }
    }

    func seasonCount(ofSeries id: String) async throws -> Int? {
        let (client, session) = try signedIn()
        let request = Paths.getItems(parameters: .init(
            userID: session.userID,
            fields: [.childCount],
            enableUserData: false,
            ids: [id]
        ))
        return try await send(request, with: client).items?.first?.childCount
    }

    func setFavorite(_ isFavorite: Bool, itemID: String) async throws {
        let (client, session) = try signedIn()
        if isFavorite {
            _ = try await send(Paths.markFavoriteItem(itemID: itemID, userID: session.userID), with: client)
        } else {
            _ = try await send(Paths.unmarkFavoriteItem(itemID: itemID, userID: session.userID), with: client)
        }
    }

    func children(of item: MediaItem) async throws -> [MediaItem] {
        let (client, session) = try signedIn()
        switch item.kind {
        case .series:
            let request = Paths.getSeasons(
                seriesID: item.id,
                parameters: .init(userID: session.userID, fields: Self.itemFields, enableUserData: true)
            )
            return try await mapItems(send(request, with: client), client: client)
        case .season:
            // A season is just a folder of episodes, so list its children in episode order.
            let request = Paths.getItems(parameters: .init(
                userID: session.userID,
                sortOrder: [.ascending],
                parentID: item.id,
                fields: Self.itemFields,
                sortBy: [.indexNumber],
                enableUserData: true
            ))
            return try await mapItems(send(request, with: client), client: client)
        case .movie, .episode, .extra, .other:
            return []
        }
    }

    func nextEpisode(in series: MediaItem) async throws -> MediaItem? {
        let (client, session) = try signedIn()

        // The server's Next Up for this one show: the episode after the last one watched, or a partly watched
        // one. For a show not yet started it's the first episode. It's empty once the show is finished,
        // because rewatching is off.
        let nextUp = Paths.getNextUp(parameters: .init(
            userID: session.userID,
            limit: 1,
            fields: Self.itemFields,
            seriesID: series.id,
            enableUserData: true,
            enableResumable: true,
            enableRewatching: false
        ))
        if let next = try await mapItems(send(nextUp, with: client), client: client).first {
            return next
        }

        // Finished (or nothing for Next Up to go on): start again from the top. Episodes come in season and
        // episode order; specials (season 0) are skipped unless they're all there is.
        let all = Paths.getEpisodes(seriesID: series.id, parameters: .init(
            userID: session.userID,
            fields: Self.itemFields,
            isMissing: false,
            enableUserData: true
        ))
        let episodes = try await mapItems(send(all, with: client), client: client)
        return episodes.first { ($0.seasonNumber ?? 1) > 0 } ?? episodes.first
    }

    func search(_ query: String) async throws -> [MediaItem] {
        let (client, session) = try signedIn()
        let request = Paths.getItems(parameters: .init(
            userID: session.userID,
            limit: 50,
            isRecursive: true,
            searchTerm: query,
            fields: Self.itemFields,
            includeItemTypes: [.movie, .series, .episode],
            enableUserData: true
        ))
        return try await mapItems(send(request, with: client), client: client)
    }

    // MARK: - Playback

    func playbackInfo(for item: MediaItem, options: PlaybackOptions) async throws -> PlaybackInfo {
        let (client, session) = try signedIn()

        // Describe what this device can play (`deviceProfile`) and let the server pick the cheapest
        // way to deliver it: direct play, then remux, then transcode. A bitrate cap below the file's own
        // rules out the first two, and the server scales the picture down to fit.
        let body = PlaybackInfoDto(
            audioStreamIndex: options.audioIndex,
            deviceProfile: Self.deviceProfile,
            enableDirectPlay: true,
            enableDirectStream: true,
            enableTranscoding: true,
            maxStreamingBitrate: options.maxBitrate ?? Self.deviceProfile.maxStreamingBitrate,
            mediaSourceID: options.mediaSourceID,
            subtitleStreamIndex: options.subtitleIndex,
            userID: session.userID
        )
        let response = try await send(Paths.getPostedPlaybackInfo(itemID: item.id, parameters: nil, body), with: client)

        guard let source = response.mediaSources?.first, let sourceID = source.id else {
            throw MediaServiceError.itemNotPlayable
        }

        let method: PlaybackMethod
        let path: String
        if source.isSupportsDirectPlay == true {
            // Static stream of the original file.
            method = .directPlay
            var components = URLComponents()
            components.path = "/Videos/\(item.id)/stream"
            components.queryItems = [
                URLQueryItem(name: "static", value: "true"),
                URLQueryItem(name: "mediaSourceId", value: sourceID),
                URLQueryItem(name: "deviceId", value: identity.deviceID),
                URLQueryItem(name: "tag", value: source.eTag)
            ].filter { $0.value != nil }
            path = components.string ?? components.path
        } else if let transcodingURL = source.transcodingURL {
            // The server hands back a ready-made HLS URL (remux or transcode).
            method = source.isSupportsDirectStream == true ? .directStream : .transcode
            path = transcodingURL
        } else {
            throw MediaServiceError.itemNotPlayable
        }

        guard let url = client.url(path: path) else { throw MediaServiceError.itemNotPlayable }

        let streams = source.mediaStreams ?? []
        func tracks(of type: MediaStreamType) -> [MediaTrack] {
            streams.compactMap { stream in
                guard stream.type == type, let index = stream.index else { return nil }
                let title = stream.displayTitle ?? stream.title ?? stream.language ?? String(localized: "Track \(index)")
                // Text subtitles are fetched as WebVTT and drawn by the app (see `SubtitleOverlay`): the player's
                // own HLS subtitles drift out of step with the speech.
                let subtitleURL = type == .subtitle && stream.isTextSubtitleStream == true
                    ? client.url(path: "/Videos/\(item.id)/\(sourceID)/Subtitles/\(index)/0/Stream.vtt")
                        .map { Self.addingAccessToken(client.accessToken, to: $0) }
                    : nil
                return MediaTrack(index: index, title: title, isExternal: stream.isExternal == true, url: subtitleURL)
            }
        }

        // The server echoes the tracks it picked as the source's defaults; -1 means none.
        let audioIndex = options.audioIndex ?? source.defaultAudioStreamIndex
        let subtitleIndex = (options.subtitleIndex ?? source.defaultSubtitleStreamIndex)
            .flatMap { $0 == PlaybackOptions.noSubtitles ? nil : $0 }
        let subtitleStream = streams.first { $0.type == .subtitle && $0.index == subtitleIndex }

        return PlaybackInfo(
            url: Self.addingAccessToken(client.accessToken, to: url),
            resumePosition: (item.playedFraction ?? 0) * (item.runtime ?? 0),
            playSessionID: response.playSessionID,
            mediaSourceID: sourceID,
            method: method,
            audioTracks: tracks(of: .audio),
            subtitleTracks: tracks(of: .subtitle),
            audioIndex: audioIndex,
            subtitleIndex: subtitleIndex,
            subtitlesBurnedIn: subtitleStream?.deliveryMethod == .encode,
            sourceBitrate: source.bitrate,
            sourceHeight: streams.first { $0.type == .video }?.height,
            maxBitrate: options.maxBitrate
        )
    }

    func segments(for item: MediaItem) async -> [MediaSegment] {
        guard let client, let result = try? await send(Paths.getItemSegments(itemID: item.id), with: client) else { return [] }
        return (result.items ?? []).compactMap { segment in
            guard let start = segment.startTicks, let end = segment.endTicks, end > start else { return nil }
            let kind: MediaSegment.Kind = switch segment.type {
            case .intro: .intro
            case .outro: .outro
            case .recap: .recap
            case .preview: .preview
            case .commercial: .commercial
            case .unknown, nil: .unknown
            }
            return MediaSegment(kind: kind, start: Double(start) / Self.ticksPerSecond, end: Double(end) / Self.ticksPerSecond)
        }
        .sorted { $0.start < $1.start }
    }

    func report(_ event: PlaybackEvent, for item: MediaItem, info: PlaybackInfo, position: TimeInterval, isPaused: Bool) async {
        guard let client else { return }
        let ticks = Int(position * Self.ticksPerSecond)

        // Progress reporting is best-effort; a failed report shouldn't interrupt playback.
        switch event {
        case .started, .progress:
            let state = PlaybackStateInfo(
                canSeek: true,
                isPaused: isPaused,
                itemID: item.id,
                mediaSourceID: info.mediaSourceID,
                playMethod: Self.playMethod(for: info.method),
                playSessionID: info.playSessionID,
                positionTicks: ticks
            )
            let request = event == .started ? Paths.reportPlaybackStart(state) : Paths.reportPlaybackProgress(state)
            _ = try? await client.send(request)
        case .stopped:
            let stop = PlaybackStopInfo(
                itemID: item.id,
                mediaSourceID: info.mediaSourceID,
                playSessionID: info.playSessionID,
                positionTicks: ticks
            )
            _ = try? await client.send(Paths.reportPlaybackStopped(stop))
        }
    }

    // MARK: - Watch state

    // The server applies a series' or season's watched state to every episode in it, so one call covers it all.

    func markWatched(itemID: String) async throws {
        let (client, session) = try signedIn()
        _ = try await send(Paths.markPlayedItem(itemID: itemID, userID: session.userID), with: client)
    }

    func markUnwatched(itemID: String) async throws {
        let (client, session) = try signedIn()
        _ = try await send(Paths.markUnplayedItem(itemID: itemID, userID: session.userID), with: client)
    }

    func removeFromContinueWatching(_ item: MediaItem) async throws {
        let (client, session) = try signedIn()
        // The resume list is every item with a saved position, so zeroing it is what removes the item.
        let request = Paths.updateItemUserData(
            itemID: item.id,
            userID: session.userID,
            UpdateUserItemDataDto(playbackPositionTicks: 0)
        )
        _ = try await send(request, with: client)
    }

    // MARK: - Helpers

    /// Extra per-item fields requested beyond the defaults.
    private static let itemFields: [ItemFields] = [
        .overview, .primaryImageAspectRatio, .childCount, .recursiveItemCount, .genres, .studios
    ]

    /// Tells the server what AVPlayer can play natively so it only transcodes when it has to.
    private static let deviceProfile = DeviceProfile(
        directPlayProfiles: [
            DirectPlayProfile(
                audioCodec: "aac,ac3,eac3,mp3,alac,flac",
                container: "mp4,m4v,mov",
                type: .video,
                videoCodec: "h264,hevc"
            )
        ],
        maxStreamingBitrate: 120_000_000,
        name: "Native AVPlayer",
        // Without these the server assumes we can't show subtitles itself and burns them into the video.
        // Text subtitles are delivered separately, and the app draws them from the player's clock, the way the
        // web client does. Inside the HLS stream they drift out of step with the speech.
        subtitleProfiles: [
            SubtitleProfile(format: "vtt", method: .external),
            SubtitleProfile(format: "webvtt", method: .external),
            SubtitleProfile(format: "srt", method: .external),
            SubtitleProfile(format: "subrip", method: .external),
            SubtitleProfile(format: "ass", method: .external),
            SubtitleProfile(format: "ssa", method: .external),
            SubtitleProfile(format: "mov_text", method: .external)
        ],
        transcodingProfiles: [
            TranscodingProfile(
                protocol: .hls,
                audioCodec: "aac,ac3,eac3",
                container: "mp4",
                context: .streaming,
                maxAudioChannels: "6",
                minSegments: 2,
                type: .video,
                videoCodec: "h264,hevc"
            )
        ]
    )

    /// Builds an SDK client for `url`, identifying this app and device to the server.
    private func makeClient(url: URL, accessToken: String?) -> JellyfinClient {
        JellyfinClient(configuration: .init(
            url: url,
            accessToken: accessToken,
            client: identity.name,
            deviceName: identity.deviceName,
            deviceID: identity.deviceID,
            version: identity.version
        ))
    }

    /// The client from `connect(to:)`/`restore(_:)`, which may not be signed in yet.
    private func connectedClient() throws -> JellyfinClient {
        guard let client else { throw MediaServiceError.serverUnreachable }
        return client
    }

    /// The client and session for calls that need a signed-in user.
    private func signedIn() throws -> (JellyfinClient, UserSession) {
        guard let client, let session else { throw MediaServiceError.notSignedIn }
        return (client, session)
    }

    /// Records the session from a successful sign-in so later calls can use it.
    private func storeSession(from result: AuthenticationResult, client: JellyfinClient) throws -> UserSession {
        guard let token = result.accessToken, let userID = result.user?.id else {
            throw MediaServiceError.underlying("The server's sign-in response was incomplete.")
        }
        let url = client.configuration.url

        let session = UserSession(
            server: server ?? ServerInfo(id: result.serverID ?? "", name: url.host() ?? "Jellyfin", url: url),
            userID: userID,
            username: result.user?.name ?? "",
            accessToken: token,
            avatarURL: Self.avatarURL(userID: userID, tag: result.user?.primaryImageTag, client: client)
        )
        self.session = session
        return session
    }

    /// The URL of a user's profile picture, or nil if they haven't set one.
    ///
    /// The server only reports an image tag if the user has uploaded a picture, and the tag changes
    /// whenever the picture does, so the URL changes with it and caches stay correct.
    /// Like item artwork, no token is needed to fetch it.
    private static func avatarURL(userID: String, tag: String?, client: JellyfinClient) -> URL? {
        guard let tag else { return nil }
        return client.url(path: "/UserImage?userId=\(userID)&tag=\(tag)")
    }

    /// Sends a request and unwraps its value, converting SDK errors to `MediaServiceError`.
    private func send<T: Decodable & Sendable>(_ request: Request<T>, with client: JellyfinClient) async throws -> T {
        do {
            return try await client.send(request).value
        } catch {
            throw Self.mapError(error)
        }
    }

    private func mapItems(_ result: BaseItemDtoQueryResult, client: JellyfinClient) -> [MediaItem] {
        (result.items ?? []).compactMap { Self.makeItem(from: $0, client: client) }
    }

    private static func mapError(_ error: Error) -> MediaServiceError {
        switch error {
        case let error as MediaServiceError:
            error
        case is URLError:
            .serverUnreachable
        case APIError.unacceptableStatusCode(let code) where code == 401:
            // Only ever sent with a token, so a 401 means the server no longer accepts it.
            .sessionExpired
        default:
            .underlying(error.localizedDescription)
        }
    }

    /// "jellyfin.local:8096" → https://… then http://…; an explicit scheme is used as-is.
    ///
    /// Falling back to HTTP is what makes LAN servers work without typing a scheme, but it means the
    /// connection may be unencrypted. The sign-in screen warns when it is.
    private static func candidateURLs(from address: String) -> [URL] {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let strings = trimmed.contains("://") ? [trimmed] : ["https://\(trimmed)", "http://\(trimmed)"]
        return strings.compactMap { string in
            guard let url = URL(string: string), url.host() != nil else { return nil }
            return url
        }
    }

    /// AVPlayer can't attach auth headers to every HLS segment request, so the token goes in the URL.
    ///
    /// Works on the percent-encoded query so the server's own parameters are passed through byte for byte.
    private static func addingAccessToken(_ token: String?, to url: URL) -> URL {
        guard let token,
              // `&`, `=` and `+` are legal in a query but would change its meaning inside a value.
              let encodedToken = token.addingPercentEncoding(
                  withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+"))
              ),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }

        var items = components.percentEncodedQueryItems ?? []
        let hasKey = items.contains { $0.name.caseInsensitiveCompare("ApiKey") == .orderedSame }
        if !hasKey { items.append(URLQueryItem(name: "ApiKey", value: encodedToken)) }
        components.percentEncodedQueryItems = items
        return components.url ?? url
    }

    private static func playMethod(for method: PlaybackMethod) -> PlayMethod {
        switch method {
        case .directPlay: .directPlay
        case .directStream: .directStream
        case .transcode: .transcode
        }
    }

    /// Maps an SDK item DTO to a `MediaItem`, or nil if it lacks the ID or name every item needs.
    /// - Parameter isExtra: Whether the item came from a list of extras. Those are also recognized by their
    ///   `extraType`, but a server may leave that out.
    private static func makeItem(from dto: BaseItemDto, client: JellyfinClient, isExtra: Bool = false) -> MediaItem? {
        guard let id = dto.id, let title = dto.name else { return nil }

        let kind: MediaItem.Kind
        if isExtra || dto.extraType != nil {
            kind = .extra
        } else {
            kind = switch dto.type {
            case .movie: .movie
            case .series: .series
            case .season: .season
            case .episode: .episode
            default: .other
            }
        }

        let runtime = dto.runTimeTicks.map { Double($0) / ticksPerSecond }

        // Only report progress for items actually started; the server also gives a percentage for finished ones.
        var playedFraction: Double?
        if let position = dto.userData?.playbackPositionTicks, position > 0,
           let percentage = dto.userData?.playedPercentage {
            playedFraction = min(max(percentage / 100, 0), 1)
        }

        return MediaItem(
            id: id,
            title: title,
            kind: kind,
            overview: dto.overview,
            year: dto.productionYear,
            runtime: runtime,
            posterURL: posterURL(for: dto, id: id, client: client),
            backdropURL: backdropURL(for: dto, id: id, client: client),
            thumbnailURL: thumbnailURL(for: dto, id: id, isExtra: kind == .extra, client: client),
            playedFraction: playedFraction,
            isPlayed: dto.userData?.isPlayed ?? false,
            seriesTitle: dto.seriesName,
            seasonNumber: dto.parentIndexNumber,
            episodeNumber: dto.indexNumber,
            extraLabel: kind == .extra ? extraLabel(for: dto.extraType) : nil,
            airDate: kind == .episode ? dto.premiereDate : nil,
            seriesID: dto.seriesID,
            seasonID: kind == .episode ? dto.seasonID : nil,
            episodeCount: episodeCount(of: dto, kind: kind),
            seasonCount: kind == .series ? dto.childCount : nil,
            unwatchedEpisodeCount: kind == .series || kind == .season ? dto.userData?.unplayedItemCount : nil,
            logoURL: logoURL(for: dto, id: id, client: client),
            genres: dto.genres ?? [],
            // A show's first studio is its original network. A movie's is its first listed studio, which the app
            // shows in the same place, as the "network" line under the title.
            network: kind == .series || kind == .movie ? dto.studios?.first?.name : nil,
            officialRating: dto.officialRating,
            communityRating: dto.communityRating.map(Double.init),
            criticRating: dto.criticRating.map(Double.init),
            technicalLine: technicalLine(of: dto),
            status: dto.status,
            endYear: dto.endDate.map { Calendar.utc.component(.year, from: $0) },
            tagline: dto.taglines?.first(where: { !$0.isEmpty }),
            trailerURL: dto.remoteTrailers?.lazy.compactMap { $0.url.flatMap(webURL(from:)) }.first,
            isFavorite: dto.userData?.isFavorite ?? false,
            people: people(of: dto, client: client),
            chapters: chapters(of: dto, id: id, client: client)
        )
    }

    /// The item's chapters, with a still for each that has one.
    private static func chapters(of dto: BaseItemDto, id: String, client: JellyfinClient) -> [MediaChapter] {
        (dto.chapters ?? []).enumerated().map { index, chapter in
            MediaChapter(
                name: chapter.name ?? "",
                start: Double(chapter.startPositionTicks ?? 0) / ticksPerSecond,
                imageURL: chapter.imageTag.flatMap {
                    client.url(path: "/Items/\(id)/Images/Chapter/\(index)?maxWidth=\(backdropWidth / 4)&tag=\($0)")
                }
            )
        }
    }

    /// The item's own logo, falling back to its parent's (a series' logo, for its seasons and episodes).
    private static func logoURL(for dto: BaseItemDto, id: String, client: JellyfinClient) -> URL? {
        if let tag = dto.imageTags?[ImageType.logo.rawValue] {
            return imageURL(itemID: id, type: .logo, tag: tag, width: logoWidth, client: client)
        }
        if let parentID = dto.parentLogoItemID, let tag = dto.parentLogoImageTag {
            return imageURL(itemID: parentID, type: .logo, tag: tag, width: logoWidth, client: client)
        }
        return nil
    }

    /// The item's cast and crew, leaving out kinds of credit the app doesn't show (e.g. music credits) and repeats.
    private static func people(of dto: BaseItemDto, client: JellyfinClient) -> [MediaPerson] {
        var seen = Set<String>()
        return (dto.people ?? []).compactMap { person in
            guard let personID = person.id, let name = person.name else { return nil }
            let role: MediaPerson.Role
            switch person.type {
            case .actor, .guestStar: role = .actor
            case .director: role = .director
            case .writer: role = .writer
            case .producer: role = .producer
            case .creator: role = .creator
            case .composer: role = .composer
            default: return nil
            }
            let image = person.primaryImageTag.flatMap {
                imageURL(itemID: personID, type: .primary, tag: $0, width: posterWidth, client: client)
            }
            let largeImage = person.primaryImageTag.flatMap {
                imageURL(itemID: personID, type: .primary, tag: $0, width: largePortraitWidth, client: client)
            }
            let result = MediaPerson(
                personID: personID,
                role: role,
                name: name,
                character: role == .actor ? person.role.flatMap { $0.isEmpty ? nil : $0 } : nil,
                imageURL: image,
                largeImageURL: largeImage
            )
            return seen.insert(result.id).inserted ? result : nil
        }
    }

    /// The URL for a link the server supplied, only if it's a web page. The server is trusted to describe media, not
    /// to choose what the app opens, so a `tel:`, custom-scheme or `file:` link is dropped.
    private static func webURL(from string: String) -> URL? {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host() != nil else { return nil }
        return url
    }

    /// Whether a provider ID is only letters and digits, as IMDb's (`tt0903747`) and TMDb's are, so it can't change
    /// the path or host of the link it's put into.
    private static func isPlainID(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// e.g. "Behind the Scenes" for an extra's type, or nil if the server doesn't say.
    private static func extraLabel(for type: ExtraType?) -> String? {
        switch type {
        case .behindTheScenes: String(localized: "Behind the Scenes")
        case .deletedScene: String(localized: "Deleted Scene")
        case .interview: String(localized: "Interview")
        case .featurette: String(localized: "Featurette")
        case .trailer: String(localized: "Trailer")
        case .clip: String(localized: "Clip")
        case .scene: String(localized: "Scene")
        case .short: String(localized: "Short")
        case .sample: String(localized: "Sample")
        case .themeVideo: String(localized: "Theme Video")
        case .themeSong, .unknown, nil: nil
        }
    }

    /// e.g. "4K · Dolby Vision · Dolby Atmos 7.1": the resolution, dynamic range (if not plain SDR) and main audio
    /// of the item's video file. Nil if the item has no streams listed.
    private static func technicalLine(of dto: BaseItemDto) -> String? {
        let streams = dto.mediaStreams ?? dto.mediaSources?.first?.mediaStreams ?? []
        let video = streams.first { $0.type == .video }
        // The default audio track, else the first.
        let audio = streams.first { $0.type == .audio && $0.isDefault == true } ?? streams.first { $0.type == .audio }

        let parts = [video.flatMap(resolutionLabel(of:)), video.flatMap(dynamicRangeLabel(of:)), audio.flatMap(audioLabel(of:))]
        let line = parts.compactMap { $0 }
        return line.isEmpty ? nil : line.joined(separator: " · ")
    }

    /// "4K", "1080p" and so on. It goes by width, because a widescreen film's picture is shorter than its format.
    private static func resolutionLabel(of video: MediaStream) -> String? {
        guard let width = video.width else { return nil }
        switch width {
        case 3500...: return "4K"
        case 2400...: return "1440p"
        case 1800...: return "1080p"
        case 1200...: return "720p"
        default: return String(localized: "SD")
        }
    }

    /// "Dolby Vision", "HDR10+", "HDR10" or "HLG"; nil for ordinary (SDR) video.
    private static func dynamicRangeLabel(of video: MediaStream) -> String? {
        switch video.videoRangeType {
        case .dovi, .doviWithHDR10, .doviWithHLG, .doviWithEL, .doviWithHDR10Plus, .doviWithELHDR10Plus: "Dolby Vision"
        case .hdr10Plus: "HDR10+"
        case .hdr10: "HDR10"
        case .hlg: "HLG"
        default: nil
        }
    }

    /// e.g. "Dolby Atmos 7.1", "Dolby Digital Plus 5.1" or "AAC 2.0".
    private static func audioLabel(of audio: MediaStream) -> String? {
        let profile = audio.profile?.lowercased() ?? ""
        let format: String? = switch audio.codec?.lowercased() {
        case "truehd": "Dolby TrueHD"
        case "eac3": "Dolby Digital Plus"
        case "ac3": "Dolby Digital"
        case "dts": profile.contains("ma") ? "DTS-HD MA" : profile.contains("hra") ? "DTS-HD HRA" : "DTS"
        case "aac": "AAC"
        case "flac": "FLAC"
        case "opus": "Opus"
        case "mp3": "MP3"
        case "pcm_s16le", "pcm_s24le", "pcm_s32le": "PCM"
        case .some(let other): other.uppercased()
        case nil: nil
        }

        // An object-based mix is named for what it is, whatever the file's codec.
        let name: String? = switch audio.audioSpatialFormat {
        case .dolbyAtmos: "Dolby Atmos"
        case .dtsx: "DTS:X"
        default: format
        }

        let layout: String? = audio.channels.map { channels in
            switch channels {
            case 1: "1.0"
            case 2: "2.0"
            case 6: "5.1"
            case 8: "7.1"
            default: "\(channels)ch"
            }
        }

        let parts = [name, layout].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// How many episodes a series or season has, or nil for anything else.
    private static func episodeCount(of dto: BaseItemDto, kind: MediaItem.Kind) -> Int? {
        switch kind {
        // A series' child count is its seasons, so only its recursive count is its episodes.
        case .series: dto.recursiveItemCount
        case .season: dto.recursiveItemCount ?? dto.childCount
        default: nil
        }
    }

    /// An image URL on the server. The `tag` makes the URL change when the image does, so caches stay correct.
    private static func imageURL(itemID: String, type: ImageType, tag: String, width: Int, client: JellyfinClient) -> URL? {
        client.url(path: "/Items/\(itemID)/Images/\(type.rawValue)?maxWidth=\(width)&tag=\(tag)")
    }

    /// The portrait poster.
    ///
    /// An episode uses its show's poster, because its own image is a widescreen still that looks wrong in a
    /// poster slot (see `thumbnailURL(for:id:client:)`). Everything else uses its own poster, falling back to
    /// its series' poster if it has none.
    private static func posterURL(for dto: BaseItemDto, id: String, client: JellyfinClient) -> URL? {
        var ownPoster: URL?
        if let tag = dto.imageTags?[ImageType.primary.rawValue] {
            ownPoster = imageURL(itemID: id, type: .primary, tag: tag, width: posterWidth, client: client)
        }

        var seriesPoster: URL?
        if let seriesID = dto.seriesID, let tag = dto.seriesPrimaryImageTag {
            seriesPoster = imageURL(itemID: seriesID, type: .primary, tag: tag, width: posterWidth, client: client)
        }

        return dto.type == .episode ? (seriesPoster ?? ownPoster) : (ownPoster ?? seriesPoster)
    }

    /// Widescreen artwork for list rows.
    ///
    /// An episode uses its own still (its primary image). A movie uses its thumb image, falling back to its
    /// backdrop. Everything else has none.
    private static func thumbnailURL(for dto: BaseItemDto, id: String, isExtra: Bool, client: JellyfinClient) -> URL? {
        // An extra's own image is a widescreen frame, so it's used as it is, falling back to a thumb or backdrop.
        if isExtra {
            if let tag = dto.imageTags?[ImageType.primary.rawValue] {
                return imageURL(itemID: id, type: .primary, tag: tag, width: posterWidth, client: client)
            }
            if let tag = dto.imageTags?[ImageType.thumb.rawValue] {
                return imageURL(itemID: id, type: .thumb, tag: tag, width: posterWidth, client: client)
            }
            return backdropURL(for: dto, id: id, client: client)
        }
        switch dto.type {
        case .episode:
            guard let tag = dto.imageTags?[ImageType.primary.rawValue] else { return nil }
            return imageURL(itemID: id, type: .primary, tag: tag, width: posterWidth, client: client)
        case .movie:
            if let tag = dto.imageTags?[ImageType.thumb.rawValue] {
                return imageURL(itemID: id, type: .thumb, tag: tag, width: posterWidth, client: client)
            }
            return backdropURL(for: dto, id: id, client: client)
        default:
            return nil
        }
    }

    /// The item's own backdrop, falling back to its parent's.
    private static func backdropURL(for dto: BaseItemDto, id: String, client: JellyfinClient) -> URL? {
        if let tag = dto.backdropImageTags?.first {
            return imageURL(itemID: id, type: .backdrop, tag: tag, width: backdropWidth, client: client)
        }
        if let parentID = dto.parentBackdropItemID, let tag = dto.parentBackdropImageTags?.first {
            return imageURL(itemID: parentID, type: .backdrop, tag: tag, width: backdropWidth, client: client)
        }
        return nil
    }
}

private extension Calendar {
    /// A Gregorian calendar in UTC, for dates the server stores as plain calendar dates.
    nonisolated static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }
}
