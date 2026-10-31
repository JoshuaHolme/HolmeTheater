// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation
import OSLog
#if os(iOS)
import ActivityKit
#endif
#if os(tvOS)
import UIKit
#endif

/// How the downloads under an item are doing, for its download button.
enum DownloadStatus: Equatable {
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

/// Downloads movies and episodes for offline viewing, and keeps track of them.
///
/// The files come through a background `URLSession`, so they carry on when the app is closed or suspended. Before each
/// file, the item's details, cast and bios, artwork, subtitles and skip markers are saved too, so it can be shown and
/// played with no server (see ``OfflineFallbackMediaService``).
///
/// Only the signed-in account's downloads are visible (see ``accountChanged(scope:)``).
@Observable
final class DownloadManager {
    /// The background session's identifier, which the system uses to wake the app when downloads finish.
    static let sessionIdentifier = (Bundle.main.bundleIdentifier ?? "NativeFin") + ".downloads"

    /// How many downloads run at once. Each is a whole movie or episode, so more would only slow each down.
    private static let maxConcurrent = 2

    private nonisolated static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NativeFin", category: "Downloads")

    /// The account's downloads in every state, oldest first. Changes with every tick of progress, so views that only
    /// care whether something is downloaded read ``completedIDs`` instead.
    private(set) var records: [DownloadRecord] = []

    /// The IDs of movies and episodes that are fully downloaded. Only changes when that does.
    private(set) var completedIDs: Set<String> = []

    /// Set when something couldn't be started, to show in an alert. The owner clears it.
    var errorMessage: String?

    @ObservationIgnored let store: DownloadStore

    /// The server itself, not the offline-aware wrapper: a download has to come from the server.
    @ObservationIgnored private let service: any MediaService
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var scope = ""

    /// Items being prepared (details, artwork, the file's URL), by ID, so they can be cancelled.
    @ObservationIgnored private var preparations: [String: Task<Void, Never>] = [:]

    /// The items downloaded together, which the Live Activity reports on as one. Emptied when they're all done.
    @ObservationIgnored private var batch: Set<String> = []

    @ObservationIgnored private let backgroundEvents = BackgroundEvents()

    #if os(iOS)
    /// Whether a Live Activity is showing downloads in progress.
    @ObservationIgnored private var hasActivity = false
    @ObservationIgnored private let activityUpdater = LiveActivityUpdater()

    /// What the activity was last told to show, so an update that wouldn't change it isn't sent.
    @ObservationIgnored private var lastActivityState: DownloadActivityAttributes.ContentState?
    @ObservationIgnored private var lastActivityUpdate = Date.distantPast
    #endif

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

    @ObservationIgnored private var isSyncing = false

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
    func accountChanged(scope newScope: String) {
        guard newScope != scope else { return }
        scope = newScope
        batch = []
        refresh()
        guard !newScope.isEmpty else { return }
        verifyFiles()
        Task {
            await resumeInterrupted()
            await syncProgress()
        }
    }

    /// Marks finished downloads whose video the system has removed (to free up space) as failed, so they show as needing a
    /// new download rather than as playable.
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

    /// Downloads left running or waiting when the app last closed carry on, or start again if the system dropped them.
    private func resumeInterrupted() async {
        let running = Set(await session.allTasks.compactMap(\.taskDescription))
        for record in records {
            switch record.state {
            case .preparing:
                store.update(record.id) { $0.state = .queued }
            case .downloading where !running.contains(record.id):
                store.update(record.id) { $0.state = .queued }
            default:
                break
            }
        }
        refresh()
        batch = Set(records.filter { Self.isInProgress($0.state) }.map(\.id))
        pump()
    }

    /// Deletes every download, e.g. on sign-out, so the next person on the device doesn't see them.
    func removeAll() {
        for task in preparations.values { task.cancel() }
        preparations = [:]
        session.getAllTasks { $0.forEach { $0.cancel() } }
        store.removeAll()
        batch = []
        refresh()
        endActivity()
    }

    /// Lets the system's background-session wake-up finish once this app has been told about every finished download.
    func waitForBackgroundEvents() async {
        await backgroundEvents.wait()
    }

