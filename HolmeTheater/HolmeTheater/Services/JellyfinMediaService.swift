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
    static let ticksPerSecond = 10_000_000.0

    /// Maximum artwork widths requested from the server, in pixels.
    ///
    /// Posters are shown at about 130 pt wide (220 pt on tvOS), so 450 px is sharp on a 3× phone screen.
    /// Asking for more only costs memory (a decoded image takes width × height × 4 bytes) and bandwidth.
    static let posterWidth = 450
    static let backdropWidth = 1280
    static let logoWidth = 800

    /// How many similar titles to ask for.
    private static let similarLimit = 20

    /// How wide a person's portrait is asked for when it fills the screen.
    static let largePortraitWidth = 1200

    private let identity: ClientIdentity

    /// Set by `connect(to:)` or `restore(_:)`; nil until then.
    private var client: JellyfinClient?
    private var server: ServerInfo?

    /// Counts calls to `connect(to:)`, so only the latest one sets `client`. An earlier one can finish last (its HTTPS
    /// attempt timed out first, say), and letting it win would send the user's password to a server they've since
    /// typed over, maybe without encryption.
    private var connectGeneration = 0

    /// Set once signed in; nil while only connected.
    private var session: UserSession? {
        didSet {
            // What was cached belongs to the account (and server) it was fetched for; another one starts empty.
            if session?.userID != oldValue?.userID || session?.server.url != oldValue?.server.url {
                onThisDayCache = nil
                mergedPrefixes = [:]
            }
        }
    }

    init(identity: ClientIdentity) {
        self.identity = identity
    }

    // MARK: - Connection & auth

    func connect(to address: String) async throws -> ServerInfo {
        let candidates = Self.candidateURLs(from: address)
        guard !candidates.isEmpty else { throw MediaServiceError.invalidServerURL }

        connectGeneration += 1
        let generation = connectGeneration

        // Keep every attempt's failure so the user sees why each URL didn't work.
        var failures: [String] = []

        for url in candidates {
            let candidate = makeClient(url: url, accessToken: nil)
            let info: PublicSystemInfo
            do {
                // The public info endpoint needs no authentication, so it doubles as a "is this Jellyfin?" check.
                info = try await candidate.send(Paths.getPublicSystemInfo).value
            } catch {
                // Nor is the next address worth trying for a connect that has been superseded.
                guard generation == connectGeneration else { throw CancellationError() }
                failures.append("\(url.absoluteString): \(Self.connectFailureDescription(error))")
                continue
            }
            // A newer connect started while this one waited, and the server it finds is the one to use.
            guard generation == connectGeneration else { throw CancellationError() }
            let server = ServerInfo(
                id: info.id ?? "",
                name: info.serverName ?? url.host() ?? "Jellyfin",
                url: url
            )
            client = candidate
            self.server = server
            session = nil
            return server
        }

        throw MediaServiceError.underlying("Couldn't connect to a Jellyfin server.\n" + failures.joined(separator: "\n"))
    }

    func serverBranding() async -> ServerBranding? {
        guard let client, let options = try? await client.send(Paths.getBrandingOptions).value else { return nil }

        // The server's web page takes HTML here; this is plain text, so tags go and line breaks stay.
        let disclaimer = options.loginDisclaimer?
            .replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .decodingHTMLEntities()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let splash = options.isSplashscreenEnabled == true
            ? client.configuration.url.appending(path: "Branding/Splashscreen")
            : nil

        let branding = ServerBranding(loginDisclaimer: disclaimer?.isEmpty == false ? disclaimer : nil, splashscreenURL: splash)
        return branding.loginDisclaimer == nil && branding.splashscreenURL == nil ? nil : branding
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

    func authorizeQuickConnect(code: String) async throws {
        let (client, session) = try signedIn()
        do {
            _ = try await client.send(Paths.authorizeQuickConnect(code: code, userID: session.userID))
        } catch APIError.unacceptableStatusCode(let status) where status == 400 || status == 404 {
            throw MediaServiceError.underlying(String(localized: "That code isn't right, or it has expired."))
        } catch APIError.unacceptableStatusCode(let status) where status == 403 {
            // Quick Connect is off on the server, or this user can't use it. (A 401 is the saved token being refused,
            // which `mapError` reports as an expired session, as everywhere else.)
            throw MediaServiceError.underlying(String(localized: "Quick Connect isn't available on this server."))
        } catch {
            throw Self.mapError(error)
        }
    }

    func restore(_ session: UserSession) async {
        // A connect still going would replace this client when it finished.
        connectGeneration += 1
        client = makeClient(url: session.server.url, accessToken: session.accessToken)
        server = session.server
        self.session = session
    }

    func signOut() async {
        // Local state goes first, so signing out never waits on the server: one that's down but still routable can take a
        // minute to time out. The token is revoked server-side afterwards, best effort, with the client that holds it.
        let revoking = client
        connectGeneration += 1
        client = nil
        server = nil
        session = nil
        Task {
            // Playback that was showing reports its stop first, with this token, so the server keeps where it got to.
            await waitForStopReports(using: revoking?.accessToken, timeout: .seconds(5))
            try? await revoking?.signOut()
        }
    }

    func authorizedRequest(for url: URL) async -> URLRequest {
        var request = URLRequest(url: url)
        // Only for the server itself, so a URL anywhere else never sees the token.
        guard let client, let token = client.accessToken, !url.isFileURL,
              Self.isSameOrigin(url, client.configuration.url) else { return request }
        request.setValue("MediaBrowser Token=\"\(token)\"", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Whether two URLs have the same scheme, host and port.
    private static func isSameOrigin(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased()
            && a.host()?.lowercased() == b.host()?.lowercased()
            && (a.port ?? defaultPort(a)) == (b.port ?? defaultPort(b))
    }

    private static func defaultPort(_ url: URL) -> Int? {
        switch url.scheme?.lowercased() {
        case "https": 443
        case "http": 80
        default: nil
        }
    }

    func refreshProfile() async throws -> UserSession {
        let (client, session) = try signedIn()
        let user = try await send(Paths.getCurrentUser, with: client)

        let updated = UserSession(
            server: session.server,
            userID: session.userID,
            username: user.name ?? session.username,
            accessToken: session.accessToken,
            avatarURL: Self.avatarURL(userID: session.userID, tag: user.primaryImageTag, client: client),
            canManageCollections: Self.canManageCollections(user.policy)
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
            let role: Library.Role = switch dto.collectionType {
            case .boxsets: .collections
            case .playlists: .playlists
            default: .library
            }
            return Library(id: id, name: name, kind: kind, role: role)
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

    /// Fetches a page that may come from several libraries, which the server can only filter one at a time. With more
    /// than one, each is asked for enough to cover the page, and the results are merged: taking from each library in
    /// turn, so one library's items can't crowd the others off the page, then, with `byLastPlayed`, by when each was last
    /// played, newest first, which is the order the server would have given them in.
    ///
    /// What each library sent is kept (see ``mergedPrefixes``), so a later page asks each only for what it hasn't sent
    /// yet, rather than everything up to that page again. A first page starts over, which is also how a refresh asks.
    private func page(
        _ list: String,
        from libraryIDs: [String]?,
        offset: Int,
        limit: Int,
        byLastPlayed: Bool = false,
        _ fetch: @escaping @Sendable (_ parentID: String?, _ offset: Int, _ limit: Int) async throws -> [MediaItem]
    ) async throws -> [MediaItem] {
        guard let libraryIDs else { return try await fetch(nil, offset, limit) }
        if libraryIDs.count == 1 { return try await fetch(libraryIDs[0], offset, limit) }

        func key(_ id: String) -> String { "\(list)|\(id)" }
        if offset == 0 {
            for id in libraryIDs { mergedPrefixes[key(id)] = nil }
        }
        let needed = offset + limit
        let starts = libraryIDs.map { ($0, mergedPrefixes[key($0)] ?? MergedPrefix()) }
        let prefixes = try await Self.fetchEach(starts) { start in
            let (id, prefix) = start
            guard prefix.items.count < needed, !prefix.isComplete else { return prefix }
            let wanted = needed - prefix.items.count
            let more = try await fetch(id, prefix.items.count, wanted)
            return MergedPrefix(items: prefix.items + more, isComplete: more.count < wanted)
        }
        for (id, prefix) in zip(libraryIDs, prefixes) { mergedPrefixes[key(id)] = prefix }
        let lists = prefixes.map { Array($0.items.prefix(needed)) }

        var seen = Set<MediaItem.ID>()
        var merged: [MediaItem] = []
        for position in 0..<(lists.map(\.count).max() ?? 0) {
            for list in lists where position < list.count && seen.insert(list[position].id).inserted {
                merged.append(list[position])
            }
        }
        if byLastPlayed {
            // Stable, so items played at the same moment (or never) keep their turn-by-turn order.
            merged = merged.enumerated()
                .sorted { a, b in
                    switch (a.element.lastPlayedDate, b.element.lastPlayedDate) {
                    case let (x?, y?) where x != y: x > y
                    case (_?, nil): true
                    case (nil, _?): false
                    default: a.offset < b.offset
                    }
                }
                .map(\.element)
        }
        return Array(merged.dropFirst(offset).prefix(limit))
    }

    /// The start of one library's list, as far as it has been fetched for a page merged from several.
    private nonisolated struct MergedPrefix: Sendable {
        var items: [MediaItem] = []
        /// Whether the library sent fewer than it was asked for, so there's no more to ask it for.
        var isComplete = false
    }

    /// What each library has sent for a list merged from several, by the list's name and the library's ID.
    private var mergedPrefixes: [String: MergedPrefix] = [:]

    /// Runs `fetch` for every library at once, rather than one after another, and returns the results in the libraries'
    /// order.
    private static func fetchEach<ID: Sendable, Result: Sendable>(
        _ ids: [ID],
        _ fetch: @escaping @Sendable (ID) async throws -> Result
    ) async throws -> [Result] {
        try await withThrowingTaskGroup(of: (Int, Result).self) { group in
            for (index, id) in ids.enumerated() {
                group.addTask { (index, try await fetch(id)) }
            }
            var results = [Result?](repeating: nil, count: ids.count)
            for try await (index, result) in group { results[index] = result }
            return results.compactMap { $0 }
        }
    }

    func resumeItems(offset: Int, limit: Int, libraryIDs: [String]?) async throws -> [MediaItem] {
        let (client, session) = try signedIn()
        return try await page("resume", from: libraryIDs, offset: offset, limit: limit, byLastPlayed: true) { parentID, offset, limit in
            let request = Paths.getResumeItems(parameters: .init(
                userID: session.userID,
                startIndex: offset,
                limit: limit,
                parentID: parentID,
                fields: Self.itemFields,
                mediaTypes: [.video],
                enableUserData: true
            ))
            return try await self.mapItems(self.send(request, with: client), client: client)
        }
    }

    func nextUpItems(offset: Int, limit: Int, libraryIDs: [String]?) async throws -> [MediaItem] {
        let (client, session) = try signedIn()
        return try await page("nextUp", from: libraryIDs, offset: offset, limit: limit) { parentID, offset, limit in
            let request = Paths.getNextUp(parameters: .init(
                userID: session.userID,
                startIndex: offset,
                limit: limit,
                fields: Self.itemFields,
                parentID: parentID,
                enableUserData: true,
                // Partly watched episodes already show under Continue Watching, and a show you've finished
                // shouldn't come back around.
                enableResumable: false,
                enableRewatching: false
            ))
            return try await self.mapItems(self.send(request, with: client), client: client)
        }
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

    func randomItems(in library: Library, limit: Int) async throws -> [MediaItem] {
        let (client, session) = try signedIn()
        let request = Paths.getItems(parameters: .init(
            userID: session.userID,
            limit: limit,
            isRecursive: true,
            parentID: library.id,
            fields: Self.itemFields,
            includeItemTypes: library.kind == .tvShows ? [.series] : [.movie],
            sortBy: [.random],
            enableUserData: true
        ))
        return try await mapItems(send(request, with: client), client: client)
    }

    func recentlyReleasedPage(in library: Library, offset: Int, limit: Int) async throws -> [MediaItem] {
        let (client, session) = try signedIn()

        let includeTypes: [BaseItemKind]? = switch library.kind {
        case .movies: [.movie]
        case .tvShows: [.episode]
        case .music, .other: nil
        }
        let request = Paths.getItems(parameters: .init(
            userID: session.userID,
            // Not past today, so what's still to come isn't first in the list.
            maxPremiereDate: .now,
            startIndex: offset,
            limit: limit,
            isRecursive: includeTypes != nil,
            sortOrder: [.descending],
            parentID: library.id,
            fields: Self.itemFields,
            includeItemTypes: includeTypes,
            // Sorted by release date.
            sortBy: [.premiereDate],
            enableUserData: true
        ))
        return try await mapItems(send(request, with: client), client: client)
    }

    /// What was found for one day in one set of libraries, so the home screen and the list behind its shelf don't
    /// ask the server again.
    private var onThisDayCache: (month: Int, day: Int, libraryIDs: [String]?, items: [MediaItem])?

    func itemsOnThisDay(libraryIDs: [String]?) async throws -> [MediaItem] {
        let (client, session) = try signedIn()

        let today = Calendar.current.dateComponents([.month, .day], from: .now)
        guard let month = today.month, let day = today.day else { return [] }
        if let cache = onThisDayCache, cache.month == month, cache.day == day, cache.libraryIDs == libraryIDs {
            return cache.items
        }

        // The server can't filter by month and day, only by date range, so it's asked for every movie and episode and
        // they're filtered here. Shows and seasons are left out; only the episodes released on the day count. Only the little that cards need is requested, since there can be thousands.
        let parentIDs: [String?] = libraryIDs ?? [nil]
        let items = try await Self.fetchEach(parentIDs) { parentID in
            let request = Paths.getItems(parameters: .init(
                userID: session.userID,
                isRecursive: true,
                parentID: parentID,
                fields: [.primaryImageAspectRatio, .childCount, .recursiveItemCount],
                includeItemTypes: [.movie, .episode],
                enableUserData: true
            ))
            return try await self.mapItems(self.send(request, with: client), client: client)
        }.flatMap { $0 }

        // Premiere dates are calendar dates stored at midnight UTC, so they're read as UTC, not in the user's zone.
        let calendar = Calendar.utc
        let matches = items
            .filter { item in
                guard let date = item.releaseDate else { return false }
                let components = calendar.dateComponents([.month, .day], from: date)
                return components.month == month && components.day == day
            }
            .sorted { ($0.releaseDate ?? .distantPast) > ($1.releaseDate ?? .distantPast) }
        onThisDayCache = (month, day, libraryIDs, matches)
        return matches
    }

    func items(withIDs ids: [String]) async throws -> [MediaItem] {
        guard !ids.isEmpty else { return [] }
        let (client, session) = try signedIn()
        let request = Paths.getItems(parameters: .init(
            userID: session.userID,
            fields: Self.itemFields,
            enableUserData: true,
            ids: ids
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

    func genres() async throws -> [Genre] {
        let (client, session) = try signedIn()
        let request = Paths.getGenres(parameters: .init(
            includeItemTypes: [.movie, .series],
            userID: session.userID,
            sortBy: [.sortName],
            sortOrder: [.ascending]
        ))
        return try await send(request, with: client).items?.compactMap { dto in
            guard let id = dto.id, let name = dto.name else { return nil }
            let image = dto.imageTags?[ImageType.primary.rawValue].flatMap {
                Self.imageURL(itemID: id, type: .primary, tag: $0, width: Self.posterWidth, client: client)
            }
            return Genre(id: id, name: name, imageURL: image)
        } ?? []
    }

    func items(in genre: Genre) async throws -> [MediaItem] {
        let (client, session) = try signedIn()
        let request = Paths.getItems(parameters: .init(
            userID: session.userID,
            isRecursive: true,
            sortOrder: [.ascending],
            fields: Self.itemFields,
            includeItemTypes: [.movie, .series],
            sortBy: [.sortName],
            enableUserData: true,
            genreIDs: [genre.id]
        ))
        return try await mapItems(send(request, with: client), client: client)
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
        case .collection:
            // A collection's members, which can be movies or shows. Sorted by release, as a film series is watched.
            let request = Paths.getItems(parameters: .init(
                userID: session.userID,
                sortOrder: [.ascending],
                parentID: item.id,
                fields: Self.itemFields,
                sortBy: [.premiereDate, .sortName],
                enableUserData: true
            ))
            return try await mapItems(send(request, with: client), client: client)
        case .playlist:
            // In the playlist's own order. Each entry carries the ID that removing or moving it needs.
            let request = Paths.getPlaylistItems(
                playlistID: item.id,
                parameters: .init(userID: session.userID, fields: Self.itemFields, enableUserData: true)
            )
            return try await mapItems(send(request, with: client), client: client)
        case .movie, .episode, .extra, .other:
            return []
        }
    }

    // MARK: - Collections

    func collections() async throws -> [MediaItem] {
        let (client, session) = try signedIn()
        let request = Paths.getItems(parameters: .init(
            userID: session.userID,
            isRecursive: true,
            sortOrder: [.ascending],
            fields: Self.itemFields,
            includeItemTypes: [.boxSet],
            sortBy: [.sortName],
            enableUserData: true
        ))
        return try await mapItems(send(request, with: client), client: client)
    }

    func createCollection(named name: String, itemIDs: [String]) async throws -> MediaItem {
        let (client, _) = try signedIn()
        let created = try await send(Paths.createCollection(parameters: .init(name: name, ids: itemIDs)), with: client)
        guard let id = created.id else { throw MediaServiceError.underlying(String(localized: "The server didn't create the collection.")) }
        return try await item(id: id)
    }

    func addItems(withIDs itemIDs: [String], toCollection collectionID: String) async throws {
        let (client, _) = try signedIn()
        try await send(Paths.addToCollection(collectionID: collectionID, ids: itemIDs), with: client)
    }

    func removeItems(withIDs itemIDs: [String], fromCollection collectionID: String) async throws {
        let (client, _) = try signedIn()
        try await send(Paths.removeFromCollection(collectionID: collectionID, ids: itemIDs), with: client)
    }

    // MARK: - Playlists

    func playlists() async throws -> [MediaItem] {
        let (client, session) = try signedIn()
        let request = Paths.getItems(parameters: .init(
            userID: session.userID,
            isRecursive: true,
            sortOrder: [.ascending],
            fields: Self.itemFields,
            includeItemTypes: [.playlist],
            sortBy: [.sortName],
            enableUserData: true
        ))
        return try await mapItems(send(request, with: client), client: client)
    }

    func createPlaylist(named name: String, itemIDs: [String]) async throws -> MediaItem {
        let (client, session) = try signedIn()
        let body = CreatePlaylistDto(ids: itemIDs, name: name, userID: session.userID)
        let created = try await send(Paths.createPlaylist(body), with: client)
        guard let id = created.id else { throw MediaServiceError.underlying(String(localized: "The server didn't create the playlist.")) }
        return try await item(id: id)
    }

    func addItems(withIDs itemIDs: [String], toPlaylist playlistID: String) async throws {
        let (client, session) = try signedIn()
        let request = Paths.addItemToPlaylist(
            playlistID: playlistID,
            parameters: .init(ids: itemIDs, userID: session.userID)
        )
        try await send(request, with: client)
    }

    func removeEntries(withIDs entryIDs: [String], fromPlaylist playlistID: String) async throws {
        let (client, _) = try signedIn()
        try await send(Paths.removeItemFromPlaylist(playlistID: playlistID, entryIDs: entryIDs), with: client)
    }

    func moveEntry(withID entryID: String, inPlaylist playlistID: String, to index: Int) async throws {
        let (client, _) = try signedIn()
        try await send(Paths.moveItem(playlistID: playlistID, itemID: entryID, newIndex: index), with: client)
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
            // Direct play must stay on: with it off, the server doesn't remux a file AVPlayer can already play, but
            // re-encodes its video, and a 4K re-encode can't keep up with playback, so the buffer drains and the
            // picture freezes. (The player waiting to minimise stalling, set in `PlaybackSession`, is what keeps a
            // direct-play file from freezing the picture while the audio carries on.)
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
        let streamURL: URL?
        if source.isSupportsDirectPlay == true {
            // Static stream of the original file.
            method = .directPlay
            streamURL = Self.serverURL(client, path: ["Videos", item.id, "stream"], query: [
                "static": "true",
                "mediaSourceId": sourceID,
                "deviceId": identity.deviceID,
                "tag": source.eTag
            ])
        } else if let transcodingURL = source.transcodingURL {
            // The server hands back a ready-made HLS URL (remux or transcode). The SDK puts its path on the server's
            // address, whatever host it names.
            method = source.isSupportsDirectStream == true ? .directStream : .transcode
            streamURL = client.url(path: transcodingURL)
        } else {
            throw MediaServiceError.itemNotPlayable
        }

        guard let url = streamURL else { throw MediaServiceError.itemNotPlayable }

        let streams = source.mediaStreams ?? []
        func tracks(of type: MediaStreamType) -> [MediaTrack] {
            streams.compactMap { stream in
                guard stream.type == type, let index = stream.index else { return nil }
                let title = stream.displayTitle ?? stream.title ?? stream.language ?? String(localized: "Track \(index)")
                // Text subtitles are fetched as WebVTT and drawn by the app (see `SubtitleOverlay`): the player's
                // own HLS subtitles drift out of step with the speech. PGS pictures are fetched as they are, which the
                // server (10.9 and later) only offers for a track it's sending separately; an older one burns them in.
                // SubStation Alpha is fetched as it is too (as the web client does), since its WebVTT leaves out the
                // picture size its positions are measured on and the alignment its styles give.
                var subtitleURL: URL?
                var format: SubtitleFormat?
                let codec = stream.codec?.lowercased()
                func subtitleStream(_ fileName: String) -> URL? {
                    Self.serverURL(client, path: ["Videos", item.id, sourceID, "Subtitles", String(index), "0", fileName])
                }
                // No token in the URL: the app fetches these itself, with it in a header (see `authorizedRequest(for:)`).
                if type == .subtitle, stream.isTextSubtitleStream == true, let codec, codec == "ass" || codec == "ssa" {
                    subtitleURL = subtitleStream("Stream.\(codec)")
                    format = .ass
                } else if type == .subtitle, stream.isTextSubtitleStream == true {
                    subtitleURL = subtitleStream("Stream.vtt")
                    format = .webVTT
                } else if type == .subtitle, codec == "pgssub", stream.deliveryMethod == .external {
                    subtitleURL = stream.deliveryURL.flatMap { client.url(path: $0) } ?? subtitleStream("Stream.pgssub")
                    format = .pgs
                }
                return MediaTrack(index: index, title: title, isExternal: stream.isExternal == true, url: subtitleURL,
                                  format: format, isForced: type == .subtitle ? stream.isForced : nil)
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
            maxBitrate: options.maxBitrate,
            expectedBytes: source.size.map { Int64($0) }
        )
    }

    func downloadInfo(for item: MediaItem) async throws -> PlaybackInfo {
        var info = try await playbackInfo(for: item, options: PlaybackOptions())
        // A download is fetched by the app's own session, which sends the token in a header (see
        // `authorizedRequest(for:)`), so it stays out of the URL and the server's logs.
        info.url = info.url.removingAccessToken()
        // The original file, as it is on the server.
        if info.method == .directPlay { return info }

        // A file this device can't play as it is (an MKV, say) has no plain URL, only an HLS playlist, which
        // URLSession can't save as one file. Ask for the same thing as a progressive MP4 instead.
        let (client, _) = try signedIn()
        guard let sourceID = info.mediaSourceID else { throw MediaServiceError.itemNotPlayable }
        guard let url = Self.serverURL(client, path: ["Videos", item.id, "stream.mp4"], query: [
            "mediaSourceId": sourceID,
            "deviceId": identity.deviceID,
            "videoCodec": "h264",
            "audioCodec": "aac",
            "maxAudioChannels": "6",
            "audioStreamIndex": info.audioIndex.map(String.init)
        ]) else { throw MediaServiceError.itemNotPlayable }

        var result = info
        result.url = url
        // The converted file's size isn't known until it's done. Its length at the original's bitrate is a ceiling it
        // usually stays under, which is enough to show roughly how far along it is.
        if let runtime = item.runtime, let bitrate = info.sourceBitrate {
            result.expectedBytes = Int64(runtime * Double(bitrate) / 8)
        } else {
            result.expectedBytes = nil
        }
        // Subtitles come as separate files, so none are drawn into the picture.
        result.subtitlesBurnedIn = false
        return result
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
        // Each playback reports with the client it started with, so its token and user stay the same throughout: a stop
        // reported after sign-out still goes out (before the token is revoked), and one reported after switching accounts
        // never lands on the new account.
        let key = Self.reportKey(item: item, info: info)
        let client: JellyfinClient
        switch event {
        case .started:
            guard let current = self.client, session != nil else { return }
            reportingClients[key] = current
            client = current
        case .progress:
            guard let started = reportingClients[key] else { return }
            client = started
        case .stopped:
            guard let started = reportingClients.removeValue(forKey: key) else { return }
            client = started
        }
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
            stopsInFlight += 1
            _ = try? await client.send(Paths.reportPlaybackStopped(stop))
            stopsInFlight -= 1
        }
    }

    /// The client each playback reported its start with, by ``reportKey(item:info:)``, until it reports its stop.
    private var reportingClients: [String: JellyfinClient] = [:]

    /// How many stop reports are on their way to the server, so revoking the token on sign-out can wait for them.
    private var stopsInFlight = 0

    /// Identifies one playback among those reporting: the server's play session, or the item if it gave none.
    private static func reportKey(item: MediaItem, info: PlaybackInfo) -> String {
        info.playSessionID ?? item.id
    }

    /// Waits, up to `timeout`, for playback started with `token` to report its stop. Sign-out stops the player just
    /// before it signs out, and the stop report would fail if the token were revoked first.
    private func waitForStopReports(using token: String?, timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline,
              stopsInFlight > 0 || reportingClients.values.contains(where: { $0.accessToken == token }) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        // Whatever never reported its stop won't be able to once the token is revoked.
        reportingClients = reportingClients.filter { $0.value.accessToken != token }
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

    func syncProgress(itemID: String, position: TimeInterval, isPlayed: Bool, date: Date) async throws {
        let (client, session) = try signedIn()

        // Another device may have watched it since; the later watch wins.
        let current = try await send(Paths.getItem(itemID: itemID, userID: session.userID), with: client)
        if let serverDate = current.userData?.lastPlayedDate, serverDate > date { return }

        let data = UpdateUserItemDataDto(
            isPlayed: isPlayed,
            lastPlayedDate: date,
            playCount: isPlayed ? max(1, current.userData?.playCount ?? 0) : nil,
            playbackPositionTicks: isPlayed ? 0 : Int(position * Self.ticksPerSecond)
        )
        _ = try await send(Paths.updateItemUserData(itemID: itemID, userID: session.userID, data), with: client)
    }

    // MARK: - Helpers

    /// Extra per-item fields requested beyond the defaults.
    private static let itemFields: [ItemFields] = [
        .overview, .primaryImageAspectRatio, .childCount, .recursiveItemCount, .genres, .studios, .dateCreated, .sortName
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
            SubtitleProfile(format: "mov_text", method: .external),
            // Pictures, which the server can't make text of. Burning them in instead means re-encoding the video, which
            // is slow to start and leaves the app nothing to adjust the timing of. The app draws them (see `PGS`).
            SubtitleProfile(format: "pgssub", method: .external)
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
            avatarURL: Self.avatarURL(userID: userID, tag: result.user?.primaryImageTag, client: client),
            canManageCollections: Self.canManageCollections(result.user?.policy)
        )
        self.session = session
        return session
    }

    /// Whether a user's policy lets them manage collections, which the server allows administrators and anyone granted it.
    /// Nil if the server sent no policy, so nothing is assumed either way.
    private static func canManageCollections(_ policy: UserPolicy?) -> Bool? {
        guard let policy else { return nil }
        return policy.isAdministrator == true || policy.enableCollectionManagement
    }

    /// The URL of a user's profile picture, or nil if they haven't set one.
    ///
    /// The server only reports an image tag if the user has uploaded a picture, and the tag changes
    /// whenever the picture does, so the URL changes with it and caches stay correct.
    /// Like item artwork, no token is needed to fetch it.
    private static func avatarURL(userID: String, tag: String?, client: JellyfinClient) -> URL? {
        guard let tag else { return nil }
        return serverURL(client, path: ["UserImage"], query: ["userId": userID, "tag": tag])
    }

    /// Sends a request and unwraps its value, converting SDK errors to `MediaServiceError`.
    private func send<T: Decodable & Sendable>(_ request: Request<T>, with client: JellyfinClient) async throws -> T {
        do {
            return try await client.send(request).value
        } catch {
            throw Self.mapError(error)
        }
    }

    /// Sends a request that has no response body, converting SDK errors to `MediaServiceError`.
    private func send(_ request: Request<Void>, with client: JellyfinClient) async throws {
        do {
            _ = try await client.send(request)
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

    /// Why one address in `connect(to:)` didn't work, in words the user can act on.
    ///
    /// The app only allows unencrypted HTTP to servers on the local network (`NSAllowsLocalNetworking`), so plain HTTP to
    /// one on the internet is refused before anything is sent. The system's own message for that doesn't say so.
    private static func connectFailureDescription(_ error: Error) -> String {
        if let error = error as? URLError, error.code == .appTransportSecurityRequiresSecureConnection {
            return String(localized: "Unencrypted connections are only allowed to servers on your local network. Use an HTTPS address for this server.")
        }
        return error.localizedDescription
    }

    /// "jellyfin.local:8096" → https://… then http://…; an explicit scheme is used as-is.
    ///
    /// Falling back to HTTP is what makes LAN servers work without typing a scheme, but it means the
    /// connection may be unencrypted. The sign-in screen warns when it is.
    private static func candidateURLs(from address: String) -> [URL] {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // What the user typed with a scheme is used as it is; without one, secure first, then plain.
        let strings = trimmed.contains("://") ? [trimmed] : ["https://\(trimmed)", "http://\(trimmed)"]
        return strings.compactMap { string in
            // Only web addresses: a `file:`, `ftp:` or custom scheme would never reach a Jellyfin server, and the
            // password must never go anywhere else.
            guard let url = URL(string: string), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
                  url.host() != nil else { return nil }
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
}

private extension String {
    /// The text with HTML character references (`&amp;`, `&nbsp;`, `&#39;`, `&#x2014;`) turned into the characters they
    /// stand for. Ones it doesn't know are left as they are.
    nonisolated func decodingHTMLEntities() -> String {
        guard contains("&") else { return self }
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
            "ndash": "\u{2013}", "mdash": "\u{2014}", "hellip": "\u{2026}", "copy": "\u{00A9}", "reg": "\u{00AE}",
            "trade": "\u{2122}", "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}"
        ]
        var result = ""
        var rest = self[...]
        while let ampersand = rest.firstIndex(of: "&") {
            result += rest[..<ampersand]
            let afterAmpersand = rest.index(after: ampersand)
            // A reference is short; a lone "&" in ordinary text has no ";" soon after it.
            guard let semicolon = rest[afterAmpersand...].prefix(10).firstIndex(of: ";") else {
                result += "&"
                rest = rest[afterAmpersand...]
                continue
            }
            let name = rest[afterAmpersand..<semicolon]
            let decoded: String? = if name.hasPrefix("#x") || name.hasPrefix("#X") {
                UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if name.hasPrefix("#") {
                UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                named[String(name)]
            }
            if let decoded {
                result += decoded
                rest = rest[rest.index(after: semicolon)...]
            } else {
                result += "&"
                rest = rest[afterAmpersand...]
            }
        }
        return result + rest
    }
}
