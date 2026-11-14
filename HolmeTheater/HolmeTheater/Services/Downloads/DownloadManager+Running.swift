// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import OSLog
#if os(iOS)
import ActivityKit
#endif
#if os(tvOS)
import UIKit
#endif

// Starting, pausing and running transfers, saving an item's details before its file, handling the background session's
// events, and the Live Activity that reports on a batch.

extension DownloadManager {
    // MARK: - Resuming interrupted work

    /// Downloads left running or waiting when the app last closed carry on, or start again if the system dropped them.
    func resumeInterrupted() async {
        let running = Set(await session.allTasks.compactMap(\.taskDescription))
        for record in records {
            // A transfer started before keys had the account in them is described by the bare item ID.
            let isRunning = running.contains(taskKey(record.id)) || running.contains(record.id)
            switch record.state {
            case .preparing:
                store.update(record.id) { $0.state = .queued }
            case .downloading where !isRunning:
                store.update(record.id) { $0.state = .queued }
            default:
                break
            }
        }
        refresh()
        batch = Set(records.filter { $0.state.isInProgress }.map(\.id))
        pump()
    }

    // MARK: - Starting

    /// Downloads a movie or episode, or every episode of a show or season. Anything already downloaded or on its way is
    /// left alone, and a failed or paused one starts again.
    func download(_ item: MediaItem) async {
        let scope = scope
        guard !scope.isEmpty else { return }
        do {
            let playable = try await playableItems(of: item)
            // Signed out or switched accounts while the list came: it isn't the new account's to download.
            guard scope == self.scope else { return }
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
            guard scope == self.scope else { return }
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
        case .collection, .playlist:
            // Everything in it, which for a collection can be whole shows. Remembered, so its state can be shown.
            let members = try await service.children(of: item)
            register(members, asMembersOf: item)
            var seen = Set<String>()
            var playable: [MediaItem] = []
            for member in members {
                for entry in try await playableItems(of: member) where seen.insert(entry.id).inserted {
                    playable.append(entry)
                }
            }
            return playable
        case .extra, .other:
            return []
        }
    }

    // MARK: - Controlling

