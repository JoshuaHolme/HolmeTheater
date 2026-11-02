// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Network

/// Whether the device has a network at all, so offline screens can go straight to what's saved instead of waiting
/// for a request to time out.
nonisolated final class NetworkMonitor: @unchecked Sendable {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var online = true

    /// False only when the system says there's no route out. A server that's down still counts as online.
    var isOnline: Bool { lock.withLock { online } }

    /// Called when the network comes back after being gone. Set once, by the download manager.
    var onReconnect: (@Sendable () -> Void)? {
        get { lock.withLock { reconnectHandler } }
        set { lock.withLock { reconnectHandler = newValue } }
    }
    private var reconnectHandler: (@Sendable () -> Void)?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let wasOnline = lock.withLock { () -> Bool in
                defer { online = path.status == .satisfied }
                return online
            }
            if !wasOnline, path.status == .satisfied { onReconnect?() }
        }
        monitor.start(queue: DispatchQueue(label: "NetworkMonitor", qos: .utility))
    }
}

/// A ``MediaService`` that answers from downloads when the server can't, and plays a download from its file even when
/// it can.
///
/// Everything else goes to `base`. Because the detail screens, the player and the cast pages already talk to the
/// service, wrapping it is all it takes for a downloaded item to look the same offline as online.
nonisolated struct OfflineFallbackMediaService: MediaService {
    let base: any MediaService
    let store: DownloadStore

    /// Runs `call` against the server, or `offline` when there's no network or the call fails. If there's nothing saved
    /// for it, the server's error is passed on.
    private func serving<T>(_ call: () async throws -> T, offline: () -> T?) async throws -> T {
        if !NetworkMonitor.shared.isOnline, let local = offline() { return local }
        do {
            return try await call()
        } catch {
            if error is CancellationError { throw error }
            if let local = offline() { return local }
            throw error
        }
    }

    // MARK: Connection & auth

    func connect(to address: String) async throws -> ServerInfo { try await base.connect(to: address) }

    func serverBranding() async -> ServerBranding? { await base.serverBranding() }

    func signIn(username: String, password: String) async throws -> UserSession {
        try await base.signIn(username: username, password: password)
    }

    func quickConnect() -> AsyncThrowingStream<QuickConnectEvent, Error> { base.quickConnect() }

    func authorizeQuickConnect(code: String) async throws { try await base.authorizeQuickConnect(code: code) }

    func restore(_ session: UserSession) async { await base.restore(session) }

    func signOut() async { await base.signOut() }

    func refreshProfile() async throws -> UserSession { try await base.refreshProfile() }

    // MARK: Browsing

    func libraries() async throws -> [Library] { try await base.libraries() }

    func items(in library: Library) async throws -> [MediaItem] { try await base.items(in: library) }

    func resumeItems(offset: Int, limit: Int, libraryIDs: [String]?) async throws -> [MediaItem] {
        try await base.resumeItems(offset: offset, limit: limit, libraryIDs: libraryIDs)
    }

    func nextUpItems(offset: Int, limit: Int, libraryIDs: [String]?) async throws -> [MediaItem] {
        try await base.nextUpItems(offset: offset, limit: limit, libraryIDs: libraryIDs)
    }

    func recentlyAddedItems(in library: Library) async throws -> [MediaItem] {
        try await base.recentlyAddedItems(in: library)
    }

    func recentlyAddedPage(in library: Library, offset: Int, limit: Int) async throws -> [MediaItem] {
        try await base.recentlyAddedPage(in: library, offset: offset, limit: limit)
    }

    func randomItems(in library: Library, limit: Int) async throws -> [MediaItem] {
        try await base.randomItems(in: library, limit: limit)
    }

    func recentlyReleasedPage(in library: Library, offset: Int, limit: Int) async throws -> [MediaItem] {
        try await base.recentlyReleasedPage(in: library, offset: offset, limit: limit)
    }

    func itemsOnThisDay(libraryIDs: [String]?) async throws -> [MediaItem] { try await base.itemsOnThisDay(libraryIDs: libraryIDs) }

    func items(withIDs ids: [String]) async throws -> [MediaItem] {
        try await serving {
            try await base.items(withIDs: ids)
        } offline: {
            ids.compactMap { store.localAnyItem(id: $0) }
        }
    }

    func item(id: String) async throws -> MediaItem {
        try await serving {
            try await base.item(id: id)
        } offline: {
            store.offlineItem(id: id)
        }
    }

    func similarItems(to item: MediaItem) async throws -> [MediaItem] {
        guard NetworkMonitor.shared.isOnline else { return [] }
        return try await base.similarItems(to: item)
    }

    func specialFeatures(of item: MediaItem) async throws -> [MediaItem] {
        guard NetworkMonitor.shared.isOnline else { return [] }
        return try await base.specialFeatures(of: item)
    }

    func children(of item: MediaItem) async throws -> [MediaItem] {
        try await serving {
            try await base.children(of: item)
        } offline: {
            store.offlineChildren(of: item)
        }
    }

    func items(featuring personID: String) async throws -> [PersonCredit] {
        try await serving {
            try await base.items(featuring: personID)
        } offline: {
            store.offlineCredits(for: personID)
        }
    }

    func details(ofPerson personID: String) async throws -> PersonDetails {
        try await serving {
            try await base.details(ofPerson: personID)
        } offline: {
            store.personDetails(id: personID)
        }
    }

    func seasonCount(ofSeries id: String) async throws -> Int? {
        try await serving {
            try await base.seasonCount(ofSeries: id)
        } offline: {
            store.offlineItem(id: id).map(\.seasonCount)
        }
    }

    func setFavorite(_ isFavorite: Bool, itemID: String) async throws {
        try await base.setFavorite(isFavorite, itemID: itemID)
    }

    func nextEpisode(in series: MediaItem) async throws -> MediaItem? {
        try await serving {
            try await base.nextEpisode(in: series)
        } offline: {
            .some(store.offlineNextEpisode(in: series))
        }
    }

    func search(_ query: String) async throws -> [MediaItem] { try await base.search(query) }

    func genres() async throws -> [Genre] { try await base.genres() }

    func items(in genre: Genre) async throws -> [MediaItem] { try await base.items(in: genre) }

    // MARK: Playback

    func playbackInfo(for item: MediaItem, options: PlaybackOptions) async throws -> PlaybackInfo {
        // A downloaded item plays from its file. A request for a particular stream (a quality or track change) is for
        // the server, though.
        if options == PlaybackOptions(), let local = store.localPlayback(for: item.id, resumeFrom: item) {
            return local
        }
        return try await base.playbackInfo(for: item, options: options)
    }

    func downloadInfo(for item: MediaItem) async throws -> PlaybackInfo {
        try await base.downloadInfo(for: item)
    }

    func segments(for item: MediaItem) async -> [MediaSegment] {
        if let record = store.record(id: item.id), record.isComplete { return record.segments }
        return await base.segments(for: item)
    }

    func report(_ event: PlaybackEvent, for item: MediaItem, info: PlaybackInfo, position: TimeInterval, isPaused: Bool) async {
        // Keep the downloaded copy's progress, so it resumes where it left off even if the server can't be told.
        if info.url.isFileURL, event != .started {
            store.updateProgress(id: item.id, position: position, persist: event == .stopped)
        }
        await base.report(event, for: item, info: info, position: position, isPaused: isPaused)
    }

    // MARK: Watch state

    func markWatched(itemID: String) async throws {
        try await base.markWatched(itemID: itemID)
        store.setPlayed(true, under: itemID)
    }

    func markUnwatched(itemID: String) async throws {
        try await base.markUnwatched(itemID: itemID)
        store.setPlayed(false, under: itemID)
    }

    func syncProgress(itemID: String, position: TimeInterval, isPlayed: Bool, date: Date) async throws {
        try await base.syncProgress(itemID: itemID, position: position, isPlayed: isPlayed, date: date)
    }

    func removeFromContinueWatching(_ item: MediaItem) async throws {
        try await base.removeFromContinueWatching(item)
        store.update(item.id) { $0.item.playedFraction = nil }
    }
}

