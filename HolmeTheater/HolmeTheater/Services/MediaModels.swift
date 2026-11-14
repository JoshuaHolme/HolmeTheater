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

/// How a server's administrator has branded its sign-in page.
nonisolated struct ServerBranding: Hashable, Sendable {
    /// A notice to show people signing in, or nil if there isn't one.
    let loginDisclaimer: String?

    /// The server's splash screen picture, or nil if it doesn't have one turned on.
    let splashscreenURL: URL?
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

    /// Whether the user may create collections and change what's in them: an administrator, or someone the server has given
    /// that permission. `nil` until the server has said, as for sessions saved before this property existed.
    ///
    /// Optional with a default so those sessions still decode. Playlists need no permission.
    var canManageCollections: Bool? = nil
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

    /// What a library is to the user: a real library of media, or one of the server's collected views, which are listed
    /// after the libraries.
    nonisolated enum Role: Int, Hashable, Sendable {
        case library
        case collections
        case playlists
    }

    /// Whether this is a library, or the server's collections or playlists.
    var role: Role = .library
}

/// A genre such as "Comedy", as a way to browse movies and shows other than by library.
nonisolated struct Genre: Identifiable, Hashable, Sendable {
    /// The genre's unique ID on the server.
    let id: String

    /// The display name, e.g. "Sci-Fi".
    let name: String

    /// Artwork the server has for the genre, if any.
    let imageURL: URL?
}

/// Something browsable or playable: a movie, series, season, or episode.
nonisolated struct MediaItem: Identifiable, Hashable, Sendable, Codable {
    /// The kind of item.
    nonisolated enum Kind: Hashable, Sendable, Codable {
        /// A movie, which can be played.
        case movie
        /// A TV series, which contains seasons.
        case series
        /// A season of a series, which contains episodes.
        case season
        /// An episode of a series, which can be played.
        case episode
        /// A bonus video attached to a movie or show: behind the scenes, a deleted scene, an interview. It can
        /// be played.
        case extra
        /// A server collection (a "box set"): a group of movies or shows, such as a film series.
        case collection
        /// A playlist: an ordered list of movies and episodes that the user can edit and play through.
        case playlist
        /// Anything the app doesn't specifically handle (music, photos, …).
        case other
    }

    /// The item's unique ID on the server.
    let id: String

    /// The item's name: a movie or series title, a season name, or an episode title.
    let title: String

    /// The kind of item.
    let kind: Kind

    /// A synopsis, if the server has one.
    var overview: String?

    /// The production year.
    let year: Int?

    /// The total runtime, in seconds.
    let runtime: TimeInterval?

    /// Portrait poster artwork, ready to load.
    ///
    /// For an episode this is its show's poster, so it sits comfortably in a poster slot.
    /// An episode's own widescreen still is ``thumbnailURL``.
    var posterURL: URL?

    /// Widescreen background artwork, ready to load. Falls back to the parent's (e.g. the series') backdrop.
    var backdropURL: URL?

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

    /// For an extra: what kind it is, e.g. "Behind the Scenes". `nil` for anything else, or if the server doesn't say.
    var extraLabel: String? = nil

    /// For an episode: the day it first aired, a calendar date in UTC. `nil` for anything else, or if unknown.
    var airDate: Date? = nil

    /// The ID of the series an episode or season belongs to, or `nil` for anything else.
    var seriesID: String? = nil

    /// The ID of the season an episode belongs to, or `nil` for anything else.
    var seasonID: String? = nil

    /// For an episode: its season's poster, ready to load, if the server may have one. `nil` for anything else.
    var seasonPosterURL: URL? = nil

    /// For a show or season: how many episodes it has. `nil` for anything else, or if the server didn't say.
    var episodeCount: Int? = nil

    /// For a show: how many seasons it has, counting a Specials season. `nil` for anything else, or if the
    /// server didn't say.
    var seasonCount: Int? = nil

    /// For a show or season: how many of its episodes aren't watched. `nil` for anything else, or if the
    /// server didn't say.
    var unwatchedEpisodeCount: Int? = nil

    /// The item's logo (its title as artwork, on a transparent background), or `nil` if the server has none.
    var logoURL: URL? = nil

    /// The item's genres, e.g. "Drama" and "Comedy", in the order the server lists them.
    var genres: [String] = []

    /// For a show: the network it originally aired on, e.g. "HBO". For a movie: its first listed studio. `nil` if the
    /// server doesn't know.
    var network: String? = nil

    /// The content rating, e.g. "TV-MA" or "PG-13". `nil` if the server doesn't have one.
    var officialRating: String? = nil

    /// The audience score out of 10, or `nil` if the server has none.
    var communityRating: Double? = nil

    /// The critics' score as a percentage (0 to 100), or `nil` if the server has none.
    var criticRating: Double? = nil

    /// The picture and sound of the video file, e.g. "4K · Dolby Vision · Dolby Atmos 7.1". `nil` for anything
    /// without a file of its own (a show or season), or if the server doesn't say.
    var technicalLine: String? = nil

    /// A show's status as the server words it, e.g. "Continuing" or "Ended". `nil` if it doesn't say.
    var status: String? = nil

    /// The year a show's run ended. `nil` if it hasn't, or the server doesn't know.
    var endYear: Int? = nil

    /// A one-line promotional tagline, if the server has one.
    var tagline: String? = nil

    /// A link to the trailer on the web (usually YouTube), if the server has one.
    var trailerURL: URL? = nil

    /// Whether the user has marked the item as a favorite.
    var isFavorite = false

    /// The cast and crew, in the server's order. Only filled in when a single item is fetched, not in lists.
    var people: [MediaPerson] = []

    /// The chapters, in order. Only filled in when a single item is fetched, not in lists.
    var chapters: [MediaChapter] = []

    /// When the item was added to the server's library. `nil` if the server doesn't say.
    var dateAdded: Date? = nil

    /// The day the movie or show was first released or aired. `nil` if the server doesn't say.
    var releaseDate: Date? = nil

    /// The name the server sorts the item by, e.g. "Godfather, The" or a name set by hand. `nil` if it doesn't say.
    var sortName: String? = nil

    /// When the user last played the item, or nil if they never have.
    var lastPlayedDate: Date? = nil

    /// For an item listed in a playlist: this entry's ID in the playlist, which is what removing it needs. The same item can
    /// be in a playlist more than once, so this differs from ``id``. `nil` for anything not fetched as part of a playlist.
    var playlistEntryID: String? = nil
}

