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
    private static let posterWidth = 600
    private static let backdropWidth = 1280

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

    func resumeItems() async throws -> [MediaItem] {
        let (client, session) = try signedIn()
        let request = Paths.getResumeItems(parameters: .init(
            userID: session.userID,
            limit: 16,
            fields: Self.itemFields,
            mediaTypes: [.video],
            enableUserData: true
        ))
        return try await mapItems(send(request, with: client), client: client)
    }

    func latestItems(in library: Library) async throws -> [MediaItem] {
        let (client, session) = try signedIn()
        let request = Paths.getLatestMedia(parameters: .init(
            userID: session.userID,
            parentID: library.id,
            fields: Self.itemFields,
            enableUserData: true,
            limit: 16
        ))
        // Unlike the other endpoints, "latest" returns a bare array rather than a query result.
        let dtos = try await send(request, with: client)
        return dtos.compactMap { Self.makeItem(from: $0, client: client) }
    }

    func recentlyAdded(in library: Library, offset: Int, limit: Int) async throws -> [MediaItem] {
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
        case .movie, .episode, .other:
            return []
        }
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

    func playbackInfo(for item: MediaItem) async throws -> PlaybackInfo {
        let (client, session) = try signedIn()

        // Describe what this device can play (`deviceProfile`) and let the server pick the cheapest
        // way to deliver it: direct play, then remux, then transcode.
        let body = PlaybackInfoDto(
            deviceProfile: Self.deviceProfile,
            enableDirectPlay: true,
            enableDirectStream: true,
            enableTranscoding: true,
            maxStreamingBitrate: Self.deviceProfile.maxStreamingBitrate,
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

        return PlaybackInfo(
            url: Self.addingAccessToken(client.accessToken, to: url),
            resumePosition: (item.playedFraction ?? 0) * (item.runtime ?? 0),
            playSessionID: response.playSessionID,
            mediaSourceID: sourceID,
            method: method
        )
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

    // MARK: - Helpers

    /// Extra per-item fields requested beyond the defaults.
    private static let itemFields: [ItemFields] = [.overview, .primaryImageAspectRatio]

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
            .notSignedIn
        default:
            .underlying(error.localizedDescription)
        }
    }

    /// "jellyfin.local:8096" → https://… then http://…; an explicit scheme is used as-is.
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
    private static func addingAccessToken(_ token: String?, to url: URL) -> URL {
        guard let token, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = components.queryItems ?? []
        let hasKey = items.contains { $0.name.caseInsensitiveCompare("ApiKey") == .orderedSame }
        if !hasKey { items.append(URLQueryItem(name: "ApiKey", value: token)) }
        components.queryItems = items
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
    private static func makeItem(from dto: BaseItemDto, client: JellyfinClient) -> MediaItem? {
        guard let id = dto.id, let title = dto.name else { return nil }

        let kind: MediaItem.Kind = switch dto.type {
        case .movie: .movie
        case .series: .series
        case .season: .season
        case .episode: .episode
        default: .other
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
            playedFraction: playedFraction,
            isPlayed: dto.userData?.isPlayed ?? false,
            seriesTitle: dto.seriesName,
            seasonNumber: dto.parentIndexNumber,
            episodeNumber: dto.indexNumber
        )
    }

    /// An image URL on the server. The `tag` makes the URL change when the image does, so caches stay correct.
    private static func imageURL(itemID: String, type: ImageType, tag: String, width: Int, client: JellyfinClient) -> URL? {
        client.url(path: "/Items/\(itemID)/Images/\(type.rawValue)?maxWidth=\(width)&tag=\(tag)")
    }

    /// The item's own poster, falling back to its series' poster (e.g. for episodes without a thumbnail).
    private static func posterURL(for dto: BaseItemDto, id: String, client: JellyfinClient) -> URL? {
        if let tag = dto.imageTags?[ImageType.primary.rawValue] {
            return imageURL(itemID: id, type: .primary, tag: tag, width: posterWidth, client: client)
        }
        if let seriesID = dto.seriesID, let tag = dto.seriesPrimaryImageTag {
            return imageURL(itemID: seriesID, type: .primary, tag: tag, width: posterWidth, client: client)
        }
        return nil
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
