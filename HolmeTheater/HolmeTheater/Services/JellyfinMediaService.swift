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
/// types in `MediaModels.swift`, so no SDK type leaks out of the service.
///
/// This is an actor because it owns mutable connection state (the client and session) that
/// is touched from several concurrent UI tasks.
///
/// This file holds the connection and sign-in flow and the helpers the rest share. Browsing is in
/// `JellyfinMediaService+Browsing.swift`, collections and playlists in `+Collections.swift`, playback and watch state in
/// `+Playback.swift`, and turning the SDK's items into `MediaItem`s in `+Mapping.swift`.
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

    /// How wide a person's portrait is asked for when it fills the screen.
    static let largePortraitWidth = 1200

    let identity: ClientIdentity

    /// Set by `connect(to:)` or `restore(_:)`; nil until then.
    private(set) var client: JellyfinClient?
    private var server: ServerInfo?

    /// Counts calls to `connect(to:)`, so only the latest one sets `client`. An earlier one can finish last (its HTTPS
    /// attempt timed out first, say), and letting it win would send the user's password to a server they've since
    /// typed over, maybe without encryption.
    private var connectGeneration = 0

    /// Set once signed in; nil while only connected.
    private(set) var session: UserSession? {
        didSet {
            // What was cached belongs to the account (and server) it was fetched for; another one starts empty.
            if session?.userID != oldValue?.userID || session?.server.url != oldValue?.server.url {
                onThisDayCache = nil
                mergedPrefixes = [:]
            }
        }
    }

    // MARK: State kept for the extensions

    // Actors can't declare stored properties in extensions, so the state the browsing and playback files keep lives here.

    /// What each library has sent for a list merged from several, by the list's name and the library's ID. See
    /// `page(_:from:offset:limit:byLastPlayed:_:)`.
    var mergedPrefixes: [String: MergedPrefix] = [:]

    /// What was found for one day in one set of libraries, so the home screen and the list behind its shelf don't
    /// ask the server again.
    var onThisDayCache: (month: Int, day: Int, libraryIDs: [String]?, items: [MediaItem])?

    /// The client each playback reported its start with, by `reportKey(item:info:)`, until it reports its stop.
    var reportingClients: [String: JellyfinClient] = [:]

    /// How many stop reports are on their way to the server, so revoking the token on sign-out can wait for them.
    var stopsInFlight = 0

    init(identity: ClientIdentity) {
        self.identity = identity
    }

    // MARK: - Connection & auth

    func connect(to address: String) async throws -> ServerInfo {
        let candidates = ServerAddress.candidateURLs(from: address)
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
        let disclaimer = options.loginDisclaimer?.strippingHTMLTags()
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
              ServerAddress.isSameOrigin(url, client.configuration.url) else { return request }
        request.setValue("MediaBrowser Token=\"\(token)\"", forHTTPHeaderField: "Authorization")
        return request
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

    // MARK: - Helpers

    /// Extra per-item fields requested beyond the defaults.
    static let itemFields: [ItemFields] = [
        .overview, .primaryImageAspectRatio, .childCount, .recursiveItemCount, .genres, .studios, .dateCreated, .sortName
    ]

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
    func signedIn() throws -> (JellyfinClient, UserSession) {
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
    func send<T: Decodable & Sendable>(_ request: Request<T>, with client: JellyfinClient) async throws -> T {
        do {
            return try await client.send(request).value
        } catch {
            throw Self.mapError(error)
        }
    }

    /// Sends a request that has no response body, converting SDK errors to `MediaServiceError`.
    func send(_ request: Request<Void>, with client: JellyfinClient) async throws {
        do {
            _ = try await client.send(request)
        } catch {
            throw Self.mapError(error)
        }
    }

    func mapItems(_ result: BaseItemDtoQueryResult, client: JellyfinClient) -> [MediaItem] {
        (result.items ?? []).compactMap { Self.makeItem(from: $0, client: client) }
    }

    static func mapError(_ error: Error) -> MediaServiceError {
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

    /// Runs `fetch` for every element at once, rather than one after another, and returns the results in the elements'
    /// order.
    static func fetchEach<ID: Sendable, Result: Sendable>(
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
}