    // MARK: - Reading

    private static func isInProgress(_ state: DownloadState) -> Bool {
        state == .queued || state == .preparing || state == .downloading
    }

    func record(for id: String) -> DownloadRecord? { records.first { $0.id == id } }

    /// Whether a movie or episode is fully downloaded. For a show or season, whether every episode is.
    func isDownloaded(_ item: MediaItem) -> Bool {
        switch item.kind {
        case .movie, .episode:
            return completedIDs.contains(item.id)
        case .season, .series:
            return status(of: item) == .downloaded
        case .extra, .other:
            return false
        }
    }

    /// The downloads an item stands for: itself, or the episodes of a show or season.
    private func records(under item: MediaItem) -> [DownloadRecord] {
        switch item.kind {
        case .movie, .episode: records.filter { $0.id == item.id }
        case .season: records.filter { $0.item.seasonID == item.id }
        case .series: records.filter { $0.item.seriesID == item.id }
        case .extra, .other: []
        }
    }

    func status(of item: MediaItem) -> DownloadStatus {
        let relevant = records(under: item)
        guard !relevant.isEmpty else { return .none }

        let moving = relevant.filter { Self.isInProgress($0.state) }
        if !moving.isEmpty {
            let progress = relevant.map { $0.isComplete ? 1 : $0.progress }.reduce(0, +) / Double(relevant.count)
            return .downloading(progress: progress)
        }
        if relevant.contains(where: { $0.state == .paused || $0.state == .failed }) { return .paused }

        switch item.kind {
        case .season, .series:
            return relevant.count >= (item.episodeCount ?? .max) ? .downloaded : .partial
        default:
            return .downloaded
        }
    }

    /// The item with its saved artwork, for showing a download without the server.
    func localized(_ item: MediaItem) -> MediaItem { store.localized(item) }

    /// How many downloads are downloading or waiting to. Paused and failed ones aren't counted, since nothing is moving.
    var activeCount: Int { records.filter { Self.isInProgress($0.state) }.count }

    /// Space the finished downloads take, in bytes.
    var totalBytes: Int64 { records.reduce(0) { $0 + $1.fileSize } }

    // MARK: - Starting