/// A chapter of a movie or episode, as the server lists it.
nonisolated struct MediaChapter: Hashable, Sendable, Codable {
    /// The chapter's name.
    let name: String

    /// Where it starts, in seconds.
    let start: TimeInterval

    /// A still from the chapter, ready to load, or `nil` if the server has none.
    var imageURL: URL?
}

/// What the server knows about a person beyond their name and photo. Any of it can be missing, depending on what
/// the server's metadata provider found.
nonisolated struct PersonDetails: Hashable, Sendable, Codable {
    /// A biography.
    var biography: String?

    /// Date of birth. A calendar date in UTC, so read it as one.
    var birthDate: Date?

    /// Date of death, for someone who has died.
    var deathDate: Date?

    /// Where they were born, e.g. "Los Angeles, California, USA".
    var birthplace: String?

    /// Their page on IMDb or TMDb.
    var webpage: URL?

    /// Whether there's nothing to show.
    var isEmpty: Bool {
        biography == nil && birthDate == nil && deathDate == nil && birthplace == nil && webpage == nil
    }
}

/// A movie or show that a person is credited on, with what they did on it.
nonisolated struct PersonCredit: Identifiable, Hashable, Sendable {
    /// The movie or series.
    let item: MediaItem

    /// What the person did on it: usually one entry, more if they had several jobs (e.g. director and writer).
    let roles: [MediaPerson]

    var id: String { item.id }
}

/// A member of an item's cast or crew.
nonisolated struct MediaPerson: Identifiable, Hashable, Sendable, Codable {
    /// What the person did on the item.
    nonisolated enum Role: Hashable, Sendable, Codable {
        case actor, director, writer, producer, creator, composer
    }

    /// The person's ID on the server.
    let personID: String

    /// What they did.
    let role: Role

    /// Their name.
    let name: String

    /// The character an actor played. `nil` for crew, or if the server doesn't say.
    let character: String?

    /// A portrait, ready to load, or `nil` if the server has none.
    var imageURL: URL?

    /// A larger copy of the portrait, for showing full screen. `nil` if the server has no portrait.
    var largeImageURL: URL?

    /// A person can appear once per role, e.g. as both director and writer.
    var id: String { "\(personID)-\(role)" }
}

