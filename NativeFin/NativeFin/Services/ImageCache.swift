// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CryptoKit
import Foundation
import OSLog
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
nonisolated final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NativeFin", category: "ImageCache")

    /// Decoded images are kept up to roughly this many bytes. NSCache treats it as a hint, and the system
    /// also evicts under memory pressure.
    private static let maxMemoryBytes = 100 * 1024 * 1024

    /// The disk cache is trimmed back under this by deleting the oldest files.
    private static let maxDiskBytes = 300 * 1024 * 1024

    /// Trim again after this many bytes have been written since the last trim.
    private static let trimInterval = 50 * 1024 * 1024

    private let memory = NSCache<NSURL, PlatformImage>()

    /// Has no cache of its own, because this type does the caching.
    private let session = URLSession(configuration: .ephemeral)
    private let directory: URL

    /// Guards the three properties below.
    private let lock = NSLock()

    /// Decodes in progress, so several views asking for the same URL share one.
    private var decodes: [URL: Task<PlatformImage?, Never>] = [:]

    /// Downloads in progress, so a view and a prefetch asking for the same URL share one request.
    private var downloads: [URL: Task<Data?, Never>] = [:]

    private var bytesWrittenSinceTrim = 0

    private init() {
        memory.totalCostLimit = Self.maxMemoryBytes

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
        memory.removeAllObjects()
        let directory = directory
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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

        let task = lock.withLock { () -> Task<PlatformImage?, Never> in
            if let existing = decodes[url] { return existing }
            let new = Task { await self.decode(url) }
            decodes[url] = new
            return new
        }

        let image = await task.value
        lock.withLock { decodes[url] = nil }
        return image
    }

    // MARK: - Prefetching

    /// Starts downloading these images to disk in the background, so they're a fast local read by the time
    /// anyone scrolls to them.
    ///
    /// Only the disk is filled, not memory. It runs a few downloads at a time at low priority and skips
    /// anything already cached.
    func prefetch(_ urls: [URL]) {
        let pending = urls.filter { cachedImage(for: $0) == nil && !isOnDisk($0) }
        guard !pending.isEmpty else { return }

        Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                var remaining = pending.makeIterator()
                for _ in 0..<4 {
                    guard let url = remaining.next() else { break }
                    group.addTask { _ = await self.data(for: url) }
                }
                // As each finishes, start the next, so four are always in flight.
                while await group.next() != nil {
                    guard let url = remaining.next() else { continue }
                    group.addTask { _ = await self.data(for: url) }
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
    private func decode(_ url: URL) async -> PlatformImage? {
        guard let data = await data(for: url) else { return nil }

        guard var image = PlatformImage(data: data) else {
            // Unreadable bytes (e.g. a truncated write); drop the file so the next request refetches.
            try? FileManager.default.removeItem(at: diskURL(for: url))
            return nil
        }

        #if canImport(UIKit)
        // Decode now, off the main thread, so drawing the image later doesn't hitch scrolling.
        image = await image.byPreparingForDisplay() ?? image
        #endif

        memory.setObject(image, forKey: url as NSURL, cost: Self.cost(of: image))
        return image
    }

    /// The image's bytes: from disk if cached there, otherwise downloaded and saved.
    private func data(for url: URL) async -> Data? {
        if let data = try? Data(contentsOf: diskURL(for: url)) { return data }

        let task = lock.withLock { () -> Task<Data?, Never> in
            if let existing = downloads[url] { return existing }
            let new = Task { await self.download(url) }
            downloads[url] = new
            return new
        }

        let data = await task.value
        lock.withLock { downloads[url] = nil }
        return data
    }

    private func download(_ url: URL) async -> Data? {
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }

        try? data.write(to: diskURL(for: url), options: .atomic)

        // Keep the disk cache from growing without bound during a long session.
        let shouldTrim = lock.withLock { () -> Bool in
            bytesWrittenSinceTrim += data.count
            guard bytesWrittenSinceTrim >= Self.trimInterval else { return false }
            bytesWrittenSinceTrim = 0
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

/// Resumes a continuation the first time it's asked to, and ignores any later request.
private nonisolated final class ResumeOnce: @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Never>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume()
    }
}