// MARK: - Reading saved shows and seasons

nonisolated extension DownloadStore {
    /// The completed downloads of a show or season's episodes.
    func episodes(ofSeries seriesID: String? = nil, season seasonID: String? = nil) -> [DownloadRecord] {
        records
            .filter { $0.isComplete && $0.item.kind == .episode }
            .filter { seriesID == nil || $0.item.seriesID == seriesID }
            .filter { seasonID == nil || $0.item.seasonID == seasonID }
            .sorted(by: DownloadRecord.episodeOrder)
    }

    /// A downloaded movie or episode, or a show or season holding downloaded episodes, as it should read offline: with
    /// only the downloaded part of it counted.
    func offlineItem(id: String) -> MediaItem? {
        if let item = localItem(id: id) { return item }
        guard var container = container(id: id).map(localized) else { return nil }
        switch container.kind {
        case .season:
            let episodes = episodes(season: id)
            container.episodeCount = episodes.count
            container.unwatchedEpisodeCount = episodes.filter { !$0.item.isPlayed }.count
        case .series:
            let episodes = episodes(ofSeries: id)
            container.episodeCount = episodes.count
            container.unwatchedEpisodeCount = episodes.filter { !$0.item.isPlayed }.count
            container.seasonCount = Set(episodes.compactMap(\.item.seasonID)).count
        default:
            break
        }
        return container
    }

    /// The seasons of a show, or episodes of a season, that are downloaded.
    func offlineChildren(of item: MediaItem) -> [MediaItem]? {
        switch item.kind {
        case .series:
            let seasonIDs = Set(episodes(ofSeries: item.id).compactMap(\.item.seasonID))
            let seasons = seasonIDs.compactMap { offlineItem(id: $0) }
            return seasons.isEmpty ? nil : seasons.sorted { ($0.episodeNumber ?? 0) < ($1.episodeNumber ?? 0) }
        case .season:
            let episodes = episodes(season: item.id).map { localized($0.item) }
            return episodes.isEmpty ? nil : episodes
        default:
            return nil
        }
    }

    /// The downloaded episode a show's Play button should start: one that's partly watched, else the first not yet
    /// watched, else the first.
    func offlineNextEpisode(in series: MediaItem) -> MediaItem? {
        let episodes = episodes(ofSeries: series.id).map { localized($0.item) }
        return episodes.first { $0.playedFraction != nil } ?? episodes.first { !$0.isPlayed } ?? episodes.first
    }

    /// Downloaded movies and shows a person is in, with what they did on each.
    func offlineCredits(for personID: String) -> [PersonCredit]? {
        var credits: [PersonCredit] = []
        for record in records where record.isComplete && record.item.kind == .movie {
            let roles = record.item.people.filter { $0.personID == personID }
            if !roles.isEmpty { credits.append(PersonCredit(item: localized(record.item), roles: roles)) }
        }
        for series in containers where series.kind == .series {
            let roles = episodes(ofSeries: series.id).lazy
                .map { $0.item.people.filter { $0.personID == personID } }
                .first { !$0.isEmpty }
            if let roles, let item = offlineItem(id: series.id) { credits.append(PersonCredit(item: item, roles: roles)) }
        }
        credits.sort { $0.item.title.localizedStandardCompare($1.item.title) == .orderedAscending }
        return credits.isEmpty ? nil : credits
    }

    /// Mirrors a watched or unwatched change the server accepted onto the downloads it covers.
    func setPlayed(_ isPlayed: Bool, under itemID: String) {
        for record in records where record.id == itemID || record.item.seasonID == itemID || record.item.seriesID == itemID {
            update(record.id) {
                $0.item.isPlayed = isPlayed
                $0.item.playedFraction = nil
            }
        }
    }
}

nonisolated extension DownloadRecord {
    /// Season by season, episode by episode.
    static func episodeOrder(_ a: DownloadRecord, _ b: DownloadRecord) -> Bool {
        let (sa, sb) = (a.item.seasonNumber ?? 0, b.item.seasonNumber ?? 0)
        if sa != sb { return sa < sb }
        return (a.item.episodeNumber ?? 0) < (b.item.episodeNumber ?? 0)
    }
}
