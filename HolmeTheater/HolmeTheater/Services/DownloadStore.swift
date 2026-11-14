// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CryptoKit
import Foundation
import OSLog
import Synchronization

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

    /// Held while files in the items' folders are written, moved or deleted, and while ``artworkFiles`` are. Disk work
    /// is kept out of ``state``'s lock, which the main thread takes many times a second, so it never waits on the disk.
    ///
    /// Whatever checks the index before touching the disk (that a download hasn't been removed, say) does it while
    /// holding the file lock, taking ``state``'s inside it, never the other way round.
    private let itemFiles = Mutex(())
    private let artworkFiles = Mutex(())

    private let writer: DownloadIndexWriter

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
        initial.index = DownloadIndexWriter.load(from: Self.indexURL(in: directory))
        let artworkFiles = (try? FileManager.default.contentsOfDirectory(atPath: Self.artworkDirectory(in: directory).path(percentEncoded: false))) ?? []
        initial.artwork = Set(artworkFiles)
        // Both run, whatever the first finds.
        let migrated = Self.migrateUnscopedRecords(&initial.index, itemsDirectory: Self.itemsDirectory(in: directory))
        let cleaned = Self.removeSavedTokens(&initial.index)
        if migrated || cleaned {
            DownloadIndexWriter.write(initial.index, to: Self.indexURL(in: directory))
        }
        state = Mutex(initial)
        writer = DownloadIndexWriter(url: Self.indexURL(in: directory))

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
    static func parse(key: String, fallbackScope: String) -> (scope: String, id: String) {
        guard let separator = key.lastIndex(of: keySeparator) else { return (fallbackScope, key) }
        return (String(key[..<separator]), String(key[key.index(after: separator)...]))
    }

    // MARK: - Index

    private static func indexURL(in root: URL) -> URL { root.appending(path: "index.json", directoryHint: .notDirectory) }

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
        let directories = state.withLock { state -> [URL] in
            let directories = ids.map { id in
                state.index.records[Self.key(scope: state.scope, id: id)] = nil
                return itemDirectory(scope: state.scope, id: id)
            }
            pruneUnreferenced(&state)
            writer.submit(state.index)
            return directories
        }
        // Moved aside rather than deleted, which for a whole series can take seconds. The records are already gone, and
        // anything that writes into a folder (``saveResumeData(_:key:request:)``) checks its record under this same
        // lock, so nothing can write into one after it has been moved.
        let movedAny = itemFiles.withLock { _ -> Bool in
            var movedAny = false
            for directory in directories where FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) {
                if !movedAny { try? FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true) }
                if (try? FileManager.default.moveItem(at: directory, to: trash.appending(path: UUID().uuidString))) == nil {
                    try? FileManager.default.removeItem(at: directory)
                }
                movedAny = true
            }
            return movedAny
        }
        guard movedAny else { return }
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: trash) }
    }

    /// Where removed downloads' folders wait to be deleted, out of the way.
    private static func trashDirectory(in root: URL) -> URL { root.appending(path: "Removed", directoryHint: .isDirectory) }

    /// Drops shows, seasons and people that no download uses, and forgets their artwork. The files themselves are deleted
    /// in the background (see ``removeUnreferencedArtworkFiles()``): listing and deleting them could hold up the main
    /// thread, and everything else waiting on the lock.
    private func pruneUnreferenced(_ state: inout State) {
        let items = state.index.records.values.map(\.item)
        let seriesIDs = Set(items.compactMap(\.seriesID))
        let seasonIDs = Set(items.compactMap(\.seasonID))
        state.index.containers = state.index.containers.filter { seriesIDs.contains($0.key) || seasonIDs.contains($0.key) }

        let personIDs = Set(items.flatMap(\.people).map(\.personID))
        state.index.people = state.index.people.filter { personIDs.contains($0.key) }

        state.artwork.formIntersection(Self.referencedArtwork(in: state.index))
        Task.detached(priority: .utility) { [self] in removeUnreferencedArtworkFiles() }
    }

    /// The file names of every image the index's downloads, shows and seasons show.
    private static func referencedArtwork(in index: DownloadIndex) -> Set<String> {
        var names = Set<String>()
        for item in index.records.values.map(\.item) + Array(index.containers.values) {
            for url in artworkURLs(of: item) { names.insert(artworkName(for: url)) }
        }
        return names
    }

    /// Deletes the saved images nothing uses any more. Goes by the folder itself, rather than the list of what's saved, so
    /// a file that slipped past the list goes too.
    private func removeUnreferencedArtworkFiles() {
        // Listed without the lock, which is the slow part.
        let files = (try? FileManager.default.contentsOfDirectory(at: artworkDirectory, includingPropertiesForKeys: nil)) ?? []
        guard !files.isEmpty else { return }
        artworkFiles.withLock { _ in
            // Worked out again now, under the lock that ``saveArtwork(_:for:)`` saves with, so an image saved for a
            // download since the removal isn't taken for an unused one.
            let keep = state.withLock { Self.referencedArtwork(in: $0.index).union($0.artwork) }
            for file in files where !keep.contains(file.lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        }
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
    static func isPlainName(_ name: String) -> Bool {
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

    /// The fingerprint of the token a request was made with: in its `Authorization` header, or, for a transfer started
    /// before the token moved out of the URL, its `ApiKey`. Nil if it has neither.
    static func tokenFingerprint(in request: URLRequest?) -> String? {
        guard let request else { return nil }
        if let header = request.value(forHTTPHeaderField: "Authorization"),
           let start = header.range(of: "Token=\"")?.upperBound,
           let end = header[start...].firstIndex(of: "\"") {
            return tokenFingerprint(String(header[start..<end]))
        }
        guard let url = request.url,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let token = items.first(where: { $0.name.caseInsensitiveCompare("ApiKey") == .orderedSame })?.value
        else { return nil }
        return tokenFingerprint(token)
    }

    /// Keeps where a transfer got to, so trying again carries on from there, unless its download is gone.
    ///
    /// Under the item-files lock, like ``remove(ids:)``'s moving of folders: a pause's resume data arrives a moment after
    /// the pause, and if the download was removed in between, writing it would bring back a folder that nothing points to.
    ///
    /// The data repeats the transfer's request, access token and all. It's only usable with that token, so it's tagged
    /// with its fingerprint, and ``removeResumeData()`` deletes it all when the session ends.
    func saveResumeData(_ data: Data, key: String, request: URLRequest?) {
        // Without a token in the request, no session's fingerprint matches, and the data is only ever thrown away.
        let fingerprint = Self.tokenFingerprint(in: request) ?? ""
        itemFiles.withLock { _ in
            let directory = state.withLock { state in
                state.index.records[key] != nil ? itemDirectory(key: key, in: state) : nil
            }
            guard let directory else { return }
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
        let directory = itemDirectory(key: key)
        return itemFiles.withLock { _ in
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
        let directories = state.withLock { state in
            state.index.records.values.filter { $0.scope == state.scope }.map { itemDirectory(scope: state.scope, id: $0.id) }
        }
        itemFiles.withLock { _ in
            for directory in directories {
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

    /// Saves an image. Called off the main thread, while a download is prepared.
    func saveArtwork(_ data: Data, for url: URL) {
        let name = Self.artworkName(for: url)
        try? FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        // Written and listed under one lock, so ``removeUnreferencedArtworkFiles()`` never finds the file without its name.
        artworkFiles.withLock { _ in
            guard (try? data.write(to: artworkFile(named: name), options: .atomic)) != nil else { return }
            _ = state.withLock { $0.artwork.insert(name) }
        }
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

    /// Past this share of the runtime an item counts as finished, like the server's own rule of thumb.
    static let playedThreshold = 0.9

    /// Remembers how far through a downloaded item the viewer got, so it resumes there and shows as watched even when
    /// the server can't be told.
    ///
    /// - Parameter persist: Whether to write to disk. Playback reports every few seconds; only its end needs saving.
    func updateProgress(id: String, position: TimeInterval, persist: Bool) {
        update(id, persist: persist) { record in
            guard let runtime = record.item.runtime, runtime > 0 else { return }
            let fraction = position / runtime
            // Past the credits it counts as finished, like the server's own rule of thumb.
            let isPlayed = fraction >= Self.playedThreshold
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
