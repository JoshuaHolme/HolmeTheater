// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// Plain value types shared between the UI and whichever `MediaService` is in use.
// They deliberately don't expose any Jellyfin SDK types, so views never depend on the SDK.
//
// They are marked `nonisolated` so they can cross actor boundaries freely,
// since the module defaults to MainActor isolation.

/// A Jellyfin server the app has successfully connected to.
nonisolated struct ServerInfo: Codable, Hashable, Sendable {
    /// The server's unique ID, or an empty string if the server didn't report one.
    let id: String

    /// The server's display name, as configured by its administrator.
    let name: String

    /// The base URL the server was reached at, including scheme and port.
    let url: URL
}

/// A signed-in user on a particular server.
///
/// This is what's saved in the keychain, so the app is still signed in at the next launch.
/// Printing a session redacts its access token.
nonisolated struct UserSession: Codable, Hashable, Sendable {
    /// The server the user is signed in to.
    let server: ServerInfo

    /// The user's unique ID on the server.
    let userID: String

    /// The user's display name.
    let username: String

    /// The Jellyfin access token that authorizes every request. Treat as a secret.
    let accessToken: String

    /// The user's profile picture, or `nil` if they haven't set one.
    ///
    /// Optional with a default so sessions saved before this property existed still decode.
    var avatarURL: URL? = nil
}

// Keep the access token out of logs and debugger output: printing a session shows everything but the token.
extension UserSession: CustomStringConvertible, CustomDebugStringConvertible {
    /// A textual description of the session, with the access token redacted.
    var description: String {
        "UserSession(user: \(username) [\(userID)], server: \(server.url.absoluteString), accessToken: <redacted>)"
    }

    /// The same as ``description``, so the debugger never shows the access token either.
    var debugDescription: String { description }
}

/// A step in a Quick Connect sign-in. See ``MediaService/quickConnect()``.
nonisolated enum QuickConnectEvent: Sendable {
    /// A code to show the user, so they can approve this device from another signed-in Jellyfin client.
    case code(String)

    /// The code was approved, and sign-in finished with this session.
    case signedIn(UserSession)
}

/// A top-level collection on the server, such as "Movies" or "TV Shows".
nonisolated struct Library: Identifiable, Hashable, Sendable {
    /// The kind of content a library holds.
    nonisolated enum Kind: Hashable, Sendable {
        /// A library of movies.
        case movies
        /// A library of TV series.
        case tvShows
        /// A library of music.
        case music
        /// Any other kind of library, such as photos or home videos.
        case other
    }

    /// The library's unique ID on the server.
    let id: String

    /// The library's display name.
    let name: String

    /// The kind of content the library holds.
    let kind: Kind
}

/// Something browsable or playable: a movie, series, season, or episode.
nonisolated struct MediaItem: Identifiable, Hashable, Sendable {
    /// The kind of item.
    nonisolated enum Kind: Hashable, Sendable {
        /// A movie, which can be played.
        case movie
        /// A TV series, which contains seasons.
        case series
        /// A season of a series, which contains episodes.
        case season
        /// An episode of a series, which can be played.
        case episode
        /// Anything the app doesn't specifically handle (music, photos, collections, …).
        case other
    }

    /// The item's unique ID on the server.
    let id: String

    /// The item's name: a movie or series title, a season name, or an episode title.
    let title: String

    /// The kind of item.
    let kind: Kind

    /// A synopsis, if the server has one.
    let overview: String?

    /// The production year.
    let year: Int?

    /// The total runtime, in seconds.
    let runtime: TimeInterval?

    /// Portrait poster artwork, ready to load.
    ///
    /// For an episode this is its show's poster, so it sits comfortably in a poster slot.
    /// An episode's own widescreen still is ``thumbnailURL``.
    let posterURL: URL?

    /// Widescreen background artwork, ready to load. Falls back to the parent's (e.g. the series') backdrop.
    let backdropURL: URL?

    /// Widescreen artwork for list rows: an episode's own still, or a movie's thumb image (falling back to its
    /// backdrop). `nil` for anything else, or a movie with neither.
    var thumbnailURL: URL? = nil

    /// How much of the item has been watched, from 0 to 1, or `nil` if it hasn't been started.
    var playedFraction: Double?

    /// Whether the user has finished watching the item.
    var isPlayed: Bool

    /// The title of the series an episode or season belongs to.
    let seriesTitle: String?

    /// An episode's season number.
    let seasonNumber: Int?

    /// An episode's number within its season.
    let episodeNumber: Int?

    /// The ID of the series an episode or season belongs to, or `nil` for anything else.
    var seriesID: String? = nil

    /// For a show or season: how many episodes it has. `nil` for anything else, or if the server didn't say.
    var episodeCount: Int? = nil

    /// For a show or season: how many of its episodes aren't watched. `nil` for anything else, or if the
    /// server didn't say.
    var unwatchedEpisodeCount: Int? = nil
}

