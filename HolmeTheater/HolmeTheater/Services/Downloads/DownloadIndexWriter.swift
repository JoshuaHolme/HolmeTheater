// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import OSLog
import Synchronization

/// Writes the downloads index off the thread that changed it, keeping only the latest version waiting.
///
/// The index holds every download's item, cast and chapters, so encoding it takes a while, and changes come in bursts
/// (a whole season queued, each download moving from state to state). Writing each one where it was made held up the
/// main thread and every other user of the store's lock; here a burst ends in one write, in the background.
nonisolated final class DownloadIndexWriter: Sendable {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "HolmeTheater", category: "DownloadStore")

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
            Self.write(next, to: url)
        }
    }

    /// Encodes and writes an index, on whatever thread calls it.
    static func write(_ index: DownloadIndex, to url: URL) {
        do {
            try JSONEncoder().encode(index).write(to: url, options: .atomic)
        } catch {
            logger.error("Couldn't save the downloads index: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Reads an index, or an empty one if there isn't one or it can't be read.
    static func load(from url: URL) -> DownloadIndex {
        guard let data = try? Data(contentsOf: url) else { return DownloadIndex() }
        do {
            return try JSONDecoder().decode(DownloadIndex.self, from: data)
        } catch {
            logger.error("Couldn't read the downloads index: \(error.localizedDescription, privacy: .public)")
            return DownloadIndex()
        }
    }
}
