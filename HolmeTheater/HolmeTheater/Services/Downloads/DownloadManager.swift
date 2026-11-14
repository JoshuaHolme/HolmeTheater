// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation
import OSLog

/// Downloads movies and episodes for offline viewing, and keeps track of them.
///
/// The files come through a background `URLSession`, so they carry on when the app is closed or suspended. Before each
/// file, the item's details, cast and bios, artwork, subtitles and skip markers are saved too, so it can be shown and
/// played with no server (see ``OfflineFallbackMediaService``).
///
/// Only the signed-in account's downloads are visible (see ``accountChanged(scope:accessToken:)``).
///
/// This file holds the stored state, the account handling and the reading side. Starting, pausing, running transfers,
/// saving details, session events and the Live Activity are in `DownloadManager+Running.swift`.
@Observable
final class DownloadManager {
    /// The background session's identifier, which the system uses to wake the app when downloads finish.
    static let sessionIdentifier = (Bundle.main.bundleIdentifier ?? "HolmeTheater") + ".downloads"

    /// How many downloads run at once. Each is a whole movie or episode, so more would only slow each down.
    static let maxConcurrent = 2

    nonisolated static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "HolmeTheater", category: "Downloads")

    /// The account's downloads in every state, oldest first. Changes with every tick of progress, so views that only
    /// care whether something is downloaded read ``summary`` instead.
    private(set) var records: [DownloadRecord] = []

    /// Everything derived from ``records`` that changes only when a download starts, stops, finishes or is added or
    /// removed, not with progress. Views that only care about that read it, so a tick of progress doesn't redraw them.
    private(set) var summary = DownloadSummary()

    /// The IDs of movies and episodes that are fully downloaded.
    var completedIDs: Set<String> { summary.completedIDs }

    /// How many downloads are downloading or waiting to.
    var activeCount: Int { summary.activeCount }

    /// What each collection and playlist holds, by its ID, as far as the screens that have shown them know. Downloads are
    /// kept per movie and episode, so a collection's or playlist's state is worked out from its members'. Not saved: a
    /// screen registers its members (see ``register(_:asMembersOf:)``) each time it loads them.
    private(set) var groupMembers: [String: [MediaItem]] = [:]

    /// Set when something couldn't be started, to show in an alert. The owner clears it.
    var errorMessage: String?

    @ObservationIgnored let store: DownloadStore

    /// The server itself, not the offline-aware wrapper: a download has to come from the server.
    @ObservationIgnored let service: any MediaService
    @ObservationIgnored let session: URLSession
    @ObservationIgnored private(set) var scope = ""

    /// ``DownloadStore/tokenFingerprint(_:)`` of the signed-in session's access token, so resume data made with an
    /// older one isn't used.
    @ObservationIgnored private(set) var tokenFingerprint: String?

    /// For the subtitle and artwork requests made while preparing a download. Subtitle URLs carry the access token, and
    /// the shared session's cache would write them to disk.
    @ObservationIgnored let detailsSession = URLSession(configuration: .ephemeral)

    /// Items being prepared (details, artwork, the file's URL), by item ID, so they can be cancelled. Only ever the
    /// signed-in account's: changing accounts cancels them.
    @ObservationIgnored var preparations: [String: Task<Void, Never>] = [:]

    /// The items downloaded together, which the Live Activity reports on as one. Emptied when they're all done.
    @ObservationIgnored var batch: Set<String> = []

    @ObservationIgnored let backgroundEvents = BackgroundEvents()

    #if os(iOS)
    /// Whether a Live Activity may be showing downloads in progress. True at first, since one can be left over from an
    /// earlier launch that was closed mid-download; the first time there's nothing to show, it's taken down.
    @ObservationIgnored var hasActivity = true
    @ObservationIgnored let activityUpdater = LiveActivityUpdater()

    /// What the activity was last told to show, so an update that wouldn't change it isn't sent.
    @ObservationIgnored var lastActivityState: DownloadActivityAttributes.ContentState?
    @ObservationIgnored var lastActivityUpdate = Date.distantPast
    #endif

    @ObservationIgnored private var isSyncing = false

    /// - Parameter background: Whether downloads continue while the app isn't running. Only one background session
    ///   can exist per identifier, so previews and tests turn it off.
    init(service: any MediaService, store: DownloadStore = DownloadStore(), background: Bool = true) {
        self.service = service
        self.store = store

        let configuration = background ? URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier) : .default
        configuration.sessionSendsLaunchEvents = true
        // Wait for the network to come back instead of failing, so a download rides out a dropped connection.
        configuration.waitsForConnectivity = true
        let delegate = DownloadSessionDelegate(store: store, backgroundEvents: backgroundEvents)
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        delegate.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }

        // Progress made offline goes to the server once it can be reached: when playback ends, and when the network
        // comes back.
        store.onPendingProgress = { [weak self] in
            Task { @MainActor in await self?.syncProgress() }
        }
        NetworkMonitor.shared.onReconnect = { [weak self] in
            Task { @MainActor in await self?.syncProgress() }
        }
    }

    // MARK: - Syncing watch progress

    /// Tells the server about progress made on downloaded copies that it hasn't heard yet. Anything that can't be sent
    /// now stays for next time.
    func syncProgress() async {
        guard !scope.isEmpty, !isSyncing, NetworkMonitor.shared.isOnline else { return }
        isSyncing = true
        defer { isSyncing = false }

        for record in store.recordsWithPendingProgress where record.scope == scope {
            guard let pending = record.pendingProgress else { continue }
            do {
                try await service.syncProgress(itemID: record.id, position: pending.position, isPlayed: pending.isPlayed, date: pending.date)
                store.clearPendingProgress(id: record.id, ifStill: pending)
            } catch MediaServiceError.itemNotFound {
                // Gone from the server, so there's nothing to tell it.
                store.clearPendingProgress(id: record.id, ifStill: pending)
            } catch {
                // Unreachable, or the session lapsed. Try again later.
                Self.logger.notice("Couldn't sync progress for \(record.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        refresh()
    }

    // MARK: - Account

    /// Shows the downloads of the account that's signed in (or none, when `scope` is empty), and picks up any that
    /// were interrupted.
    ///
    /// - Parameter accessToken: The signed-in session's token, which paused downloads' resume data has to match.
    func accountChanged(scope newScope: String, accessToken: String?) {
        tokenFingerprint = accessToken.map(DownloadStore.tokenFingerprint)
        guard newScope != scope else { return }
        // What the last account was preparing stops; its records stay `.preparing`, which `resumeInterrupted` queues
        // again when that account is back.
        for task in preparations.values { task.cancel() }
        preparations = [:]
        scope = newScope
        store.scope = newScope
        batch = []
        refresh()
        guard !newScope.isEmpty else { return }
        verifyFiles()
        Task {
            await resumeInterrupted()
            await syncProgress()
        }
    }

    /// Marks finished downloads whose video the system has removed (to free up space) as failed, so they show as needing
    /// a new download rather than as playable.
    func verifyFiles() {
        var changed = false
        for record in store.records where record.isComplete && store.localPlayback(for: record.id, resumeFrom: record.item) == nil {
            store.update(record.id) {
                $0.state = .failed
                $0.errorMessage = String(localized: "Removed by the system to free up space. Download it again.")
                $0.videoFileName = nil
                $0.fileSize = 0
                $0.bytesWritten = 0
            }
            changed = true
        }
        if changed { refresh() }
    }

    /// The signed-in account's key for an item, which its transfer is described by.
    func taskKey(_ id: String) -> String { DownloadStore.key(scope: scope, id: id) }

    /// Deletes the signed-in account's downloads, e.g. on sign-out, so the next person on the device doesn't get them.
    /// Other accounts' downloads stay, for when they sign back in.
    func removeAllForAccount() {
        // Which also takes down the Live Activity, now there's nothing left in the batch.
        remove(ids: store.records.map(\.id))
    }

    /// Deletes what paused downloads kept to carry on from, for when the session ends but the downloads stay. It holds the
    /// session's access token, which shouldn't outlive it on disk. Those downloads start again when resumed.
    func discardResumeData() {
        store.removeResumeData()
    }

    /// Lets the system's background-session wake-up finish once this app has been told about every finished download.
    func waitForBackgroundEvents() async {
        await backgroundEvents.wait()
    }

    // MARK: - Reading

    /// Reloads the account's records and the summary derived from them. The summary is only reassigned when it changes,
    /// so views reading it aren't invalidated by a tick of progress. Called from the running extension; it lives here so
    /// it can write the ``private(set)`` state.
    func refresh() {
        records = store.records.sorted { $0.dateAdded < $1.dateAdded }
        let summary = DownloadSummary(records: records)
        if summary != self.summary { self.summary = summary }
    }

    func record(for id: String) -> DownloadRecord? { records.first { $0.id == id } }

    /// Whether a movie or episode is fully downloaded. For a show or season, whether every episode is.
    ///
    /// Reads only what changes when something finishes or starts, not with progress, so the badges on every card that
    /// call this aren't redrawn while a download runs.
    func isDownloaded(_ item: MediaItem) -> Bool {
        switch item.kind {
        case .collection, .playlist:
            guard let members = groupMembers[item.id], !members.isEmpty else { return false }
            return members.allSatisfy(isDownloaded)
        case .movie, .episode:
            return summary.completedIDs.contains(item.id)
        case .season, .series:
            // The same rule as `stage(of:)`'s `.downloaded`.
            guard !summary.unfinishedContainerIDs.contains(item.id), let count = summary.completedEpisodeCounts[item.id] else { return false }
            return count >= (item.episodeCount ?? .max)
        case .extra, .other:
            return false
        }
    }

    /// Tells the manager what a collection or playlist holds, so it can say how its downloads are doing.
    func register(_ members: [MediaItem], asMembersOf group: MediaItem) {
        guard group.kind == .collection || group.kind == .playlist else { return }
        // A playlist can hold something twice, which is still one download.
        var seen = Set<String>()
        groupMembers[group.id] = members.filter { seen.insert($0.id).inserted }
    }

    /// The downloads an item stands for: itself, or the episodes of a show or season.
    func records(under item: MediaItem) -> [DownloadRecord] {
        switch item.kind {
        case .movie, .episode: return records.filter { $0.id == item.id }
        case .season: return records.filter { $0.item.seasonID == item.id }
        case .series: return records.filter { $0.item.seriesID == item.id }
        case .collection, .playlist:
            // The members' own downloads, each counted once even if the same movie is in two of them.
            var seen = Set<String>()
            return (groupMembers[item.id] ?? []).flatMap(records(under:)).filter { seen.insert($0.id).inserted }
        case .extra, .other: return []
        }
    }

    /// Where an item's downloads are, for what its menus offer. Reads only what changes when that does, not with progress,
    /// unlike ``status(of:)``, which the download button's ring needs.
    func stage(of item: MediaItem) -> DownloadStage {
        if item.kind == .collection || item.kind == .playlist {
            let stages = (groupMembers[item.id] ?? []).map(stage(of:))
            if stages.contains(.downloading) { return .downloading }
            if stages.contains(.paused) { return .paused }
            if !stages.isEmpty, stages.allSatisfy({ $0 == .downloaded }) { return .downloaded }
            return stages.contains { $0 != .none } ? .partial : .none
        }
        guard [.movie, .episode, .season, .series].contains(item.kind), (summary.recordCounts[item.id] ?? 0) > 0 else { return .none }
        if summary.movingIDs.contains(item.id) { return .downloading }
        if summary.pausedIDs.contains(item.id) { return .paused }
        switch item.kind {
        case .season, .series:
            return (summary.recordCounts[item.id] ?? 0) >= (item.episodeCount ?? .max) ? .downloaded : .partial
        default:
            return .downloaded
        }
    }

    /// Whether a show or season has episodes that aren't downloading or downloaded yet, so it can offer to download the
    /// rest. False if the server hasn't said how many it has.
    func hasEpisodesToDownload(_ item: MediaItem) -> Bool {
        if item.kind == .collection || item.kind == .playlist {
            return (groupMembers[item.id] ?? []).contains { stage(of: $0) == .none || hasEpisodesToDownload($0) }
        }
        guard item.kind == .season || item.kind == .series, let total = item.episodeCount else { return false }
        return (summary.recordCounts[item.id] ?? 0) < total
    }

    func status(of item: MediaItem) -> DownloadStatus {
        let relevant = records(under: item)
        guard !relevant.isEmpty else { return .none }

        let moving = relevant.filter { $0.state.isInProgress }
        if !moving.isEmpty {
            let progress = relevant.map { $0.isComplete ? 1 : $0.progress }.reduce(0, +) / Double(relevant.count)
            return .downloading(progress: progress)
        }
        if relevant.contains(where: { $0.state.isStalled }) { return .paused }

        switch item.kind {
        case .season, .series:
            return relevant.count >= (item.episodeCount ?? .max) ? .downloaded : .partial
        case .collection, .playlist:
            return isDownloaded(item) ? .downloaded : .partial
        default:
            return .downloaded
        }
    }

    /// The item with its saved artwork, for showing a download without the server.
    func localized(_ item: MediaItem) -> MediaItem { store.localized(item) }

    /// Space the finished downloads take, in bytes.
    var totalBytes: Int64 { records.reduce(0) { $0 + $1.fileSize } }
}
