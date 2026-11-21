// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CryptoKit
import Foundation
import OSLog
import Synchronization
#if canImport(UIKit)
import UIKit
/// The platform's native image type.
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#endif

/// Downloads and caches artwork so it's already there when a card scrolls into view.
///
/// SwiftUI's `AsyncImage` keeps no decoded images and starts every view empty, so recycled cards flash a
/// placeholder and refetch. This cache avoids that with two layers:
/// - **disk**: the downloaded bytes, in the system caches directory, which survive relaunches;
/// - **memory**: decoded, ready-to-draw images, which can be read synchronously.
///
/// Prefetching fills only the disk layer. A decoded image costs far more memory than its file (a 450×675
/// poster is about 1.2 MB decoded), so images are decoded only when something actually asks to show one.
///
/// Jellyfin image URLs include a tag that changes whenever the image does, so a cached file for a URL is never
/// stale and nothing needs to be invalidated.
nonisolated final class ImageCache: Sendable {
    static let shared = ImageCache()

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "HolmeTheater", category: "ImageCache")
    private static let diagQueue = DispatchQueue(label: "ImageCache.diag") // TEMP-DIAGNOSTIC

    /// Decoded images are kept up to roughly this many bytes. NSCache treats it as a hint, and the system
    /// also evicts under memory pressure.
    private static let maxMemoryBytes = 100 * 1024 * 1024

    /// The disk cache is trimmed back under this by deleting the oldest files.
    private static let maxDiskBytes = 300 * 1024 * 1024

    /// Trim again after this many bytes have been written since the last trim.
    private static let trimInterval = 50 * 1024 * 1024

    private let memory = SharedCache<NSURL, PlatformImage>(totalCostLimit: maxMemoryBytes)

    /// Has no cache of its own, because this type does the caching.
    private let session = URLSession(configuration: .ephemeral)
    private let directory: URL

    /// What changes, behind one lock. Anything that puts an image in the cache holds it too.
    private struct State {
        /// Decodes in progress, so several views asking for the same URL share one.
        var decodes: [URL: Task<PlatformImage?, Never>] = [:]

        /// Downloads in progress, so a view and a prefetch asking for the same URL share one request.
        var downloads: [URL: Task<Data?, Never>] = [:]

        var bytesWrittenSinceTrim = 0

        /// Goes up with every ``removeAll()``. Work started before then mustn't put what it loaded in the cache, or the
        /// previous user's artwork would be back as soon as it finished.
        var generation = 0
    }

    private let state = Mutex(State())

    /// Held while writing into the folder and while ``removeAll()`` moves it aside, so disk work stays out of ``state``'s
    /// lock, which views take on the main thread. A write checks ``State/generation`` while holding it.
    private let disk = Mutex(())

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appending(path: "ImageCache", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        trimDiskCacheInBackground()
    }

    /// Forgets every cached image, in memory and on disk.
    ///
    /// Called on sign-out, so a shared device (an Apple TV in a living room, say) doesn't keep the previous
    /// user's artwork and profile picture.
    func removeAll() {
        let fileManager = FileManager.default
        let trash = directory.deletingLastPathComponent()
            .appending(path: "ImageCache-removed-\(UUID().uuidString)", directoryHint: .isDirectory)
        let (decodes, downloads) = state.withLock { state in
            state.generation += 1
            let inFlight = (state.decodes, state.downloads)
            state.decodes = [:]
            state.downloads = [:]
            memory.removeAllObjects()
            return inFlight
        }
        // Moved aside at once, under the disk lock, so nothing in flight can write into the folder after it's been
        // emptied: a write that gets the lock after this sees the new generation and skips. Deleting what's in it, which
        // can take a while, happens afterwards.
        disk.withLock { _ in
            try? fileManager.moveItem(at: directory, to: trash)
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for task in decodes.values { task.cancel() }
        for task in downloads.values { task.cancel() }
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: trash)
        }
    }

    // MARK: - Reading

    /// The decoded image if it's already in memory. Synchronous, so a view can show it on its very first frame.
    func cachedImage(for url: URL) -> PlatformImage? {
        memory.object(forKey: url as NSURL)
    }

    /// The image for `url`, from memory, then disk, then the network. Nil if it can't be loaded.
    ///
    /// Concurrent calls for the same URL share one decode. Work isn't cancelled if a caller goes away
    /// (a card scrolling off screen), so the result still lands in the cache.
    func image(for url: URL) async -> PlatformImage? {
        if let cached = cachedImage(for: url) { return cached }

        let task = state.withLock { state -> Task<PlatformImage?, Never> in
            if let existing = state.decodes[url] { return existing }
            let generation = state.generation
            let new = Task { await self.decode(url, generation: generation) }
            state.decodes[url] = new
            return new
        }

        let image = await task.value
        // Unless `removeAll()` has run since, and the entry is a newer decode's.
        state.withLock { state in if state.decodes[url] == task { state.decodes[url] = nil } }
        return image
    }

    // MARK: - Prefetching

    /// Starts downloading these images to disk in the background, so they're a fast local read by the time
    /// anyone scrolls to them.
    ///
    /// Only the disk is filled, not memory. It runs a few downloads at a time at low priority and skips
    /// anything already cached.
    func prefetch(_ urls: [URL]) {
        let uncached = urls.filter { cachedImage(for: $0) == nil }
        guard !uncached.isEmpty else { return }
        // Those not started by the time the cache is emptied are skipped.
        let generation = state.withLock { $0.generation }

        Task.detached(priority: .utility) {
            // Checked here rather than by the caller, which is usually the main thread: it's a trip to the disk for each.
            let pending = uncached.filter { !self.isOnDisk($0) }
            await withTaskGroup(of: Void.self) { group in
                var remaining = pending.makeIterator()
                for _ in 0..<4 {
                    guard let url = remaining.next() else { break }
                    group.addTask { _ = await self.data(for: url, generation: generation) }
                }
                // As each finishes, start the next, so four are always in flight.
                while await group.next() != nil {
                    guard let url = remaining.next() else { continue }
                    group.addTask { _ = await self.data(for: url, generation: generation) }
                }
            }
        }
    }

    /// Loads these images into memory and returns once they're ready, so a row can appear with its pictures rather
    /// than the pictures popping in after it. Gives up waiting after `timeout`, so a slow network can't hold a
    /// screen back; the downloads carry on in the background either way.
    ///
    /// Use it for what shows first. A decoded image costs a lot of memory (see the type's notes), so it isn't for
    /// a whole library.
    func preload(_ urls: [URL], timeout: Duration = .seconds(2)) async {
        let pending = urls.filter { cachedImage(for: $0) == nil }
        guard !pending.isEmpty else { return }

        // A download can't be cancelled, so a task group can't be raced against the timeout (it waits for every
        // child). Two separate tasks do instead: whichever finishes first resumes the caller, the other is harmless.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(continuation)
            Task {
                await withTaskGroup(of: Void.self) { group in
                    for url in pending {
                        group.addTask { _ = await self.image(for: url) }
                    }
                }
                once.resume()
            }
            Task {
                try? await Task.sleep(for: timeout)
                once.resume()
            }
        }
    }

    // MARK: - Loading

    /// Reads the image from disk (downloading it first if needed) and decodes it into the memory cache.
    ///
    /// `@concurrent`, like ``data(for:generation:)``, so the file reads and decoding never run on the caller's actor,
    /// even if a later change calls it from the main thread.
    @concurrent private func decode(_ url: URL, generation: Int) async -> PlatformImage? {
        guard let data = await data(for: url, generation: generation) else { return nil }

        guard var image = PlatformImage(data: data) else {
            // Unreadable bytes (e.g. a truncated write); drop the file so the next request refetches.
            try? FileManager.default.removeItem(at: diskURL(for: url))
            return nil
        }

        #if canImport(UIKit)
        // TEMP-DIAGNOSTIC: remove after finding which image logs the Decompressor error.
        let diagPath = url.isFileURL ? url.lastPathComponent : url.path()
        let diagImage = image
        let diagBytes = data.count
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Self.diagQueue.async {
                Self.logger.error("DIAG begin \(diagPath, privacy: .public) bytes=\(diagBytes)")
                _ = diagImage.preparingForDisplay()
                Self.logger.error("DIAG end \(diagPath, privacy: .public)")
                continuation.resume()
            }
        }
        // Decode now, off the main thread, so drawing the image later doesn't hitch scrolling.
        if let prepared = await image.byPreparingForDisplay() {
            image = prepared
        } else {
            // Shown as it is, which may come out wrong. Logged by path, which names the item and kind of image, so a bad file on
            // the server can be found; the query, where a token could be, is left out.
            Self.logger.error("Couldn't decode image \(url.isFileURL ? url.lastPathComponent : url.path(), privacy: .public) (\(data.count) bytes)")
        }
        #endif

        // Checked and stored under one lock, so `removeAll()` can't empty the cache between the two.
        state.withLock { state in
            guard generation == state.generation else { return }
            memory.setObject(image, forKey: url as NSURL, cost: Self.cost(of: image))
        }
        return image
    }

    /// The image's bytes: from disk if cached there, otherwise downloaded and saved.
    ///
    /// - Parameter generation: The ``generation`` the caller started in.
    @concurrent private func data(for url: URL, generation: Int) async -> Data? {
        // Artwork saved with a download is already a file, so there's nothing to fetch or cache.
        if url.isFileURL { return try? Data(contentsOf: url) }
        if let data = try? Data(contentsOf: diskURL(for: url)) { return data }

        let task = state.withLock { state -> Task<Data?, Never>? in
            // Started before the cache was emptied, so there's nothing it should fetch.
            guard generation == state.generation else { return nil }
            if let existing = state.downloads[url] { return existing }
            let new = Task { await self.download(url, generation: generation) }
            state.downloads[url] = new
            return new
        }
        guard let task else { return nil }

        let data = await task.value
        state.withLock { state in if state.downloads[url] == task { state.downloads[url] = nil } }
        return data
    }

    private func download(_ url: URL, generation: Int) async -> Data? {
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }

        // Written under the disk lock, so it can't land in the folder after `removeAll()` has emptied it.
        let wrote = disk.withLock { _ -> Bool in
            guard generation == state.withLock({ $0.generation }) else { return false }
            return (try? data.write(to: diskURL(for: url), options: .atomic)) != nil
        }

        // Keep the disk cache from growing without bound during a long session.
        let shouldTrim = wrote && state.withLock { state -> Bool in
            state.bytesWrittenSinceTrim += data.count
            guard state.bytesWrittenSinceTrim >= Self.trimInterval else { return false }
            state.bytesWrittenSinceTrim = 0
            return true
        }
        if shouldTrim { trimDiskCacheInBackground() }

        return data
    }

    /// Roughly how many bytes the decoded image occupies, for the memory cache's limit.
    private static func cost(of image: PlatformImage) -> Int {
        #if canImport(UIKit)
        Int(image.size.width * image.scale * image.size.height * image.scale * 4)
        #else
        Int(image.size.width * image.size.height * 4)
        #endif
    }

    // MARK: - Disk

    /// Where the bytes for `url` live: a file named by the URL's hash.
    private func diskURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: name, directoryHint: .notDirectory)
    }

    private func isOnDisk(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: diskURL(for: url).path(percentEncoded: false))
    }

    private func trimDiskCacheInBackground() {
        let directory = directory
        Task.detached(priority: .utility) { Self.trimDiskCache(in: directory) }
    }

    /// Deletes the oldest files until the cache is back under its size limit.
    private static func trimDiskCache(in directory: URL) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }

        let entries = files.compactMap { url -> (url: URL, date: Date, size: Int)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let date = values.contentModificationDate,
                  let size = values.fileSize
            else { return nil }
            return (url, date, size)
        }

        var total = entries.reduce(0) { $0 + $1.size }
        logger.debug("Disk cache: \(entries.count) files, \(total / 1024 / 1024) MB (limit \(maxDiskBytes / 1024 / 1024) MB)")
        guard total > maxDiskBytes else { return }

        for entry in entries.sorted(by: { $0.date < $1.date }) {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
            if total <= maxDiskBytes { break }
        }
    }
}

/// An `NSCache` that can be shared between threads.
///
/// `NSCache` is documented as safe to use from several threads at once, but isn't marked `Sendable`, so this says so for
/// it. It's the one place that does: nothing else needs to be taken on trust.
nonisolated final class SharedCache<Key: AnyObject, Value: AnyObject>: @unchecked Sendable {
    private let cache = NSCache<Key, Value>()

    /// Roughly how much the values may cost in all; see `NSCache.totalCostLimit`.
    init(totalCostLimit: Int = 0) {
        cache.totalCostLimit = totalCostLimit
    }

    func object(forKey key: Key) -> Value? { cache.object(forKey: key) }

    func setObject(_ value: Value, forKey key: Key, cost: Int = 0) { cache.setObject(value, forKey: key, cost: cost) }

    func removeAllObjects() { cache.removeAllObjects() }
}

/// Resumes a continuation the first time it's asked to, and ignores any later request.
private nonisolated final class ResumeOnce: Sendable {
    private let continuation: Mutex<CheckedContinuation<Void, Never>?>

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume() {
        let pending = continuation.withLock { continuation in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume()
    }
}