    /// Downloads a movie or episode, or every episode of a show or season. Anything already downloaded or on its way is
    /// left alone, and a failed or paused one starts again.
    func download(_ item: MediaItem) async {
        guard !scope.isEmpty else { return }
        do {
            let playable = try await playableItems(of: item)
            var added = 0
            for entry in playable {
                if let existing = store.record(id: entry.id) {
                    guard existing.state == .failed || existing.state == .paused else { continue }
                    store.update(entry.id) {
                        $0.state = .queued
                        $0.errorMessage = nil
                    }
                } else {
                    store.save(DownloadRecord(item: entry, scope: scope, state: .queued))
                }
                batch.insert(entry.id)
                added += 1
            }
            refresh()
            pump()
            if added == 0 { updateActivity(force: true) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The movies and episodes an item covers.
    private func playableItems(of item: MediaItem) async throws -> [MediaItem] {
        switch item.kind {
        case .movie, .episode:
            return [item]
        case .season:
            return try await service.children(of: item).filter { $0.kind == .episode }
        case .series:
            let top = try await service.children(of: item)
            // A show can list its episodes directly.
            if top.first?.kind == .episode { return top }
            var episodes: [MediaItem] = []
            for season in top where season.kind == .season {
                episodes += try await service.children(of: season).filter { $0.kind == .episode }
            }
            return episodes
        case .extra, .other:
            return []
        }
    }

    // MARK: - Controlling

    /// Pauses what's downloading or waiting under an item (or for every download, with nil).
    func pause(_ item: MediaItem? = nil) {
        let ids = ids(under: item).filter { id in record(for: id).map { Self.isInProgress($0.state) } ?? false }
        for id in ids { pauseOne(id) }
        refresh()
        updateActivity(force: true)
        pump()
    }

    /// Carries on with what's paused or failed under an item (or all of it, with nil).
    func resume(_ item: MediaItem? = nil) {
        for id in ids(under: item) {
            guard let record = record(for: id), record.state == .paused || record.state == .failed else { continue }
            store.update(id) {
                $0.state = .queued
                $0.errorMessage = nil
            }
            batch.insert(id)
        }
        refresh()
        pump()
    }

    /// Deletes downloads under an item, whatever state they're in.
    func remove(_ item: MediaItem) {
        remove(ids: ids(under: item))
    }

    func remove(ids: [String]) {
        for id in ids {
            preparations[id]?.cancel()
            preparations[id] = nil
            batch.remove(id)
        }
        let idSet = Set(ids)
        session.getAllTasks { tasks in
            for task in tasks where task.taskDescription.map(idSet.contains) == true { task.cancel() }
        }
        store.remove(ids: ids)
        refresh()
        updateActivity(force: true)
        pump()
    }

    private func ids(under item: MediaItem?) -> [String] {
        guard let item else { return records.map(\.id) }
        return records(under: item).map(\.id)
    }

    private func pauseOne(_ id: String) {
        // Marked first, so the transfer ending isn't taken for a failure.
        store.update(id) { $0.state = .paused }
        preparations[id]?.cancel()
        preparations[id] = nil

        let directory = store.itemDirectory(for: id)
        session.getAllTasks { tasks in
            for case let task as URLSessionDownloadTask in tasks where task.taskDescription == id {
                // What's arrived so far is kept, so resuming carries on instead of starting again.
                task.cancel { data in
                    guard let data else { return }
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try? data.write(to: directory.appending(path: DownloadSessionDelegate.resumeFileName))
                }
            }
        }
    }

    // MARK: - Running

    private func refresh() {
        let current = store.records.filter { $0.scope == scope }.sorted { $0.dateAdded < $1.dateAdded }
        records = current
        let done = Set(current.filter(\.isComplete).map(\.id))
        if done != completedIDs { completedIDs = done }
    }

    /// Starts waiting downloads, up to the limit.
    private func pump() {
        let running = records.filter { $0.state == .preparing || $0.state == .downloading }.count
        var free = Self.maxConcurrent - running
        for record in records where record.state == .queued {
            guard free > 0 else { break }
            free -= 1
            start(record.id)
        }
        updateActivity(force: true)
    }

    private func start(_ id: String) {
        store.update(id) { $0.state = .preparing }
        refresh()
        preparations[id] = Task { [weak self] in
            await self?.prepare(id)
            self?.preparations[id] = nil
        }
    }

    /// Saves everything about an item, then starts its file coming.
    private func prepare(_ id: String) async {
        guard store.record(id: id) != nil else { return }
        do {
            let directory = try store.makeItemDirectory(for: id)

            // A download that was paused or interrupted carries on from where it got to.
            let resumeFile = directory.appending(path: DownloadSessionDelegate.resumeFileName)
            if let data = try? Data(contentsOf: resumeFile), store.record(id: id)?.info != nil {
                try? FileManager.default.removeItem(at: resumeFile)
                begin(session.downloadTask(withResumeData: data), id: id)
                return
            }

            let full = try await service.item(id: id)
            try Task.checkCancellation()

            // The show and season, so the episode sits under them like it does in the library.
            var containers: [MediaItem] = []
            for containerID in [full.seriesID, full.seasonID].compactMap({ $0 }) {
                if let saved = store.container(id: containerID) {
                    containers.append(saved)
                } else if let fetched = try? await service.item(id: containerID) {
                    store.saveContainer(fetched)
                    containers.append(fetched)
                }
            }

            let info = try await service.downloadInfo(for: full)
            let segments = await service.segments(for: full)
            try Task.checkCancellation()

            await savePeople(of: full)
            await saveArtwork(of: [full] + containers)
            let subtitleFiles = await saveSubtitles(of: info, in: directory)
            try Task.checkCancellation()

            // The URL holds the access token, which has no business on disk.
            var stored = info
            stored.url = URL(filePath: "/")
            store.update(id) { record in
                // Progress made offline since this was queued is the newer.
                var item = full
                item.playedFraction = record.item.playedFraction ?? full.playedFraction
                record.item = item
                record.info = stored
                // Until the transfer says how big it is, the size the server gave for the file stands in.
                if record.bytesExpected == 0 || record.isSizeEstimated {
                    record.bytesExpected = info.expectedBytes ?? 0
                    record.isSizeEstimated = true
                }
                record.segments = segments
                record.subtitleFiles = subtitleFiles
                record.errorMessage = nil
            }
            begin(session.downloadTask(with: info.url), id: id)
        } catch is CancellationError {
            // Paused or removed; whoever did it has already set the state.
        } catch {
            fail(id, error.localizedDescription)
        }
    }

    private func begin(_ task: URLSessionDownloadTask, id: String) {
        task.taskDescription = id
        store.update(id) { $0.state = .downloading }
        task.resume()
        refresh()
    }

    private func fail(_ id: String, _ message: String) {
        Self.logger.error("Download of \(id, privacy: .public) failed: \(message, privacy: .public)")
        store.update(id) {
            $0.state = .failed
            $0.errorMessage = message
        }
        refresh()
        pump()
    }

    // MARK: - Saving details

    /// Saves what the server knows about everyone in the item's cast and crew, for the pages behind their names.
    private func savePeople(of item: MediaItem) async {
        let store = store
        let service = service
        let missing = Dictionary(grouping: item.people, by: \.personID).keys.filter { store.personDetails(id: $0) == nil }
        for start in stride(from: 0, to: missing.count, by: 6) {
            let chunk = Array(missing[start..<min(start + 6, missing.count)])
            await withTaskGroup(of: Void.self) { group in
                for personID in chunk {
                    group.addTask {
                        if let details = try? await service.details(ofPerson: personID) {
                            store.savePersonDetails(details, id: personID)
                        }
                    }
                }
            }
        }
    }

    /// Saves every image the items show: posters, backdrops, logos, cast portraits and chapter stills.
    private func saveArtwork(of items: [MediaItem]) async {
        let store = store
        let missing = Array(Set(items.flatMap(DownloadStore.artworkURLs(of:)))).filter { !store.hasArtwork(for: $0) }
        for start in stride(from: 0, to: missing.count, by: 6) {
            let chunk = Array(missing[start..<min(start + 6, missing.count)])
            await withTaskGroup(of: Void.self) { group in
                for url in chunk {
                    group.addTask {
                        guard let (data, response) = try? await URLSession.shared.data(from: url),
                              (response as? HTTPURLResponse)?.statusCode == 200 else { return }
                        store.saveArtwork(data, for: url)
                    }
                }
            }
        }
    }

    /// Saves the text subtitle tracks, which the player draws itself. Returns each one's file name by track index.
    private func saveSubtitles(of info: PlaybackInfo, in directory: URL) async -> [Int: String] {
        var files: [Int: String] = [:]
        for track in info.subtitleTracks {
            guard let url = track.url,
                  let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
            let name = "subtitles-\(track.index).vtt"
            if (try? data.write(to: directory.appending(path: name), options: .atomic)) != nil {
                files[track.index] = name
            }
        }
        return files
    }

    // MARK: - Session events

    fileprivate func handle(_ event: DownloadSessionDelegate.Event) {
        switch event {
        case let .progress(id, written, expected):
            store.update(id, persist: false) {
                $0.bytesWritten = written
                // The transfer's own figure, when it has one, beats the estimate.
                if expected > 0 {
                    $0.bytesExpected = expected
                    $0.isSizeEstimated = false
                }
            }
            refresh()
            updateActivity(force: false)
        case .finished, .cancelled:
            refresh()
            pump()
        case let .failed(id, message):
            fail(id, message)
        }
    }

    // MARK: - Live Activity

    /// Shows the progress of the batch in a Live Activity, and ends it when the batch is over.
    private func updateActivity(force: Bool) {
        #if os(tvOS)
        // An Apple TV that goes to sleep stops downloading, so keep it awake while there's something to fetch.
        UIApplication.shared.isIdleTimerDisabled = records.contains { Self.isInProgress($0.state) }
        #endif
        #if os(iOS)
        let members = records.filter { batch.contains($0.id) }
        guard !members.isEmpty else {
            endActivity()
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if !force, Date.now.timeIntervalSince(lastActivityUpdate) < 1 { return }

        let completed = members.filter(\.isComplete).count
        let moving = members.filter { Self.isInProgress($0.state) }
        let stalled = members.filter { $0.state == .paused || $0.state == .failed }
        let isFinished = moving.isEmpty && stalled.isEmpty
        // Whole percents, which is all the activity shows. Finer than that, every update would change nothing on screen
        // and still make the island animate.
        let fraction = ((members.map { $0.isComplete ? 1 : $0.progress }.reduce(0, +) / Double(members.count)) * 100).rounded() / 100

        let title: String
        var subtitle: String?
        if members.count == 1, let only = members.first {
            title = only.item.title
            subtitle = only.item.subtitle
        } else {
            title = String(localized: "\(members.count) Downloads")
            subtitle = String(localized: "\(completed) of \(members.count) finished")
        }
        let state = DownloadActivityAttributes.ContentState(
            title: title,
            subtitle: subtitle,
            completed: completed,
            total: members.count,
            fraction: fraction,
            isPaused: moving.isEmpty && !stalled.isEmpty,
            isFinished: isFinished
        )
        // Nothing the activity shows has changed, so there's nothing to send.
        if state == lastActivityState { return }
        lastActivityState = state
        lastActivityUpdate = .now
        let content = ActivityContent(state: state, staleDate: nil)

        if isFinished {
            hasActivity = false
            lastActivityState = nil
            batch = []
            // Left on screen a few seconds to say it's done.
            activityUpdater.submit(.end(content, .after(.now + 8)))
        } else {
            hasActivity = true
            activityUpdater.submit(.show(content))
        }
        #endif
    }

    /// Takes the Live Activity down, if there's one to take down.
    private func endActivity() {
        #if os(iOS)
        // One that's already finishing is left to do so.
        guard hasActivity else { return }
        hasActivity = false
        lastActivityState = nil
        activityUpdater.submit(.end(nil, .immediate))
        #endif
    }
}

#if os(iOS)
/// Sends changes to the downloads Live Activity one at a time, in order, and only ever the latest.
///
/// Each change used to go in a task of its own, and those finish in any order. An old percentage could arrive after a
/// newer one, so the display stepped back and forward, and two first updates could each start an activity, leaving two
/// on screen. Here a change replaces any that hasn't been sent yet, and one is sent only after the one before it is done.
nonisolated final class LiveActivityUpdater: @unchecked Sendable {
    typealias Content = ActivityContent<DownloadActivityAttributes.ContentState>

    enum Update {
        /// Update the activity, or start it if there isn't one.
        case show(Content)
        /// End it, leaving `content` (if any) on screen as the policy says.
        case end(Content?, ActivityUIDismissalPolicy)
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NativeFin", category: "LiveActivity")

    private let lock = NSLock()
    private var pending: Update?
    private var isSending = false

    /// Queues `update`, replacing one still waiting. Returns at once; the order calls are made in is the order they count in.
    func submit(_ update: Update) {
        let shouldStart = lock.withLock { () -> Bool in
            pending = update
            if isSending { return false }
            isSending = true
            return true
        }
        if shouldStart { Task.detached { await self.sendPending() } }
    }

    private func sendPending() async {
        while true {
            let next = lock.withLock { () -> Update? in
                let next = pending
                pending = nil
                if next == nil { isSending = false }
                return next
            }
            guard let next else { return }
            await send(next)
        }
    }

    // The activity is only ever handled in here, never passed between tasks, because it can't be sent safely.
    private func send(_ update: Update) async {
        switch update {
        case .show(let content):
            // There's at most one, which may be left from an earlier launch.
            if let existing = Activity<DownloadActivityAttributes>.activities.first {
                await existing.update(content)
                return
            }
            do {
                _ = try Activity.request(attributes: DownloadActivityAttributes(), content: content)
            } catch {
                Self.logger.error("Couldn't start the Live Activity: \(error.localizedDescription, privacy: .public)")
            }
        case .end(let content, let policy):
            for activity in Activity<DownloadActivityAttributes>.activities {
                await activity.end(content, dismissalPolicy: policy)
            }
        }
    }
}
#endif

/// Waits for the system to say a background session has told the app everything that happened while it was away.
nonisolated final class BackgroundEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func markFinished() { lock.withLock { finished = true } }

    /// Returns once events have been delivered, or after 30 seconds, which is as long as the system would allow.
    func wait() async {
        for _ in 0..<60 {
            if lock.withLock({ () -> Bool in
                defer { finished = false }
                return finished
            }) { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
}

/// Receives a background session's callbacks, which come on a queue of its own, and saves each finished file at once:
/// the system deletes it as soon as the callback returns.
nonisolated final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    /// What a transfer did.
    enum Event: Sendable {
        case progress(id: String, written: Int64, expected: Int64)
        case finished(id: String)
        case failed(id: String, message: String)
        /// Cancelled: paused or removed, which whoever did it has dealt with.
        case cancelled(id: String)
    }

    /// Where a paused or interrupted transfer's progress is kept, in the item's folder.
    static let resumeFileName = "resume.data"

    private let store: DownloadStore
    private let backgroundEvents: BackgroundEvents
    private let lock = NSLock()
    private var lastProgress: [String: Date] = [:]

    /// Set once, right after creating the session.
    var onEvent: (@Sendable (Event) -> Void)?

    init(store: DownloadStore, backgroundEvents: BackgroundEvents) {
        self.store = store
        self.backgroundEvents = backgroundEvents
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        // Many times a second otherwise, and each one redraws the screen.
        let isDue = lock.withLock { () -> Bool in
            let now = Date.now
            if let last = lastProgress[id], now.timeIntervalSince(last) < 0.25 { return false }
            lastProgress[id] = now
            return true
        }
        guard isDue else { return }
        onEvent?(.progress(id: id, written: totalBytesWritten, expected: totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription, store.record(id: id) != nil else { return }

        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            onEvent?(.failed(id: id, message: String(localized: "The server returned an error (\(http.statusCode)).")))
            return
        }
        do {
            let directory = try store.makeItemDirectory(for: id)
            let name = "video." + Self.fileExtension(of: downloadTask)
            let destination = directory.appending(path: name, directoryHint: .notDirectory)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            let size = (try? FileManager.default.attributesOfItem(atPath: destination.path(percentEncoded: false))[.size] as? Int64) ?? 0
            store.update(id) {
                $0.videoFileName = name
                $0.fileSize = size
                $0.bytesWritten = size
                $0.bytesExpected = size
                $0.state = .completed
                $0.errorMessage = nil
            }
            lock.withLock { lastProgress[id] = nil }
            onEvent?(.finished(id: id))
        } catch {
            onEvent?(.failed(id: id, message: error.localizedDescription))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription else { return }
        let nsError = error as NSError
        lock.withLock { lastProgress[id] = nil }

        // Wherever the transfer got to is kept, so trying again carries on from there.
        if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data, store.record(id: id) != nil,
           let directory = try? store.makeItemDirectory(for: id) {
            try? data.write(to: directory.appending(path: Self.resumeFileName))
        }

        // Paused or removed.
        let state = store.record(id: id)?.state
        if nsError.code == NSURLErrorCancelled || state == nil || state == .paused {
            onEvent?(.cancelled(id: id))
        } else {
            onEvent?(.failed(id: id, message: error.localizedDescription))
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        backgroundEvents.markFinished()
    }

    /// The file's extension, which the player needs to recognize what it is. The server's own name for it, if that's
    /// one it can play, otherwise MP4.
    private static func fileExtension(of task: URLSessionDownloadTask) -> String {
        let playable: Set<String> = ["mp4", "m4v", "mov"]
        let suggested = (task.response?.suggestedFilename as NSString?)?.pathExtension.lowercased() ?? ""
        return playable.contains(suggested) ? suggested : "mp4"
    }
}
