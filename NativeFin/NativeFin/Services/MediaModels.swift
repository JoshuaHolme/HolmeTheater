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
    /// The server's unique ID (empty if the server didn't report one).
    let id: String
    /// The server's display name, as configured by its administrator.
    let name: String
    /// The base URL the server was reached at, including scheme and port.
    let url: URL
}

/// A signed-in user on a particular server. This is what gets persisted in the keychain.
nonisolated struct UserSession: Codable, Hashable, Sendable {
    let server: ServerInfo
    let userID: String
    let username: String
    /// The Jellyfin access token. Treat as a secret.
    let accessToken: String
    /// The user's profile picture, or nil if they haven't set one.
    ///
    /// Optional with a default so sessions saved before this field existed still decode.
    var avatarURL: URL? = nil
}

/// Progress of a Quick Connect sign-in. See ``MediaService/quickConnect()``.
nonisolated enum QuickConnectEvent: Sendable {
    /// Show this code to the user so they can approve this device from another signed-in Jellyfin client.
    case code(String)
    /// The code was approved and sign-in finished.
    case signedIn(UserSession)
}

/// A top-level collection on the server, such as "Movies" or "TV Shows".
nonisolated struct Library: Identifiable, Hashable, Sendable {
    nonisolated enum Kind: Hashable, Sendable {
        case movies, tvShows, music, other
    }

    let id: String
    let name: String
    let kind: Kind
}

/// Something browsable or playable: a movie, series, season, or episode.
nonisolated struct MediaItem: Identifiable, Hashable, Sendable {
    nonisolated enum Kind: Hashable, Sendable {
        case movie, series, season, episode
        /// Anything the app doesn't specifically handle (music, photos, collections, …).
        case other
    }

    let id: String
    let title: String
    let kind: Kind
    let overview: String?
    /// Production year.
    let year: Int?
    /// Total runtime in seconds.
    let runtime: TimeInterval?
    /// Ready-to-load artwork URLs, resolved against the server by the service.
    let posterURL: URL?
    let backdropURL: URL?
    /// 0...1 for partially watched items, nil otherwise.
    let playedFraction: Double?
    /// Whether the user has finished watching this item.
    let isPlayed: Bool

    // Episode context (nil for everything else)

    let seriesTitle: String?
    let seasonNumber: Int?
    let episodeNumber: Int?
}

/// How the server is delivering a video stream.
nonisolated enum PlaybackMethod: Sendable {
    /// The original file, untouched.
    case directPlay
    /// The original video/audio streams, repackaged into a different container (e.g. HLS).
    case directStream
    /// Re-encoded by the server.
    case transcode
}

/// Everything the player needs to start an item, and everything the service needs back
/// to report progress for it.
nonisolated struct PlaybackInfo: Hashable, Sendable {
    /// A URL AVPlayer can load directly. Authentication is embedded in the URL.
    let url: URL
    /// Where to start, in seconds.
    let resumePosition: TimeInterval
    /// Echoed back in progress reports so the server can track the session.
    let playSessionID: String?
    let mediaSourceID: String?
    let method: PlaybackMethod
}

/// A stage of playback to report to the server.
nonisolated enum PlaybackEvent: Sendable {
    case started
    case progress
    case stopped
}

/// Errors surfaced by a `MediaService`. Each case has a user-presentable description.
nonisolated enum MediaServiceError: LocalizedError, Sendable {
    case invalidServerURL
    case serverUnreachable
    case invalidCredentials
    case notSignedIn
    case itemNotPlayable
    /// Anything else; the associated value is already user-presentable.
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL: "That doesn't look like a valid server address."
        case .serverUnreachable: "Couldn't reach the server."
        case .invalidCredentials: "Incorrect username or password."
        case .notSignedIn: "You're not signed in."
        case .itemNotPlayable: "This item can't be played."
        case .underlying(let message): message
        }
    }
}
