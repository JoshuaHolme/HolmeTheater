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

    /// Fetches one page of "Up Next": for each show the user has been watching, the next episode to watch.
    ///
    /// Episodes that are partly watched are left out, since they're in ``resumeItems(offset:limit:)``.
    ///
    /// - Parameters:
    ///   - offset: The number of items already loaded; 0 for the first page.
    ///   - limit: The maximum number of items to return.
    /// - Returns: Up to `limit` episodes, most recently watched show first. A page shorter than `limit` is the last one.
    func nextUpItems(offset: Int, limit: Int) async throws -> [MediaItem]

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

    /// Fetches one page of what's been released most recently in a library, newest release first, whenever it was added
    /// to the library. Nothing that hasn't come out yet.
    ///
    /// Like ``recentlyAddedPage(in:offset:limit:)``, this returns individual playable items: episodes for a TV library,
    /// movies for a movie library.
    ///
    /// - Parameters:
    ///   - library: The library to list.
    ///   - offset: The number of items already loaded; 0 for the first page.
    ///   - limit: The maximum number of items to return.
    /// - Returns: Up to `limit` items. A page shorter than `limit` is the last one.
    func recentlyReleasedPage(in library: Library, offset: Int, limit: Int) async throws -> [MediaItem]

    /// Fetches the movies and shows, in every library, that first came out on today's date in some year.
    ///
    /// - Returns: Everything with a premiere date on today's month and day, newest year first.
    func itemsOnThisDay() async throws -> [MediaItem]

    /// Fetches several items in one request, with only the details lists have (no cast, chapters or streams).
    ///
    /// - Parameter ids: The items' IDs.
    /// - Returns: The items the server found, in no particular order. Any it doesn't have are left out.
    func items(withIDs ids: [String]) async throws -> [MediaItem]

    /// Fetches one item afresh, e.g. to pick up its latest watch progress after playback.
    ///
    /// - Parameter id: The item's ID.
    /// - Throws: ``MediaServiceError/itemNotFound`` if the server has no such item.
    func item(id: String) async throws -> MediaItem

    /// Finds other movies or shows on the server that resemble one, by genre, cast, studio and so on.
    ///
    /// - Parameter item: A movie or series.
    /// - Returns: The closest matches, not including the item itself. Empty for any other kind of item, or if
    ///   the server finds nothing close.
    func similarItems(to item: MediaItem) async throws -> [MediaItem]

    /// Fetches the special features attached to a movie or show: behind the scenes, deleted scenes, interviews and
    /// so on, which the server finds from how they're named and filed.
    ///
    /// - Parameter item: A movie or series.
    /// - Returns: The extras, in the server's order. Empty if there are none.
    func specialFeatures(of item: MediaItem) async throws -> [MediaItem]

    /// Fetches the items inside a series or season.
    ///
    /// - Parameter item: A series or season.
    /// - Returns: A series' seasons, or a season's episodes in episode order. Empty for any other kind of item.
    func children(of item: MediaItem) async throws -> [MediaItem]

    /// Finds the movies and shows on the server that a person is credited on, e.g. an actor's other work.
    ///
    /// - Parameter personID: ``MediaPerson/personID``.
    /// - Returns: Movies and series (not episodes), sorted by name, each with what the person did on it. Only
    ///   what's on this server.
    func items(featuring personID: String) async throws -> [PersonCredit]

    /// Fetches what the server knows about a person: biography, birth and death dates, birthplace and a web link.
    ///
    /// - Parameter personID: ``MediaPerson/personID``.
    /// - Returns: The details. Every part of them can be missing, so check ``PersonDetails/isEmpty``.
    func details(ofPerson personID: String) async throws -> PersonDetails

    /// Fetches only how many seasons a show has, which is far lighter than fetching the whole show (its cast and
    /// streams) for a count.
    ///
    /// - Parameter id: The show's ID.
    /// - Returns: The season count, counting a Specials season, or `nil` if the server didn't say.
    func seasonCount(ofSeries id: String) async throws -> Int?

    /// Marks an item as a favorite, or takes it off the favorites.
    ///
    /// - Parameters:
    ///   - isFavorite: Whether it should be a favorite.
    ///   - itemID: The item's ID.
    func setFavorite(_ isFavorite: Bool, itemID: String) async throws

    /// Picks the episode a show's Play button starts: the next one to watch (resuming one that's partly
    /// watched), or the first episode of season 1 if the user hasn't started the show or has finished it.
    ///
    /// - Parameter series: A series.
    /// - Returns: The episode to play, or `nil` if the show has no episodes.
    func nextEpisode(in series: MediaItem) async throws -> MediaItem?

    /// Searches the user's movies, series, and episodes.
    ///
    /// - Parameter query: The text to search for.
    /// - Returns: Matching items, most relevant first.
    func search(_ query: String) async throws -> [MediaItem]

    /// Fetches the genres that movies and shows on the server are filed under.
    ///
    /// - Returns: The genres, sorted by name.
    func genres() async throws -> [Genre]

    /// Fetches the movies and series filed under a genre, sorted by name.
    ///
    /// - Parameter genre: The genre to list.
    /// - Returns: Its movies and series.
    func items(in genre: Genre) async throws -> [MediaItem]

    // MARK: Playback

    /// Asks the server how to play an item on this device.
    ///
    /// - Parameters:
    ///   - item: A movie or episode.
    ///   - options: The quality and tracks to ask for; pass empty options to let the server choose.
    /// - Returns: A stream URL AVPlayer can load, the tracks on offer, and the details needed to report
    ///   progress for it.
    /// - Throws: ``MediaServiceError/itemNotPlayable`` if the server offers no usable stream.
    func playbackInfo(for item: MediaItem, options: PlaybackOptions) async throws -> PlaybackInfo

    /// Asks the server for a single file that can be saved and played later without the server.
    ///
    /// Like ``playbackInfo(for:options:)``, but the URL is always one plain file URLSession can fetch: the original
    /// file if this device can play it, otherwise a progressive MP4 the server converts it to.
    ///
    /// - Parameter item: A movie or episode.
    /// - Returns: The file's URL, and the tracks it carries.
    func downloadInfo(for item: MediaItem) async throws -> PlaybackInfo

    /// The intro, credits and other stretches the server has marked in an item, so the player can offer to skip
    /// them. Empty if the server has none, or can't say: this is only a convenience, so it never throws.
    func segments(for item: MediaItem) async -> [MediaSegment]

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

    // MARK: Watch state

    /// Marks an item as watched. The server also clears its resume position, so it leaves "Continue Watching".
    ///
    /// For a series or season, the server marks every episode in it, stamping each with the current time as its
    /// watched date (overwriting real dates). A whole series marked watched has nothing left for "Up Next".
    ///
    /// - Parameter itemID: The ID of a movie, episode, season or series.
    func markWatched(itemID: String) async throws

    /// Marks an item as not watched, and clears its resume position.
    ///
    /// For a series or season, the server marks every episode in it, also resetting each one's play count and
    /// watched date, so this can't be undone. A whole series marked unwatched leaves "Up Next" until it's watched
    /// again.
    ///
    /// - Parameter itemID: The ID of a movie, episode, season or series.
    func markUnwatched(itemID: String) async throws

    /// Forgets how far through an item the user got, so it no longer appears in "Continue Watching".
    ///
    /// This doesn't change whether the item counts as watched.
    ///
    /// - Parameter item: A movie or episode.
    func removeFromContinueWatching(_ item: MediaItem) async throws

    /// Sends watch progress made while the server couldn't be reached, e.g. from a downloaded copy.
    ///
    /// If the server has a more recent watch of the item than `date`, it's left alone.
    ///
    /// - Parameters:
    ///   - itemID: The movie's or episode's ID.
    ///   - position: Where playback stopped, in seconds. Ignored if `isPlayed`.
    ///   - isPlayed: Whether the item was watched to the end.
    ///   - date: When it was watched.
    func syncProgress(itemID: String, position: TimeInterval, isPlayed: Bool, date: Date) async throws
}

extension MediaService {
    /// Services with no server of their own have nothing to send it to.
    func syncProgress(itemID: String, position: TimeInterval, isPlayed: Bool, date: Date) async throws {}

    /// Services with nothing better to offer download what they'd stream.
    func downloadInfo(for item: MediaItem) async throws -> PlaybackInfo {
        try await playbackInfo(for: item, options: PlaybackOptions())
    }
}