/// How the server is delivering a video stream.
nonisolated enum PlaybackMethod: Sendable {
    /// The original file, untouched.
    case directPlay

    /// The original video and audio streams, repackaged into a different container (e.g. HLS).
    case directStream

    /// Re-encoded by the server.
    case transcode
}

/// Everything the player needs to start an item, and everything the service needs back to report
/// progress for it.
///
/// Printing playback info redacts its URL, which contains the access token.
nonisolated struct PlaybackInfo: Hashable, Sendable {
    /// A URL AVPlayer can load directly. The access token is embedded in its query.
    let url: URL

    /// Where to start playing, in seconds.
    let resumePosition: TimeInterval

    /// The server's ID for this playback, echoed back in progress reports.
    let playSessionID: String?

    /// The ID of the version of the item being played (an item can have several, e.g. 4K and HD).
    let mediaSourceID: String?

    /// How the server is delivering the stream.
    let method: PlaybackMethod
}

// `url` carries the access token in its query, so printing playback info omits it.
extension PlaybackInfo: CustomStringConvertible, CustomDebugStringConvertible {
    /// A textual description of the playback info, with the stream URL redacted.
    var description: String {
        "PlaybackInfo(method: \(method), host: \(url.host() ?? "?"), resumePosition: \(resumePosition), url: <redacted>)"
    }

    /// The same as ``description``, so the debugger never shows the access token either.
    var debugDescription: String { description }
}

/// A stage of playback to report to the server.
nonisolated enum PlaybackEvent: Sendable {
    /// Playback began.
    case started

    /// Playback is ongoing; sent periodically with the current position.
    case progress

    /// Playback ended or the player was closed.
    case stopped
}

/// The errors a ``MediaService`` throws. Each has a description that can be shown to the user.
nonisolated enum MediaServiceError: LocalizedError, Sendable {
    /// The address couldn't be turned into a URL.
    case invalidServerURL

    /// The server couldn't be reached.
    case serverUnreachable

    /// The username or password was wrong.
    case invalidCredentials

    /// There's no session to make the request with.
    case notSignedIn

    /// The server rejected the saved access token (it expired, or was revoked from the server's dashboard).
    case sessionExpired

    /// The server offered no stream this device can play.
    case itemNotPlayable

    /// The item doesn't exist on the server (any more), or the user can't see it.
    case itemNotFound

    /// Anything else; the associated message is already user-presentable.
    case underlying(String)

    /// A localized message describing what went wrong.
    var errorDescription: String? {
        switch self {
        case .invalidServerURL: String(localized: "That doesn't look like a valid server address.")
        case .serverUnreachable: String(localized: "Couldn't reach the server.")
        case .invalidCredentials: String(localized: "Incorrect username or password.")
        case .notSignedIn: String(localized: "You're not signed in.")
        case .sessionExpired: String(localized: "Your session has expired. Sign in again.")
        case .itemNotPlayable: String(localized: "This item can't be played.")
        case .itemNotFound: String(localized: "This item is no longer available.")
        case .underlying(let message): message
        }
    }
}
