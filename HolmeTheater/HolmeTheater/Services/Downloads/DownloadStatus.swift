// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Where the downloads under an item are, without how far along: what its menus offer. It doesn't change with every tick
/// of progress, so a menu that reads it isn't rebuilt (which makes an open one flash) while a download runs.
nonisolated enum DownloadStage: Equatable, Sendable {
    case none, downloading, paused, partial, downloaded
}

/// How the downloads under an item are doing, for its download button.
nonisolated enum DownloadStatus: Equatable, Sendable {
    /// Nothing has been downloaded.
    case none
    /// Something is downloading or waiting to; 0 to 1.
    case downloading(progress: Double)
    /// What's left is paused or failed.
    case paused
    /// Some of a show or season is downloaded, not all of it.
    case partial
    /// All of it is downloaded.
    case downloaded
}

/// Everything the download manager derives from the account's records that changes only when something starts, stops,
/// finishes or is added or removed, not with every tick of progress. Views that only care about that read these, so
/// they aren't redrawn while a download runs.
nonisolated struct DownloadSummary: Equatable, Sendable {
    /// The IDs of movies and episodes that are fully downloaded.
    var completedIDs: Set<String> = []

    /// How many downloads are downloading or waiting to. Paused and failed ones aren't counted, since nothing is moving.
    var activeCount = 0

    /// How many episodes of each show and season are fully downloaded, by the show's or season's ID.
    var completedEpisodeCounts: [String: Int] = [:]

    /// The shows and seasons with an episode that isn't downloaded yet: waiting, on its way, paused or failed.
    var unfinishedContainerIDs: Set<String> = []

    /// The IDs of items, shows and seasons with a download that's downloading or waiting to.
    var movingIDs: Set<String> = []

    /// The IDs of items, shows and seasons with a download that's paused or failed.
    var pausedIDs: Set<String> = []

    /// How many downloads, in any state, each movie, episode, show and season has.
    var recordCounts: [String: Int] = [:]

    init() {}

    init(records: [DownloadRecord]) {
        for record in records {
            let containerIDs = [record.item.seriesID, record.item.seasonID].compactMap { $0 }
            let ids = [record.id] + containerIDs
            for id in ids { recordCounts[id, default: 0] += 1 }
            if record.state.isInProgress {
                movingIDs.formUnion(ids)
            } else if record.state.isStalled {
                pausedIDs.formUnion(ids)
            }
            if record.isComplete {
                completedIDs.insert(record.id)
                for id in containerIDs { completedEpisodeCounts[id, default: 0] += 1 }
            } else {
                if record.state.isInProgress { activeCount += 1 }
                unfinishedContainerIDs.formUnion(containerIDs)
            }
        }
    }
}

/// How a batch of downloads is doing as one, for the Live Activity that reports on it.
nonisolated struct DownloadBatchProgress: Equatable, Sendable {
    /// The one download's name, or e.g. "3 Downloads".
    var title: String

    /// A second line: an episode's show and number, or how many have finished.
    var subtitle: String?

    /// How many downloads are done, and how many there are in all.
    var completed: Int
    var total: Int

    /// How far along everything is, from 0 to 1, in whole percents: that's all the activity shows, and finer than that
    /// every update would change nothing on screen and still make the island animate.
    var fraction: Double

    /// Whether nothing is moving because the user paused it, or it failed.
    var isPaused: Bool

    /// Whether every download has finished.
    var isFinished: Bool

    /// Nil for an empty batch.
    init?(members: [DownloadRecord]) {
        guard !members.isEmpty else { return nil }
        completed = members.filter(\.isComplete).count
        total = members.count
        let moving = members.filter { $0.state.isInProgress }
        let stalled = members.filter { $0.state.isStalled }
        isFinished = moving.isEmpty && stalled.isEmpty
        isPaused = moving.isEmpty && !stalled.isEmpty
        fraction = ((members.map { $0.isComplete ? 1 : $0.progress }.reduce(0, +) / Double(members.count)) * 100).rounded() / 100

        if members.count == 1, let only = members.first {
            title = only.item.title
            subtitle = only.item.subtitle
        } else {
            title = String(localized: "\(members.count) Downloads")
            subtitle = String(localized: "\(completed) of \(members.count) finished")
        }
    }
}
