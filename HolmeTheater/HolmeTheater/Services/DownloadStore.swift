// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CryptoKit
import Foundation
import OSLog
import Synchronization

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
    /// Downloads by ``DownloadStore/key(scope:id:)``. Two accounts on one server see the same item IDs, so the account
    /// is part of the key.
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
/// - `Items/<account hash>/<id>/`: an item's video file and subtitle files.
/// - `Artwork/<hash>`: images, named by a hash of the URL they came from, shared by everything that uses them.
///
/// Everything read by item ID (``records``, ``record(id:)``, ``update(_:persist:_:)`` and the rest) is the signed-in
/// account's, set in ``scope``. The background session's callbacks can arrive after the account has changed, so they use
/// the methods that take a ``key(scope:id:)`` instead.
///
/// Safe to use from any thread.
nonisolated final class DownloadStore: Sendable {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "HolmeTheater", category: "DownloadStore")

    /// Everything that changes, behind one lock.
    private struct State {
        var index = DownloadIndex()

        /// See ``DownloadStore/scope``.
        var scope = ""

        /// The names of the files in `Artwork/`, so whether an image is saved can be answered without going to the disk.
        /// Rows ask for every image each time they're drawn.
        var artwork: Set<String> = []

        var onPendingProgress: (@Sendable () -> Void)?
    }

    let root: URL

    /// Whether the system keeps the downloads until they're deleted. False when they had to go in Caches, where the system
    /// may remove them if the device runs low on space.
    let isPermanent: Bool

    private let state: Mutex<State>

    private let writer: IndexWriter

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

        var initial = State()
        initial.index = Self.loadIndex(from: Self.indexURL(in: directory))
        let artworkFiles = (try? FileManager.default.contentsOfDirectory(atPath: Self.artworkDirectory(in: directory).path(percentEncoded: false))) ?? []
        initial.artwork = Set(artworkFiles)
        // Both run, whatever the first finds.
        let migrated = Self.migrateUnscopedRecords(&initial.index, itemsDirectory: Self.itemsDirectory(in: directory))
        let cleaned = Self.removeSavedTokens(&initial.index)
        if migrated || cleaned {
            Self.write(initial.index, to: Self.indexURL(in: directory))
        }
        state = Mutex(initial)
        writer = IndexWriter(url: Self.indexURL(in: directory))

        // Whatever a removal didn't get to delete before the app last closed.
        let trash = Self.trashDirectory(in: directory)
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: trash) }
    }

    // MARK: - Keys

    /// The account (``AppModel/cacheScope``) whose downloads are read and changed by item ID. Set by the download manager.
    var scope: String {
        get { state.withLock { $0.scope } }
        set { state.withLock { $0.scope = newValue } }
    }

    /// Separates the account from the item ID in a key. Neither ever contains it.
    private static let keySeparator: Character = "\u{1F}"

    /// Identifies one account's download of one item, in the index and in its transfer's `taskDescription`.
    static func key(scope: String, id: String) -> String { scope + String(keySeparator) + id }

    /// The account and item ID in a key. A bare item ID, from a transfer started before keys had the account in them,
    /// is taken to be the signed-in account's.
    func parse(key: String) -> (scope: String, id: String) {
        Self.parse(key: key, fallbackScope: scope)
    }

    /// Like ``parse(key:)``, for use with the lock held, where reading ``scope`` would wait on it forever.
    private static func parse(key: String, fallbackScope: String) -> (scope: String, id: String) {
        guard let separator = key.lastIndex(of: keySeparator) else { return (fallbackScope, key) }
        return (String(key[..<separator]), String(key[key.index(after: separator)...]))
    }

    // MARK: - Index

    private static func indexURL(in root: URL) -> URL { root.appending(path: "index.json", directoryHint: .notDirectory) }

    private static func loadIndex(from url: URL) -> DownloadIndex {
        guard let data = try? Data(contentsOf: url) else { return DownloadIndex() }
        do {
            return try JSONDecoder().decode(DownloadIndex.self, from: data)
        } catch {
            logger.error("Couldn't read the downloads index: \(error.localizedDescription, privacy: .public)")
            return DownloadIndex()
        }
    }

    /// Clears subtitle URLs saved by earlier versions, which carried the access token. Returns whether there were any.
    private static func removeSavedTokens(_ index: inout DownloadIndex) -> Bool {
        var changed = false
        for (key, record) in index.records {
            guard var info = record.info, info.subtitleTracks.contains(where: { $0.url != nil }) else { continue }
            info.subtitleTracks = info.subtitleTracks.map { track in
                var track = track
                track.url = nil
                return track
            }
            index.records[key]?.info = info
            changed = true
        }
        return changed
    }

    /// Moves records kept by bare item ID, from before the account was part of the key, and their folders, to where they
    /// go now. Returns whether there were any.
    private static func migrateUnscopedRecords(_ index: inout DownloadIndex, itemsDirectory: URL) -> Bool {
        let unscoped = index.records.filter { !$0.key.contains(keySeparator) }
        for (oldKey, record) in unscoped {
            index.records[oldKey] = nil
            index.records[key(scope: record.scope, id: record.id)] = record
            // An ID that isn't a plain name could point outside the folder; its files, if any, are left where they are.
            guard isPlainName(record.id) else { continue }
            let old = itemsDirectory.appending(path: record.id, directoryHint: .isDirectory)
            let new = itemDirectory(in: itemsDirectory, scope: record.scope, id: record.id)
            try? FileManager.default.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.moveItem(at: old, to: new)
        }
        return !unscoped.isEmpty
    }

    /// Encodes and writes the index, on whatever thread calls it.
    private static func write(_ index: DownloadIndex, to url: URL) {
        do {
            try JSONEncoder().encode(index).write(to: url, options: .atomic)
        } catch {
            logger.error("Couldn't save the downloads index: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Writes the index off the thread that changed it, keeping only the latest version waiting.
    ///
    /// The index holds every download's item, cast and chapters, so encoding it takes a while, and changes come in bursts
    /// (a whole season queued, each download moving from state to state). Writing each one where it was made held up the
    /// main thread and every other user of the lock; now a burst ends in one write, in the background.
    private final class IndexWriter: Sendable {
        private let url: URL

        /// The version waiting to be written, and whether a background write has been asked for.
        private let pending = Mutex<(index: DownloadIndex?, isScheduled: Bool)>((nil, false))

        /// Held while writing, so writes go out one at a time and an older version never lands after a newer one.
        private let writing = Mutex(())

        init(url: URL) {
            self.url = url
        }

        /// Queues `index` to be written, replacing any version still waiting. Returns at once.
        func submit(_ index: DownloadIndex) {
            let shouldSchedule = pending.withLock { pending -> Bool in
                pending.index = index
                guard !pending.isScheduled else { return false }
                pending.isScheduled = true
                return true
            }
            if shouldSchedule {
                Task.detached(priority: .utility) { self.flush() }
            }
        }

        /// Writes the waiting version, if there is one, before returning.
        func flush() {
            writing.withLock { _ in
                // Taken while holding `writing`, so whichever write runs last has the latest version.
                let next = pending.withLock { pending -> DownloadIndex? in
                    defer {
                        pending.index = nil
                        pending.isScheduled = false
                    }
                    return pending.index
                }
                guard let next else { return }
                DownloadStore.write(next, to: url)
            }
        }
    }

    /// Writes any change still waiting to go to disk, before returning. For when the system may suspend the app as soon
    /// as the caller returns: a finished transfer's callback, say, which would otherwise be downloaded again.
    func flush() {
        writer.flush()
    }

    // MARK: - Records

    /// The signed-in account's downloads.
    var records: [DownloadRecord] {
        state.withLock { state in state.index.records.values.filter { $0.scope == state.scope } }
    }

    /// The signed-in account's download of an item.
    func record(id: String) -> DownloadRecord? {
        state.withLock { $0.index.records[Self.key(scope: $0.scope, id: id)] }
    }

    /// Any account's download, by ``key(scope:id:)``.
    func record(key: String) -> DownloadRecord? { state.withLock { $0.index.records[key] } }

    /// Adds or replaces a record, under the account it belongs to.
    func save(_ record: DownloadRecord) {
        state.withLock {
            $0.index.records[Self.key(scope: record.scope, id: record.id)] = record
            writer.submit($0.index)
        }
    }

    /// Changes one of the signed-in account's records in place and returns it, or nil if there's no such record.
    ///
    /// - Parameter persist: Whether to write to disk. Progress changes many times a second, and only needs saving
    ///   when something more lasting happens.
    @discardableResult
    func update(_ id: String, persist: Bool = true, _ change: (inout DownloadRecord) -> Void) -> DownloadRecord? {
        state.withLock { update(Self.key(scope: $0.scope, id: id), in: &$0, persist: persist, change) }
    }

    /// Like ``update(_:persist:_:)``, for any account's record, by ``key(scope:id:)``.
    @discardableResult
    func update(key: String, persist: Bool = true, _ change: (inout DownloadRecord) -> Void) -> DownloadRecord? {
        state.withLock { update(key, in: &$0, persist: persist, change) }
    }

    private func update(_ key: String, in state: inout State, persist: Bool, _ change: (inout DownloadRecord) -> Void) -> DownloadRecord? {
        guard var record = state.index.records[key] else { return nil }
        change(&record)
        state.index.records[key] = record
        if persist { writer.submit(state.index) }
        return record
    }

    /// Deletes the signed-in account's downloads of these items, their files, and whatever nothing else needs any more.
    func remove(ids: [String]) {
        let trash = Self.trashDirectory(in: root).appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let movedAny = state.withLock { state -> Bool in
            var movedAny = false
            for id in ids {
                state.index.records[Self.key(scope: state.scope, id: id)] = nil
                // Moved aside rather than deleted, which for a whole series can take seconds. Still under the lock, so
                // nothing that checks the record is there first (``saveResumeData(_:key:requestURL:)``) can write into
                // the folder after it has gone.
                let directory = itemDirectory(scope: state.scope, id: id)
                guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else { continue }
                if !movedAny { try? FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true) }
                if (try? FileManager.default.moveItem(at: directory, to: trash.appending(path: UUID().uuidString))) == nil {
                    try? FileManager.default.removeItem(at: directory)
                }
                movedAny = true
            }
            pruneUnreferenced(&state)
            writer.submit(state.index)
            return movedAny
        }
        guard movedAny else { return }
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: trash) }
    }

    /// Where removed downloads' folders wait to be deleted, out of the way.
    private static func trashDirectory(in root: URL) -> URL { root.appending(path: "Removed", directoryHint: .isDirectory) }

    /// Drops shows, seasons, people and artwork that no download uses.
    private func pruneUnreferenced(_ state: inout State) {
        let items = state.index.records.values.map(\.item)
        let seriesIDs = Set(items.compactMap(\.seriesID))
        let seasonIDs = Set(items.compactMap(\.seasonID))
        state.index.containers = state.index.containers.filter { seriesIDs.contains($0.key) || seasonIDs.contains($0.key) }

        let personIDs = Set(items.flatMap(\.people).map(\.personID))
        state.index.people = state.index.people.filter { personIDs.contains($0.key) }

        var keep = Set<String>()
        for item in items + Array(state.index.containers.values) {
            for url in Self.artworkURLs(of: item) { keep.insert(Self.artworkName(for: url)) }
        }
        // The folder itself, rather than the list of what's saved, so a file that slipped past the list goes too.
        let files = (try? FileManager.default.contentsOfDirectory(at: artworkDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files where !keep.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
        state.artwork.formIntersection(keep)
    }

    // MARK: - Shows, seasons and people

    /// A show or season the signed-in account has downloads in. Shows and seasons are kept once for every account, but
    /// one account doesn't see what another downloaded.
    func container(id: String) -> MediaItem? {
        state.withLock { Self.currentContainerIDs(in: $0).contains(id) ? $0.index.containers[id] : nil }
    }

    /// The shows and seasons the signed-in account has downloads in.
    var containers: [MediaItem] {
        state.withLock { state in
            let visible = Self.currentContainerIDs(in: state)
            return state.index.containers.values.filter { visible.contains($0.id) }
        }
    }

    /// The shows and seasons of the signed-in account's downloads.
    private static func currentContainerIDs(in state: State) -> Set<String> {
        var ids = Set<String>()
        for record in state.index.records.values where record.scope == state.scope {
            if let id = record.item.seriesID { ids.insert(id) }
            if let id = record.item.seasonID { ids.insert(id) }
        }
        return ids
    }

    func saveContainer(_ item: MediaItem) {
        state.withLock {
            $0.index.containers[item.id] = item
            writer.submit($0.index)
        }
    }

    func personDetails(id: String) -> PersonDetails? { state.withLock { $0.index.people[id] } }

    func savePersonDetails(_ details: PersonDetails, id: String) {
        state.withLock {
            $0.index.people[id] = details
            writer.submit($0.index)
        }
    }

    // MARK: - Files

    private static func itemsDirectory(in root: URL) -> URL { root.appending(path: "Items", directoryHint: .isDirectory) }

    /// An account's folder for an item. The account is hashed: it holds the server's address, which has slashes in it.
    /// The item ID comes from the server, so it's only used as it is when it's a plain name; anything else (a slash,
    /// `..`) could reach outside the folder, which is deleted along with the download, so it's hashed too.
    private static func itemDirectory(in itemsDirectory: URL, scope: String, id: String) -> URL {
        itemsDirectory
            .appending(path: hashed(scope, length: 8), directoryHint: .isDirectory)
            .appending(path: isPlainName(id) ? id : hashed(id, length: 16), directoryHint: .isDirectory)
    }

    private func itemDirectory(scope: String, id: String) -> URL {
        Self.itemDirectory(in: Self.itemsDirectory(in: root), scope: scope, id: id)
    }

    /// Whether a name from the server is safe to use as a folder name: letters, digits and dashes only.
    private static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// The start of the text's SHA-256 hash, in hex.
    private static func hashed(_ text: String, length: Int) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(length).map { String(format: "%02x", $0) }.joined()
    }

    /// The signed-in account's folder for an item.
    func itemDirectory(for id: String) -> URL { itemDirectory(scope: scope, id: id) }

    /// The folder for a download, by ``key(scope:id:)``.
    func itemDirectory(key: String) -> URL {
        let (scope, id) = parse(key: key)
        return itemDirectory(scope: scope, id: id)
    }

    /// Like ``itemDirectory(key:)``, for use with the lock held.
    private func itemDirectory(key: String, in state: State) -> URL {
        let (scope, id) = Self.parse(key: key, fallbackScope: state.scope)
        return itemDirectory(scope: scope, id: id)
    }

    // MARK: - Resume data

    /// Where a paused or interrupted transfer's progress is kept, in the item's folder.
    private static let resumeFileName = "resume.data"

    /// Beside it, the ``tokenFingerprint(_:)`` of the access token its request was made with.
    private static let resumeTokenFileName = "resume.token"

    /// A short hash of an access token, so resume data can be matched to the session that made it without writing the
    /// token down again.
    static func tokenFingerprint(_ token: String) -> String { hashed(token, length: 16) }

    /// The fingerprint of the token in a request URL's `ApiKey`, or nil if it has none.
    private static func tokenFingerprint(in url: URL?) -> String? {
        guard let url,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let token = items.first(where: { $0.name.caseInsensitiveCompare("ApiKey") == .orderedSame })?.value
        else { return nil }
        return tokenFingerprint(token)
    }

    /// Keeps where a transfer got to, so trying again carries on from there, unless its download is gone.
    ///
    /// Under the lock, like ``remove(ids:)``: a pause's resume data arrives a moment after the pause, and if the download
    /// was removed in between, writing it would bring back a folder that nothing points to.
    ///
    /// The data repeats the transfer's request, access token and all. It's only usable with that token, so it's tagged
    /// with its fingerprint, and ``removeResumeData()`` deletes it all when the session ends.
    func saveResumeData(_ data: Data, key: String, requestURL: URL?) {
        // Without a token in the URL, no session's fingerprint matches, and the data is only ever thrown away.
        let fingerprint = Self.tokenFingerprint(in: requestURL) ?? ""
        state.withLock { state in
            guard state.index.records[key] != nil else { return }
            let directory = itemDirectory(key: key, in: state)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appending(path: Self.resumeFileName), options: .atomic)
                try Data(fingerprint.utf8).write(to: directory.appending(path: Self.resumeTokenFileName), options: .atomic)
            } catch {
                Self.logger.error("Couldn't save resume data: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Takes a download's resume data off the disk. Returns it only if it was made with the token `fingerprint` is for:
    /// data from another session would replay a request with a token the server no longer accepts.
    func takeResumeData(key: String, tokenFingerprint fingerprint: String?) -> Data? {
        state.withLock { state in
            let directory = itemDirectory(key: key, in: state)
            let dataFile = directory.appending(path: Self.resumeFileName)
            let tokenFile = directory.appending(path: Self.resumeTokenFileName)
            defer {
                try? FileManager.default.removeItem(at: dataFile)
                try? FileManager.default.removeItem(at: tokenFile)
            }
            guard let fingerprint, let saved = try? Data(contentsOf: tokenFile),
                  String(decoding: saved, as: UTF8.self) == fingerprint
            else { return nil }
            return try? Data(contentsOf: dataFile)
        }
    }

    /// Deletes the signed-in account's resume data, which holds the access token, for when the session ends. Paused
    /// downloads start again from the beginning.
    func removeResumeData() {
        state.withLock { state in
            for record in state.index.records.values where record.scope == state.scope {
                let directory = itemDirectory(scope: state.scope, id: record.id)
                try? FileManager.default.removeItem(at: directory.appending(path: Self.resumeFileName))
                try? FileManager.default.removeItem(at: directory.appending(path: Self.resumeTokenFileName))
            }
        }
    }

    /// The download's folder, by ``key(scope:id:)``, created if it isn't there yet.
    func makeItemDirectory(key: String) throws -> URL {
        let directory = itemDirectory(key: key)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func artworkDirectory(in root: URL) -> URL { root.appending(path: "Artwork", directoryHint: .isDirectory) }

    private var artworkDirectory: URL { Self.artworkDirectory(in: root) }

    private static func artworkName(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func artworkFile(named name: String) -> URL {
        artworkDirectory.appending(path: name, directoryHint: .notDirectory)
    }

    func hasArtwork(for url: URL) -> Bool {
        let name = Self.artworkName(for: url)
        return state.withLock { $0.artwork.contains(name) }
    }

    func saveArtwork(_ data: Data, for url: URL) {
        let name = Self.artworkName(for: url)
        try? FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        guard (try? data.write(to: artworkFile(named: name), options: .atomic)) != nil else { return }
        state.withLock { _ = $0.artwork.insert(name) }
    }

    /// Every image an item shows.
    static func artworkURLs(of item: MediaItem) -> [URL] {
        let own = [item.posterURL, item.seasonPosterURL, item.backdropURL, item.thumbnailURL, item.logoURL]
        let people = item.people.flatMap { [$0.imageURL, $0.largeImageURL] }
        let chapters = item.chapters.map(\.imageURL)
        return (own + people + chapters).compactMap { $0 }.filter { !$0.isFileURL }
    }

    /// The item with each image pointing at its saved copy, where there is one, so it shows without the server.
    func localized(_ item: MediaItem) -> MediaItem {
        // Read once, rather than taking the lock for every image.
        let saved = state.withLock { $0.artwork }
        func local(_ url: URL?) -> URL? {
            guard let url, !url.isFileURL else { return url }
            let name = Self.artworkName(for: url)
            return saved.contains(name) ? artworkFile(named: name) : url
        }
        var item = item
        item.posterURL = local(item.posterURL)
        item.seasonPosterURL = local(item.seasonPosterURL)
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
    var onPendingProgress: (@Sendable () -> Void)? {
        get { state.withLock { $0.onPendingProgress } }
        set { state.withLock { $0.onPendingProgress = newValue } }
    }

    /// Downloads with progress the server hasn't been told about.
    var recordsWithPendingProgress: [DownloadRecord] { records.filter { $0.pendingProgress != nil } }

    /// Forgets sent progress, unless more has been made since.
    func clearPendingProgress(id: String, ifStill sent: PendingProgress) {
        update(id) { if $0.pendingProgress == sent { $0.pendingProgress = nil } }
    }
}
