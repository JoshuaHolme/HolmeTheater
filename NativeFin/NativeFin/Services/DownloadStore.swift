// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CryptoKit
import Foundation
import OSLog

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
}

/// Everything saved, as written to disk.
nonisolated struct DownloadIndex: Codable, Sendable {
    /// Downloads by item ID.
    var records: [String: DownloadRecord] = [:]

    /// The shows and seasons that downloaded episodes belong to, so they can be shown in their place.
    var containers: [String: MediaItem] = [:]

    /// What the server knew about each person in the downloaded cast, by person ID.
    var people: [String: PersonDetails] = [:]
}

/// Saves downloads to disk, and finds them again.
///
/// Layout, under Application Support (which the system never purges, unlike Caches):
/// - `index.json`: ``DownloadIndex``.
/// - `Items/<id>/`: an item's video file and subtitle files.
/// - `Artwork/<hash>`: images, named by a hash of the URL they came from, shared by everything that uses them.
///
/// Safe to use from any thread.
nonisolated final class DownloadStore: @unchecked Sendable {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NativeFin", category: "DownloadStore")

    let root: URL
    private let lock = NSLock()
    private var index = DownloadIndex()

    /// Whether the system keeps the downloads until they're deleted. False when they had to go in Caches, where the system
    /// may remove them if the device runs low on space.
    let isPermanent: Bool

    /// Where downloads go: Application Support, which the system never purges. Apple TV may not let apps write there; if it
    /// doesn't, they go in Caches instead, and ``isPermanent`` is false.
    private static func defaultRoot() -> (url: URL, isPermanent: Bool) {
        let support = URL.applicationSupportDirectory.appending(path: "Downloads", directoryHint: .isDirectory)
        #if os(tvOS)
        // Try it, rather than assume: a write that fails is the only reliable answer.
        let probe = support.appending(path: ".probe", directoryHint: .notDirectory)
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            try Data().write(to: probe)
            try FileManager.default.removeItem(at: probe)
        } catch {
            return (URL.cachesDirectory.appending(path: "Downloads", directoryHint: .isDirectory), false)
        }
        #endif
        return (support, true)
    }

    /// - Parameter root: Where to keep everything. Defaults to a folder in Application Support; previews and tests
    ///   give their own.
    init(root: URL? = nil) {
        let location = root.map { ($0, true) } ?? Self.defaultRoot()
        isPermanent = location.1
        var directory = location.0
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Downloads can be fetched again, so they don't belong in the user's iCloud backup.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        self.root = directory
        load()
    }

    // MARK: - Index

    private var indexURL: URL { root.appending(path: "index.json", directoryHint: .notDirectory) }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        do {
            index = try JSONDecoder().decode(DownloadIndex.self, from: data)
        } catch {
            Self.logger.error("Couldn't read the downloads index: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Writes the index. Call with the lock held.
    private func persist() {
        do {
            try JSONEncoder().encode(index).write(to: indexURL, options: .atomic)
        } catch {
            Self.logger.error("Couldn't save the downloads index: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Records

    var records: [DownloadRecord] { lock.withLock { Array(index.records.values) } }

    func record(id: String) -> DownloadRecord? { lock.withLock { index.records[id] } }

    /// Adds or replaces a record.
    func save(_ record: DownloadRecord) {
        lock.withLock {
            index.records[record.id] = record
            persist()
        }
    }

    /// Changes a record in place and returns it, or nil if there's no such record.
    ///
    /// - Parameter persist: Whether to write to disk. Progress changes many times a second, and only needs saving
    ///   when something more lasting happens.
    @discardableResult
    func update(_ id: String, persist shouldPersist: Bool = true, _ change: (inout DownloadRecord) -> Void) -> DownloadRecord? {
        lock.withLock {
            guard var record = index.records[id] else { return nil }
            change(&record)
            index.records[id] = record
            if shouldPersist { persist() }
            return record
        }
    }

    /// Deletes downloads, their files, and whatever nothing else needs any more.
    func remove(ids: [String]) {
        lock.withLock {
            for id in ids {
                index.records[id] = nil
                try? FileManager.default.removeItem(at: itemDirectory(for: id))
            }
            pruneUnreferenced()
            persist()
        }
    }

    /// Deletes everything.
    func removeAll() {
        lock.withLock {
            index = DownloadIndex()
            try? FileManager.default.removeItem(at: root.appending(path: "Items", directoryHint: .isDirectory))
            try? FileManager.default.removeItem(at: artworkDirectory)
            persist()
        }
    }

    /// Drops shows, seasons, people and artwork that no download uses. Call with the lock held.
    private func pruneUnreferenced() {
        let items = index.records.values.map(\.item)
        let seriesIDs = Set(items.compactMap(\.seriesID))
        let seasonIDs = Set(items.compactMap(\.seasonID))
        index.containers = index.containers.filter { seriesIDs.contains($0.key) || seasonIDs.contains($0.key) }

        let personIDs = Set(items.flatMap(\.people).map(\.personID))
        index.people = index.people.filter { personIDs.contains($0.key) }

        var keep = Set<String>()
        for item in items + Array(index.containers.values) {
            for url in Self.artworkURLs(of: item) { keep.insert(Self.artworkName(for: url)) }
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: artworkDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files where !keep.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Shows, seasons and people

    func container(id: String) -> MediaItem? { lock.withLock { index.containers[id] } }

    var containers: [MediaItem] { lock.withLock { Array(index.containers.values) } }

    func saveContainer(_ item: MediaItem) {
        lock.withLock {
            index.containers[item.id] = item
            persist()
        }
    }

    func personDetails(id: String) -> PersonDetails? { lock.withLock { index.people[id] } }

    func savePersonDetails(_ details: PersonDetails, id: String) {
        lock.withLock {
            index.people[id] = details
            persist()
        }
    }

    // MARK: - Files

    func itemDirectory(for id: String) -> URL {
        root.appending(path: "Items", directoryHint: .isDirectory).appending(path: id, directoryHint: .isDirectory)
    }

    /// The item's folder, created if it isn't there yet.
    func makeItemDirectory(for id: String) throws -> URL {
        let directory = itemDirectory(for: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private var artworkDirectory: URL { root.appending(path: "Artwork", directoryHint: .isDirectory) }

    private static func artworkName(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func artworkFile(for url: URL) -> URL {
        artworkDirectory.appending(path: Self.artworkName(for: url), directoryHint: .notDirectory)
    }

    func hasArtwork(for url: URL) -> Bool {
        FileManager.default.fileExists(atPath: artworkFile(for: url).path(percentEncoded: false))
    }

    func saveArtwork(_ data: Data, for url: URL) {
        try? FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        try? data.write(to: artworkFile(for: url), options: .atomic)
    }

    /// Every image an item shows.
    static func artworkURLs(of item: MediaItem) -> [URL] {
        let own = [item.posterURL, item.backdropURL, item.thumbnailURL, item.logoURL]
        let people = item.people.flatMap { [$0.imageURL, $0.largeImageURL] }
        let chapters = item.chapters.map(\.imageURL)
        return (own + people + chapters).compactMap { $0 }.filter { !$0.isFileURL }
    }

    /// The item with each image pointing at its saved copy, where there is one, so it shows without the server.
    func localized(_ item: MediaItem) -> MediaItem {
        func local(_ url: URL?) -> URL? {
            guard let url, !url.isFileURL, hasArtwork(for: url) else { return url }
            return artworkFile(for: url)
        }
        var item = item
        item.posterURL = local(item.posterURL)
        item.backdropURL = local(item.backdropURL)
        item.thumbnailURL = local(item.thumbnailURL)
        item.logoURL = local(item.logoURL)
        item.people = item.people.map { person in
            var person = person
            person.imageURL = local(person.imageURL)
            person.largeImageURL = local(person.largeImageURL)
            return person
        }
        item.chapters = item.chapters.map { chapter in
            var chapter = chapter
            chapter.imageURL = local(chapter.imageURL)
            return chapter
        }
        return item
    }

    // MARK: - Offline reading

    /// A completed download's item, with its saved artwork and the watch progress kept with it.
    func localItem(id: String) -> MediaItem? {
        guard let record = record(id: id), record.isComplete else { return nil }
        return localized(record.item)
    }

    /// A show or season that downloaded episodes belong to, or an episode or movie that's downloaded.
    func localAnyItem(id: String) -> MediaItem? {
        localItem(id: id) ?? container(id: id).map(localized)
    }

    /// How to play a completed download from its file, or nil if there isn't one.
    ///
    /// - Parameter resumeFrom: The item as the player knows it, for where to start.
    func localPlayback(for id: String, resumeFrom item: MediaItem) -> PlaybackInfo? {
        guard let record = record(id: id), record.isComplete, let name = record.videoFileName, var info = record.info else { return nil }
        let video = itemDirectory(for: id).appending(path: name, directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: video.path(percentEncoded: false)) else { return nil }

        info.url = video
        info.method = .directPlay
        info.resumePosition = (item.playedFraction ?? 0) * (item.runtime ?? record.item.runtime ?? 0)
        info.playSessionID = nil
        info.maxBitrate = nil
        info.subtitleTracks = info.subtitleTracks.map { track in
            var track = track
            track.url = record.subtitleFiles[track.index].map {
                itemDirectory(for: id).appending(path: $0, directoryHint: .notDirectory)
            }
            return track
        }
        return info
    }

    /// Remembers how far through a downloaded item the viewer got, so it resumes there and shows as watched even when
    /// the server can't be told.
    ///
    /// - Parameter persist: Whether to write to disk. Playback reports every few seconds; only its end needs saving.
    func updateProgress(id: String, position: TimeInterval, persist: Bool) {
        update(id, persist: persist) { record in
            guard let runtime = record.item.runtime, runtime > 0 else { return }
            let fraction = position / runtime
            // Past the credits it counts as finished, like the server's own rule of thumb.
            let isPlayed = fraction >= 0.9
            if isPlayed {
                record.item.isPlayed = true
                record.item.playedFraction = nil
            } else if position > 1 {
                record.item.playedFraction = fraction
            } else {
                record.item.playedFraction = nil
            }
            record.pendingProgress = PendingProgress(position: isPlayed ? 0 : position, isPlayed: isPlayed, date: .now)
        }
        if persist { onPendingProgress?() }
    }

    /// Called when progress is waiting to be sent to the server. Set once, by the download manager.
    var onPendingProgress: (@Sendable () -> Void)?

    /// Downloads with progress the server hasn't been told about.
    var recordsWithPendingProgress: [DownloadRecord] { records.filter { $0.pendingProgress != nil } }

    /// Forgets sent progress, unless more has been made since.
    func clearPendingProgress(id: String, ifStill sent: PendingProgress) {
        update(id) { if $0.pendingProgress == sent { $0.pendingProgress = nil } }
    }
}
