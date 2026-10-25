// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// The only surface the UI talks to for anything involving a Jellyfin server.
///
/// ``JellyfinMediaService`` is the real implementation, wrapping the Jellyfin SDK.
/// ``MockMediaService`` returns canned data so views can be built and previewed without a server.
///
/// Implementations are stateful: ``connect(to:)`` and a sign-in must succeed before the browsing
/// and playback methods work, and they throw ``MediaServiceError/notSignedIn`` otherwise.
nonisolated protocol MediaService: Sendable {
    // MARK: Connection & auth

    /// Checks that an address is a reachable Jellyfin server, and makes it the server to sign in to.
    ///
    /// If `address` has no scheme, `https://` is tried first, then `http://`.
    ///
    /// - Parameter address: The server address as the user typed it, e.g. `jellyfin.local:8096`.
    /// - Returns: The server's name and the URL it was reached at.
    /// - Throws: ``MediaServiceError`` describing why each attempted address failed.
    func connect(to address: String) async throws -> ServerInfo

    /// Signs in to the server from the last successful ``connect(to:)``.
    ///
    /// - Parameters:
    ///   - username: The Jellyfin username.
    ///   - password: The user's password, which may be empty.
    /// - Returns: The new session.
    /// - Throws: ``MediaServiceError/invalidCredentials`` for a wrong username or password, or another
    ///   ``MediaServiceError`` if the server can't be reached.
    func signIn(username: String, password: String) async throws -> UserSession

    /// Starts a Quick Connect sign-in against the server from the last successful ``connect(to:)``.
    ///
    /// The stream emits ``QuickConnectEvent/code(_:)`` once, then ``QuickConnectEvent/signedIn(_:)`` when the
    /// user approves the code from another signed-in client, and then finishes. Cancelling the consuming task
    /// stops polling.
    ///
    /// - Returns: A stream of the flow's progress, which throws if Quick Connect fails or is unavailable.
    func quickConnect() -> AsyncThrowingStream<QuickConnectEvent, Error>

    /// Re-attaches a previously saved session, so the browsing and playback methods work without
    /// signing in again.
    ///
    /// - Parameter session: A session saved from an earlier sign-in, e.g. loaded from the keychain.
    func restore(_ session: UserSession) async

    /// Revokes the session's access token on the server (best effort) and forgets it locally.
    func signOut() async

    /// Re-reads the signed-in user's profile (display name and profile picture) from the server,
    /// so changes made elsewhere show up without signing in again.
    ///
    /// - Returns: The updated session, which keeps the same access token.
    /// - Throws: ``MediaServiceError/sessionExpired`` if the server rejects the token,
    ///   ``MediaServiceError/notSignedIn`` if there's no session, or another ``MediaServiceError``
    ///   if the server can't be reached.
    func refreshProfile() async throws -> UserSession

    // MARK: Browsing

    /// Fetches the user's top-level libraries.
    ///
    /// - Returns: The libraries, in the order the server lists them.
    func libraries() async throws -> [Library]

    /// Fetches everything in a library, sorted by name.
    ///
    /// Movie libraries list their movies and TV libraries list their series. This isn't paginated.
    ///
    /// - Parameter library: The library to list.
    /// - Returns: The library's items.
    func items(in library: Library) async throws -> [MediaItem]

    /// Fetches one page of partially watched movies and episodes ("Continue Watching"), most recently
    /// watched first.
    ///
    /// - Parameters:
    ///   - offset: The number of items already loaded; 0 for the first page.
    ///   - limit: The maximum number of items to return.
    /// - Returns: Up to `limit` items. A page shorter than `limit` is the last one.
    func resumeItems(offset: Int, limit: Int) async throws -> [MediaItem]

    /// Fetches a handful of the most recently added items in a library, for a home-screen shelf.
    ///
    /// - Parameter library: The library to look in.
    /// - Returns: The newest items. A TV library may group several new episodes under their series.
    func recentlyAddedItems(in library: Library) async throws -> [MediaItem]

    /// Fetches one page of everything in a library, newest first.
    ///
    /// Unlike ``recentlyAddedItems(in:)``, this returns individual playable items: episodes for a TV library,
    /// movies for a movie library.
    ///
    /// - Parameters:
    ///   - library: The library to list.
    ///   - offset: The number of items already loaded; 0 for the first page.
    ///   - limit: The maximum number of items to return.
    /// - Returns: Up to `limit` items. A page shorter than `limit` is the last one.
    func recentlyAddedPage(in library: Library, offset: Int, limit: Int) async throws -> [MediaItem]

    /// Fetches the items inside a series or season.
    ///
    /// - Parameter item: A series or season.
    /// - Returns: A series' seasons, or a season's episodes in episode order. Empty for any other kind of item.
    func children(of item: MediaItem) async throws -> [MediaItem]

    /// Searches the user's movies, series, and episodes.
    ///
    /// - Parameter query: The text to search for.
    /// - Returns: Matching items, most relevant first.
    func search(_ query: String) async throws -> [MediaItem]

    // MARK: Playback

    /// Asks the server how to play an item on this device.
    ///
    /// - Parameter item: A movie or episode.
    /// - Returns: A stream URL AVPlayer can load, and the details needed to report progress for it.
    /// - Throws: ``MediaServiceError/itemNotPlayable`` if the server offers no usable stream.
    func playbackInfo(for item: MediaItem) async throws -> PlaybackInfo

    /// Tells the server about playback progress, so watch state and "Continue Watching" stay current.
    ///
    /// This is best effort: failures are swallowed so they never interrupt playback.
    ///
    /// - Parameters:
    ///   - event: Which stage of playback this is.
    ///   - item: The item being played.
    ///   - info: The playback info returned by ``playbackInfo(for:)`` for this playback.
    ///   - position: The current playback position, in seconds.
    ///   - isPaused: Whether playback is currently paused.
    func report(_ event: PlaybackEvent, for item: MediaItem, info: PlaybackInfo, position: TimeInterval, isPaused: Bool) async
}