/// How the server is delivering a video stream.
nonisolated enum PlaybackMethod: Sendable, Codable {
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
nonisolated struct PlaybackInfo: Hashable, Sendable, Codable {
    /// A URL AVPlayer can load directly. The access token is embedded in its query, because AVPlayer has no way to send
    /// it in a header with every HLS request, but it's left out whenever the info is encoded (see ``encode(to:)``).
    var url: URL

    /// Where to start playing, in seconds.
    var resumePosition: TimeInterval

    /// The server's ID for this playback, echoed back in progress reports.
    var playSessionID: String?

    /// The ID of the version of the item being played (an item can have several, e.g. 4K and HD).
    let mediaSourceID: String?

    /// How the server is delivering the stream.
    var method: PlaybackMethod

    /// The audio tracks in the file, whichever one this stream carries.
    var audioTracks: [MediaTrack] = []

    /// The subtitle tracks in the file, whichever one this stream carries.
    var subtitleTracks: [MediaTrack] = []

    /// The ``MediaTrack/index`` of the audio track this stream plays.
    var audioIndex: Int?

    /// The ``MediaTrack/index`` of the subtitle track this stream carries, or nil for none.
    var subtitleIndex: Int?

    /// Whether the server has drawn the subtitles into the picture, so the player can't hide them.
    var subtitlesBurnedIn = false

    /// The original file's bitrate in bits per second, if known: the most any stream of it can need.
    var sourceBitrate: Int?

    /// The original file's picture height in pixels, if known.
    var sourceHeight: Int?

    /// The bitrate cap this stream was requested with, or nil for none.
    var maxBitrate: Int?

    /// How many bytes the file is expected to be, for showing a download's progress when the server doesn't say how big
    /// the transfer is. The original file's size, or a guess for one the server converts as it sends. Nil if unknown.
    var expectedBytes: Int64?
}

extension PlaybackInfo {
    /// Encodes the info with the access token taken out of ``url``, so whatever saves it (a download's record, say) can
    /// never write the token to disk. Decoding is the synthesized one, and the keys are the same, so saved data reads as
    /// before.
    ///
    /// Written out because a property wrapper can't do it in a `nonisolated` struct. A new property has to be added here
    /// too, or it won't be saved.
    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(url.removingAccessToken(), forKey: .url)
        try container.encode(resumePosition, forKey: .resumePosition)
        try container.encodeIfPresent(playSessionID, forKey: .playSessionID)
        try container.encodeIfPresent(mediaSourceID, forKey: .mediaSourceID)
        try container.encode(method, forKey: .method)
        try container.encode(audioTracks, forKey: .audioTracks)
        try container.encode(subtitleTracks, forKey: .subtitleTracks)
        try container.encodeIfPresent(audioIndex, forKey: .audioIndex)
        try container.encodeIfPresent(subtitleIndex, forKey: .subtitleIndex)
        try container.encode(subtitlesBurnedIn, forKey: .subtitlesBurnedIn)
        try container.encodeIfPresent(sourceBitrate, forKey: .sourceBitrate)
        try container.encodeIfPresent(sourceHeight, forKey: .sourceHeight)
        try container.encodeIfPresent(maxBitrate, forKey: .maxBitrate)
        try container.encodeIfPresent(expectedBytes, forKey: .expectedBytes)
    }
}

/// A stretch of a movie or episode the server knows the purpose of, which the player offers to skip.
nonisolated struct MediaSegment: Hashable, Sendable, Codable {
    nonisolated enum Kind: Hashable, Sendable, Codable {
        case intro, outro, recap, preview, commercial
        /// Something the server found but couldn't name.
        case unknown
    }

    let kind: Kind

    /// Where it starts and ends, in seconds.
    let start: TimeInterval
    let end: TimeInterval
}

/// One audio or subtitle track in a video file.
nonisolated struct MediaTrack: Identifiable, Hashable, Sendable, Codable {
    /// The server's number for the track within its file, which playback requests refer to.
    let index: Int

    /// A name for menus, e.g. "English - Dolby Digital - 5.1".
    let title: String

    /// Whether the track is in a separate file next to the video rather than inside it.
    let isExternal: Bool

    /// For a subtitle track the app can draw itself: where to fetch it, in ``format``. `nil` for anything else, such as
    /// picture-based subtitles other than PGS, which only the server can draw (by burning them into the video).
    var url: URL? = nil

    /// What ``url`` holds. Nil means WebVTT, as for every track saved before this was kept.
    var format: SubtitleFormat? = nil

    /// For a subtitle track: whether it only has the lines that aren't understood otherwise, e.g. foreign speech. Nil
    /// when unknown, as for tracks saved before this was kept.
    var isForced: Bool? = nil

    /// Whether this is a forced track, going by the server's flag or, since not every file sets it, the name.
    var looksForced: Bool {
        isForced == true || title.localizedCaseInsensitiveContains("forced")
    }

    var id: Int { index }
}

/// The kinds of subtitle file the app draws itself.
nonisolated enum SubtitleFormat: String, Hashable, Sendable, Codable {
    /// Text, which the server converts most text tracks to.
    case webVTT
    /// SubStation Alpha text (`.ass` or `.ssa`), as it is: converted, it would lose where its lines go.
    case ass
    /// Pictures, as on Blu-ray discs (a `.sup` file), sent as they are: the server can't turn them into text.
    case pgs
}

/// What to ask the server for when (re)starting a stream. Nil fields leave the choice to the server.
nonisolated struct PlaybackOptions: Hashable, Sendable {
    /// The version of the item to play (an item can have several, e.g. 4K and HD).
    var mediaSourceID: String?

    /// The most bits per second the stream may use, or nil for the best the source allows.
    var maxBitrate: Int?

    /// The ``MediaTrack/index`` of the audio track to play.
    var audioIndex: Int?

    /// The ``MediaTrack/index`` of the subtitle track to show, or ``PlaybackOptions/noSubtitles``.
    var subtitleIndex: Int?

    /// The `subtitleIndex` that asks for no subtitles at all.
    static let noSubtitles = -1
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

    /// This service can't make or change playlists.
    case playlistsNotSupported

    /// This service can't make or change collections.
    case collectionsNotSupported

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
        case .playlistsNotSupported: String(localized: "Playlists can't be changed right now.")
        case .collectionsNotSupported: String(localized: "Collections can't be changed right now.")
        case .underlying(let message): message
        }
    }
}
