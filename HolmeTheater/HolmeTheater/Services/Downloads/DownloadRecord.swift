// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Where a download is in its life.
nonisolated enum DownloadState: String, Codable, Sendable {
    /// Waiting for its turn.
    case queued
    /// Saving the item's details, cast and artwork, and asking the server for the file.
    case preparing
    /// The file is on its way.
    case downloading
    /// Stopped by the user, to be resumed.
    case paused
    /// Stopped by an error; ``DownloadRecord/errorMessage`` says which.
    case failed
    /// The file and everything that goes with it are saved.
    case completed

    /// Whether the download is downloading or waiting to: queued, preparing or downloading.
    var isInProgress: Bool { self == .queued || self == .preparing || self == .downloading }

    /// Whether the download has stopped short of finishing: paused by the user, or failed.
    var isStalled: Bool { self == .paused || self == .failed }
}

/// Watch progress made on the device that the server hasn't been told about yet.
nonisolated struct PendingProgress: Codable, Hashable, Sendable {
    /// Where playback stopped, in seconds.
    var position: TimeInterval

    /// Whether it was watched to the end.
    var isPlayed: Bool

    /// When it was watched, so a newer watch on another device isn't overwritten.
    var date: Date
}

/// One movie or episode that's been, or is being, saved for offline viewing, with everything the app needs to show
/// and play it without the server.
nonisolated struct DownloadRecord: Identifiable, Codable, Hashable, Sendable {
    /// The movie's or episode's own item, including its description, cast and chapters.
    var item: MediaItem

    /// The account and server it was downloaded for (``AppModel/cacheScope``).
    var scope: String

    var state: DownloadState

    /// How much of the file has arrived, and how big it is. The size is 0 until the server says (a converted
    /// file has no size until it's finished).
    var bytesWritten: Int64 = 0
    var bytesExpected: Int64 = 0

    /// Whether ``bytesExpected`` is the server's own figure for the file rather than a guess. Servers often don't say how
    /// big a transfer is, so until one does, the size is estimated from what's known about the movie.
    var isSizeEstimated = false

    /// The video file's name within the item's folder, once it's saved.
    var videoFileName: String?

    /// The tracks in the file. Its URL is a placeholder: the real one holds the access token, which isn't kept.
    var info: PlaybackInfo?

    /// For each text subtitle track (by ``MediaTrack/index``), the name of its saved file.
    var subtitleFiles: [Int: String] = [:]

    /// The intro, credits and so on the server marked, so the player can still offer to skip them.
    var segments: [MediaSegment] = []

    /// What went wrong, for a ``DownloadState/failed`` download.
    var errorMessage: String?

    var dateAdded: Date = .now

    /// Progress made here that's waiting to be sent to the server. Nil once it has been.
    var pendingProgress: PendingProgress?

    /// The size of the saved file in bytes. 0 until it's saved.
    var fileSize: Int64 = 0

    var id: String { item.id }

    /// How much of the file has arrived, from 0 to 1.
    var progress: Double {
        guard bytesExpected > 0 else { return 0 }
        let fraction = Double(bytesWritten) / Double(bytesExpected)
        // A guess can be too small, but it shouldn't claim to be done before the file is.
        return isSizeEstimated && !isComplete ? min(0.99, fraction) : min(1, fraction)
    }

    var isComplete: Bool { state == .completed }

    /// What a row says beneath an unfinished download: how far along it is, or why it stopped. Empty once it's done.
    var statusDescription: String {
        switch state {
        case .queued: String(localized: "Waiting…")
        case .preparing: String(localized: "Preparing…")
        case .downloading:
            if bytesExpected > 0 {
                String(localized: "\(bytesWritten.formatted(.byteCount(style: .file))) of \(isSizeEstimated ? "about " : "")\(bytesExpected.formatted(.byteCount(style: .file)))")
            } else {
                bytesWritten.formatted(.byteCount(style: .file))
            }
        case .paused: String(localized: "Paused")
        case .failed: errorMessage ?? String(localized: "Failed")
        case .completed: ""
        }
    }

    /// Season by season, episode by episode.
    static func episodeOrder(_ a: DownloadRecord, _ b: DownloadRecord) -> Bool {
        let (sa, sb) = (a.item.seasonNumber ?? 0, b.item.seasonNumber ?? 0)
        if sa != sb { return sa < sb }
        return (a.item.episodeNumber ?? 0) < (b.item.episodeNumber ?? 0)
    }
}

/// Everything saved, as written to disk.
nonisolated struct DownloadIndex: Codable, Sendable {
    /// Downloads by ``DownloadStore/key(scope:id:)``. Two accounts on one server see the same item IDs, so the account
    /// is part of the key.
    var records: [String: DownloadRecord] = [:]

    /// The shows and seasons that downloaded episodes belong to, so they can be shown in their place.
    var containers: [String: MediaItem] = [:]

    /// What the server knew about each person in the downloaded cast, by person ID.
    var people: [String: PersonDetails] = [:]
}
