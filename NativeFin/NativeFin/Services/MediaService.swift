// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// The only surface the UI talks to for anything involving a Jellyfin server.
///
/// `JellyfinMediaService` is the real implementation, wrapping the Jellyfin SDK.
/// `MockMediaService` returns canned data so views can be built and previewed without a server.
/// Implementations are stateful: `connect(to:)` and a sign-in must succeed before the browsing
/// and playback methods work, and they throw ``MediaServiceError/notSignedIn`` otherwise.
nonisolated protocol MediaService: Sendable {
    // MARK: Connection & auth

    /// Validates the address and returns basic server info. Must be called before signing in.
    ///
    /// If `address` has no scheme, `https://` is tried first, then `http://`.
    /// - Throws: ``MediaServiceError`` describing why each attempted address failed.
    func connect(to address: String) async throws -> ServerInfo

    /// Signs in to the server from the last successful `connect(to:)`.
    /// - Throws: ``MediaServiceError/invalidCredentials`` for a wrong username or password.
    func signIn(username: String, password: String) async throws -> UserSession

    /// Starts a Quick Connect sign-in against the server from the last successful `connect(to:)`.
    ///
    /// Emits `.code` once, then `.signedIn` when the user approves the code from another signed-in
    /// client. Cancelling the consuming task stops polling.
    func quickConnect() -> AsyncThrowingStream<QuickConnectEvent, Error>

    /// Re-attaches a previously saved session (e.g. loaded from the keychain), so the browsing
    /// and playback methods work without signing in again.
    func restore(_ session: UserSession) async

    /// Revokes the session's access token on the server (best effort) and forgets it locally.
    func signOut() async

    /// Re-reads the signed-in user's profile (display name and profile picture) from the server,
    /// so changes made elsewhere show up without signing in again.
    ///
    /// Returns the updated session, which keeps the same access token.
    /// - Throws: ``MediaServiceError/notSignedIn`` if there's no session, or a network error.
    func refreshProfile() async throws -> UserSession

    // MARK: Browsing

    /// The user's top-level libraries.
    func libraries() async throws -> [Library]

    /// Everything in a library, sorted by name. Not paginated.
    func items(in library: Library) async throws -> [MediaItem]

    /// Partially watched movies and episodes ("Continue Watching").
    func resumeItems() async throws -> [MediaItem]

    /// The most recently added items in a library, a handful for a home-screen shelf.
    func latestItems(in library: Library) async throws -> [MediaItem]

    /// One page of everything in a library, newest first: episodes for a TV library, movies for a movie library.
    ///
    /// Page through it by passing the number of items already loaded as `offset`. A page shorter than
    /// `limit` is the last one.
    func recentlyAdded(in library: Library, offset: Int, limit: Int) async throws -> [MediaItem]

    /// Seasons of a series, or episodes of a season. Empty for anything else.
    func children(of item: MediaItem) async throws -> [MediaItem]

    /// Movies, series, and episodes matching `query`.
    func search(_ query: String) async throws -> [MediaItem]

    // MARK: Playback

    /// Asks the server how to play `item` on this device and returns a URL AVPlayer can load.
    /// - Throws: ``MediaServiceError/itemNotPlayable`` if the server offers no usable stream.
    func playbackInfo(for item: MediaItem) async throws -> PlaybackInfo

    /// Tells the server about playback progress so watch state and "Continue Watching" stay current.
    ///
    /// Best effort: failures are swallowed so they never interrupt playback.
    /// - Parameters:
    ///   - position: Current playback position in seconds.
    ///   - isPaused: Whether playback is currently paused.
    func report(_ event: PlaybackEvent, for item: MediaItem, info: PlaybackInfo, position: TimeInterval, isPaused: Bool) async
}