    /// Pauses what's downloading or waiting under an item (or for every download, with nil).
    func pause(_ item: MediaItem? = nil) {
        let ids = ids(under: item).filter { id in record(for: id).map { $0.state.isInProgress } ?? false }
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

    /// Deletes downloads under an item, whatever state they're in, finished ones included.
    func remove(_ item: MediaItem) {
        remove(ids: ids(under: item))
    }

    /// Stops and deletes what under an item isn't downloaded yet, and keeps what is. For a movie or episode, the same as
    /// ``remove(_:)``; for a show or season, its finished episodes stay.
    func cancel(_ item: MediaItem) {
        remove(ids: records(under: item).filter { !$0.isComplete }.map(\.id))
    }

    func remove(ids: [String]) {
        for id in ids {
            preparations[id]?.cancel()
            preparations[id] = nil
            batch.remove(id)
        }
        // Bare IDs too, for transfers started before keys had the account in them.
        let idSet = Set(ids.map(taskKey)).union(ids)
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

        let store = store
        let key = taskKey(id)
        let descriptions: Set<String> = [key, id]
        session.getAllTasks { tasks in
            for case let task as URLSessionDownloadTask in tasks where task.taskDescription.map(descriptions.contains) == true {
                // What's arrived so far is kept, so resuming carries on instead of starting again. Not if the download
                // was removed before this arrived, which the store checks.
                let request = task.originalRequest
                task.cancel { data in
                    guard let data else { return }
                    store.saveResumeData(data, key: key, request: request)
                }
            }
        }
    }

    // MARK: - Running

    /// Starts waiting downloads, up to the limit.
    func pump() {
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
        let key = taskKey(id)
        preparations[id] = Task { [weak self] in
            await self?.prepare(key: key)
            // Unless the account changed meanwhile, and the entry is another account's.
            if self?.taskKey(id) == key { self?.preparations[id] = nil }
        }
    }

    /// Whether a download is still waiting for its transfer to start: not paused or removed while it was being prepared.
    private func isStillPreparing(_ key: String) -> Bool {
        !Task.isCancelled && store.record(key: key)?.state == .preparing
    }

    /// Saves everything about an item, then starts its file coming.
    ///
    /// Works by key rather than item ID throughout, so nothing it does lands on another account's record if the account
    /// changes while it waits on the server.
    private func prepare(key: String) async {
        guard let id = store.record(key: key)?.id else { return }
        do {
            let directory = try store.makeItemDirectory(key: key)

            // A download that was paused or interrupted carries on from where it got to, if it was this session that
            // started it: the saved request has the token in it. Checked before the saved progress is used up, so a pause
            // that came first keeps it for later.
            if store.record(key: key)?.info != nil {
                guard isStillPreparing(key) else { return }
                if let data = store.takeResumeData(key: key, tokenFingerprint: tokenFingerprint) {
                    begin(session.downloadTask(withResumeData: data), key: key)
                    return
                }
            }

            let full = try await service.item(id: id)
            try Task.checkCancellation()

            // The full item goes in first, before its cast and artwork are saved. Until then the record holds the
            // listing's item, with no cast or chapters, and removing another download would prune them as unused.
            store.update(key: key) { record in
                // Progress made offline since this was queued is the newer.
                var item = full
                item.playedFraction = record.item.playedFraction ?? full.playedFraction
                record.item = item
            }

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

            // The token goes in a header rather than the URL, out of the server's logs.
            let request = await service.authorizedRequest(for: info.url)

            // The URLs aren't needed once the files are saved: those stand in for them when it plays (see
            // `DownloadStore.localPlayback`).
            var stored = info
            stored.url = URL(filePath: "/")
            stored.subtitleTracks = info.subtitleTracks.map { track in
                var track = track
                track.url = nil
                return track
            }
            guard isStillPreparing(key) else { return }
            store.update(key: key) { record in
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
            begin(session.downloadTask(with: request), key: key)
        } catch {
            // Paused, removed or the account changed, and whoever did it has already set the state. A cancelled request
            // doesn't always say so (the service reports it as the server being unreachable), so the error isn't trusted.
            guard isStillPreparing(key) else { return }
            fail(key: key, error.localizedDescription)
        }
    }

    /// Starts a prepared download's transfer. Call only straight after `isStillPreparing`, with nothing awaited between.
    private func begin(_ task: URLSessionDownloadTask, key: String) {
        task.taskDescription = key
        store.update(key: key) { $0.state = .downloading }
        task.resume()
        refresh()
    }

    private func fail(key: String, _ message: String) {
        Self.logger.error("Download \(key, privacy: .private) failed: \(message, privacy: .public)")
        store.update(key: key) {
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
        let missing = Set(item.people.map(\.personID)).filter { store.personDetails(id: $0) == nil }
        await BoundedTaskGroup.forEach(Array(missing)) { personID in
            if let details = try? await service.details(ofPerson: personID) {
                store.savePersonDetails(details, id: personID)
            }
        }
    }

    /// Saves every image the items show: posters, backdrops, logos, cast portraits and chapter stills.
    private func saveArtwork(of items: [MediaItem]) async {
        let store = store
        let session = detailsSession
        let missing = Set(items.flatMap(DownloadStore.artworkURLs(of:))).filter { !store.hasArtwork(for: $0) }
        await BoundedTaskGroup.forEach(Array(missing)) { url in
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            store.saveArtwork(data, for: url)
        }
    }

    /// Saves the subtitle tracks the player draws itself. Returns each one's file name by track index.
    private func saveSubtitles(of info: PlaybackInfo, in directory: URL) async -> [Int: String] {
        var files: [Int: String] = [:]
        for track in info.subtitleTracks {
            guard let url = track.url,
                  let (data, response) = try? await detailsSession.data(for: service.authorizedRequest(for: url)),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
            let name = DownloadFileNaming.subtitleFileName(trackIndex: track.index, format: track.format)
            if (try? data.write(to: directory.appending(path: name), options: .atomic)) != nil {
                files[track.index] = name
            }
        }
        return files
    }

    // MARK: - Session events

    func handle(_ event: DownloadSessionDelegate.Event) {
        switch event {
        case let .progress(key, written, expected):
            store.update(key: key, persist: false) {
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
        case let .interrupted(key):
            // The system cancelled it, not the user, so it goes back in line; what had arrived was kept as resume data.
            store.update(key: key) { if $0.state == .downloading { $0.state = .queued } }
            refresh()
            pump()
        case let .failed(key, message):
            fail(key: key, message)
        }
    }

    // MARK: - Live Activity

    /// Shows the progress of the batch in a Live Activity, and ends it when the batch is over.
    func updateActivity(force: Bool) {
        #if os(tvOS)
        // An Apple TV that goes to sleep stops downloading, so keep it awake while there's something to fetch.
        UIApplication.shared.isIdleTimerDisabled = records.contains { $0.state.isInProgress }
        #endif
        #if os(iOS)
        let members = records.filter { batch.contains($0.id) }
        guard let progress = DownloadBatchProgress(members: members) else {
            endActivity()
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if !force, Date.now.timeIntervalSince(lastActivityUpdate) < 1 { return }

        let state = DownloadActivityAttributes.ContentState(
            title: progress.title,
            subtitle: progress.subtitle,
            completed: progress.completed,
            total: progress.total,
            fraction: progress.fraction,
            isPaused: progress.isPaused,
            isFinished: progress.isFinished
        )
        // Nothing the activity shows has changed, so there's nothing to send.
        if state == lastActivityState { return }
        lastActivityState = state
        lastActivityUpdate = .now
        let content = ActivityContent(state: state, staleDate: nil)

        if progress.isFinished {
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
        // Already taken down, or finishing (which the updater leaves to finish).
        guard hasActivity else { return }
        hasActivity = false
        lastActivityState = nil
        activityUpdater.submit(.end(nil, .immediate))
        #endif
    }
}
