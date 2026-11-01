// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// What a successful watch-state change did to the items on screen, so a screen can show it at once instead of
/// waiting for a reload.
enum WatchEffect {
    /// A movie or episode was marked watched or unwatched (`isPlayed`; nil if that didn't change), which also
    /// cleared its resume position. `removed` says whether that took it off the list it's on.
    case item(id: String, isPlayed: Bool?, removed: Bool)

    /// A show or season was marked watched or unwatched as a whole.
    case container(id: String, isPlayed: Bool)

    /// Every episode of a show was marked, which takes the show off Up Next.
    case seriesRemoved(seriesID: String)
}

extension Array where Element == MediaItem {
    /// The items as they are after `effect`.
    func applying(_ effect: WatchEffect) -> [MediaItem] {
        switch effect {
        case let .item(id, isPlayed, removed):
            return compactMap { item in
                guard item.id == id else { return item }
                if removed { return nil }
                var item = item
                if let isPlayed { item.isPlayed = isPlayed }
                item.playedFraction = nil
                return item
            }
        case let .container(id, isPlayed):
            return map { item in
                guard item.id == id else { return item }
                var item = item
                item.isPlayed = isPlayed
                // Marked as a whole, either all its episodes are watched or none are.
                item.unwatchedEpisodeCount = isPlayed ? 0 : item.episodeCount
                item.playedFraction = nil
                return item
            }
        case let .seriesRemoved(seriesID):
            return filter { $0.seriesID != seriesID }
        }
    }
}

/// A screen an item's menu can lead to besides its own.
enum RelatedLink {
    case season
    case show
}

/// How a screen opens and plays the items on it. The screen owns the navigation destination and the player,
/// so it can refresh when playback ends.
struct ItemNavigation {
    /// Opens an item's detail screen.
    private let openDetail: (MediaItem) -> Void

    /// Plays an item full-screen.
    let play: (MediaItem) -> Void

    init(open: @escaping (MediaItem) -> Void, play: @escaping (MediaItem) -> Void) {
        openDetail = open
        self.play = play
    }

    /// Opens an item's detail screen. A special feature has none, so it plays instead.
    func open(_ item: MediaItem) {
        if item.kind == .extra {
            play(item)
        } else {
            openDetail(item)
        }
    }

    /// What tapping an item does: plays it straight away, or opens it if it can't be played (a show or season).
    /// The detail screen is otherwise reached through "Go to …" or a peek.
    func tap(_ item: MediaItem) {
        if item.isPlayable {
            play(item)
        } else {
            open(item)
        }
    }
}

/// A screen's watch-state interaction in progress: a change waiting for confirmation, or an error to show.
struct WatchActionState {
    /// A show the user chose to remove from Up Next, waiting for their confirmation.
    var pendingRemoval: ShowRemoval?

    /// A whole show or season the user chose to mark watched or unwatched, waiting for their confirmation.
    var pendingBulkChange: BulkWatchChange?

    /// Set when a change fails; shown in an alert.
    var errorMessage: String?

    /// A question about a download, waiting for an answer: whether to download a whole show or season, or to remove one.
    var downloadPrompt: DownloadPrompt?
}

/// How many seasons each show has, learned as screens load. A show with a single season is treated as a mini
/// series, with no season page, so a menu needs to know before it offers "Go to Season".
///
/// It's observable, so a menu built in a view's body is rebuilt when a count arrives.
@MainActor @Observable
final class SeasonCountCache {
    static let shared = SeasonCountCache()

    private var counts: [String: Int] = [:]

    /// The shows being fetched. Not observed: it changes while a menu is being built in a view's body, and no view
    /// shows it.
    @ObservationIgnored private var loading: Set<String> = []

    /// The show's season count, or nil if it isn't known yet.
    func count(ofSeries id: String) -> Int? { counts[id] }

    /// Remembers a count a screen already has.
    func record(_ count: Int?, ofSeries id: String) {
        if let count { counts[id] = count }
    }

    /// Fetches a show's count in the background if it isn't known and isn't already being fetched.
    func prefetch(seriesID id: String, service: any MediaService) {
        guard counts[id] == nil, !loading.contains(id) else { return }
        loading.insert(id)
        Task {
            if let count = try? await service.seasonCount(ofSeries: id) {
                counts[id] = count
            }
            loading.remove(id)
        }
    }
}

/// Builds the watch-state actions for the items on a screen, and runs them.
///
/// Every screen with item menus uses this, so a shelf, its full list and a detail screen offer the same
/// choices. A change runs on the server first, and `apply` is only called once it succeeds, so the screen
/// never disagrees with the server. Pair with `watchActionAlerts(_:)` for the confirmations and errors.
struct WatchActions {
    let service: any MediaService

    /// Where downloads are managed. With it, items' menus offer to download them.
    var downloads: DownloadManager? = nil

    /// The shelf the items are on, which decides which changes take an item off it. Nil anywhere else.
    let destination: ShelfDestination?

    let state: Binding<WatchActionState>

    /// Shows a change that the server accepted.
    let apply: (WatchEffect) -> Void

    /// The menu actions for an item: "Go to …" if `goTo` is given, then the watch-state actions. Nil if there
    /// are none (an item that can't be watched, with no `goTo`).
    func actions(for item: MediaItem, goTo: (() -> Void)? = nil) -> ItemRowActions? {
        var actions = watchStateActions(for: item, goTo: goTo)
        let downloadEntries = downloadEntries(for: item)
        if !downloadEntries.isEmpty {
            actions = actions ?? ItemRowActions()
            actions?.downloadEntries = downloadEntries
        }
        return actions
    }

    /// The download entries for an item's menu, for where its download is now: download, pause, resume, or remove.
    private func downloadEntries(for item: MediaItem) -> [ItemMenuEntry] {
        guard let downloads, [.movie, .episode, .season, .series].contains(item.kind) else { return [] }
        let isContainer = item.kind == .season || item.kind == .series
        let state = state

        func entry(_ id: ItemMenuEntry.ID, _ title: String, _ systemImage: String, _ perform: @escaping () -> Void) -> ItemMenuEntry {
            ItemMenuEntry(id: id, title: title, systemImage: systemImage, perform: perform)
        }
        let start = { state.wrappedValue.downloadPrompt = DownloadPrompt.start(item, downloads: downloads) }
        let confirmRemoval = { state.wrappedValue.downloadPrompt = .remove(item) }

        switch downloads.status(of: item) {
        case .none:
            return [entry(.download, isContainer ? String(localized: "Download All Episodes") : String(localized: "Download"), "arrow.down.circle", start)]
        case .partial:
            return [
                entry(.download, String(localized: "Download Remaining Episodes"), "arrow.down.circle", start),
                entry(.removeDownload, String(localized: "Remove Downloads"), "trash", confirmRemoval)
            ]
        case .downloading:
            return [
                entry(.pauseDownload, String(localized: "Pause Download"), "pause.circle") { downloads.pause(item) },
                // Only what's unfinished: a show's or season's finished episodes stay.
                entry(.removeDownload, String(localized: "Cancel Download"), "xmark.circle") { downloads.cancel(item) }
            ]
        case .paused:
            return [
                entry(.resumeDownload, String(localized: "Resume Download"), "play.circle") { downloads.resume(item) },
                entry(.removeDownload, String(localized: "Cancel Download"), "xmark.circle") { downloads.cancel(item) }
            ]
        case .downloaded:
            return [entry(.removeDownload, isContainer ? String(localized: "Remove Downloads") : String(localized: "Remove Download"), "trash", confirmRemoval)]
        }
    }

    /// The menu actions that change an item's watch state, with "Go to …" if `goTo` is given.
    private func watchStateActions(for item: MediaItem, goTo: (() -> Void)?) -> ItemRowActions? {
        if item.kind == .series || item.kind == .season {
            // A show or season marks all its episodes, after a confirmation.
            return ItemRowActions(
                goTo: goTo,
                markWatched: { state.wrappedValue.pendingBulkChange = BulkWatchChange(item: item, markWatched: true) },
                markUnwatched: { state.wrappedValue.pendingBulkChange = BulkWatchChange(item: item, markWatched: false) }
            )
        }
        guard item.isPlayable else { return goTo.map { ItemRowActions(goTo: $0) } }

        let id = item.id
        // Either change clears the resume position, so on Continue Watching the item leaves the list. On Up Next
        // a watched episode is replaced by the one after it, so it leaves too.
        let isContinueWatching = destination == .continueWatching
        let leavesOnWatched = isContinueWatching || destination == .nextUp

        return ItemRowActions(
            goTo: goTo,
            markWatched: {
                run(.item(id: id, isPlayed: true, removed: leavesOnWatched)) { try await $0.markWatched(itemID: id) }
            },
            markUnwatched: {
                run(.item(id: id, isPlayed: false, removed: isContinueWatching)) { try await $0.markUnwatched(itemID: id) }
            },
            removeFromContinueWatching: isContinueWatching ? {
                run(.item(id: id, isPlayed: nil, removed: true)) { try await $0.removeFromContinueWatching(item) }
            } : nil,
            removeShowWatched: upNextRemoval(for: item, markWatched: true),
            removeShowUnwatched: upNextRemoval(for: item, markWatched: false)
        )
    }

    /// The menu actions for an item, with "Go to …" opening it through `navigation`.
    ///
    /// An episode also offers "Go to Season" and "Go to Show", and a season "Go to Show". The server is asked for
    /// the season or show when one is chosen, since the item only knows its ID.
    ///
    /// - Parameter omitting: Links to leave out because the screen is already inside them, e.g. "Go to Show" on a
    ///   list of a show's episodes.
    func actions(for item: MediaItem, navigation: ItemNavigation, omitting: Set<RelatedLink> = []) -> ItemRowActions? {
        // A special feature has no screen of its own to go to; it only plays.
        var actions = actions(for: item, goTo: item.kind == .extra ? nil : { navigation.open(item) })
        // A show with a single season has no season page, so its episodes offer only the episode and the show. The
        // count is fetched if it isn't known yet, and the entry waits for it.
        if item.kind == .episode, !omitting.contains(.season), let seasonID = item.seasonID, let seriesID = item.seriesID {
            let cache = SeasonCountCache.shared
            if let count = cache.count(ofSeries: seriesID) {
                if count > 1 {
                    actions?.goToSeason = { open(itemID: seasonID, through: navigation) }
                }
            } else {
                cache.prefetch(seriesID: seriesID, service: service)
            }
        }
        if item.kind == .episode || item.kind == .season, !omitting.contains(.show), let seriesID = item.seriesID {
            actions?.goToShow = { open(itemID: seriesID, through: navigation) }
        }
        return actions
    }

    /// Fetches an item by ID and opens it, or shows the error.
    private func open(itemID: String, through navigation: ItemNavigation) {
        let service = service
        let state = state
        Task {
            do {
                navigation.open(try await service.item(id: itemID))
            } catch {
                state.wrappedValue.errorMessage = error.localizedDescription
            }
        }
    }

    /// What a long-press on an item peeks at and offers. Tapping the item plays it (see `ItemNavigation/tap(_:)`);
    /// tapping its peek opens it.
    ///
    /// - Parameter actions: The item's menu actions, from `actions(for:navigation:)`. Passed in so a row that
    ///   also shows them in a "more" menu builds them once.
    static func peekSpec(for item: MediaItem, actions: ItemRowActions?, navigation: ItemNavigation) -> PeekAndPopSpec {
        PeekAndPopSpec(
            menu: actions?.menuEntries(for: item) ?? [],
            accessibilityLabel: item.accessibilityDescription,
            onTap: { navigation.tap(item) },
            onOpen: { navigation.open(item) },
            peek: ItemPeek(item: item)
        )
    }

    /// Marks every episode of a show or season watched or unwatched, once the user has confirmed.
    func perform(_ change: BulkWatchChange) {
        let id = change.item.id
        let isPlayed = change.markWatched
        run(.container(id: id, isPlayed: isPlayed)) { service in
            if isPlayed {
                try await service.markWatched(itemID: id)
            } else {
                try await service.markUnwatched(itemID: id)
            }
        }
    }

    /// Marks every episode of a show watched or unwatched, once the user has confirmed, taking it off Up Next.
    func perform(_ removal: ShowRemoval) {
        let seriesID = removal.seriesID
        let isPlayed = removal.markWatched
        run(.seriesRemoved(seriesID: seriesID)) { service in
            if isPlayed {
                try await service.markWatched(itemID: seriesID)
            } else {
                try await service.markUnwatched(itemID: seriesID)
            }
        }
    }

    /// Asks to remove an episode's show from Up Next, or nil off Up Next or if the show is unknown.
    private func upNextRemoval(for item: MediaItem, markWatched: Bool) -> (() -> Void)? {
        guard destination == .nextUp, let seriesID = item.seriesID else { return nil }
        return { state.wrappedValue.pendingRemoval = ShowRemoval(item: item, seriesID: seriesID, markWatched: markWatched) }
    }

    /// Runs a server change, then applies `effect` if it succeeded, or shows the error if it didn't.
    private func run(_ effect: WatchEffect, _ change: @escaping @Sendable (any MediaService) async throws -> Void) {
        let service = service
        let state = state
        let apply = apply
        Task {
            do {
                try await change(service)
                apply(effect)
            } catch {
                state.wrappedValue.errorMessage = error.localizedDescription
            }
        }
    }
}

/// Removing a show from Up Next rewrites the watch state of all its episodes, so it's confirmed first.
struct ShowRemoval: Identifiable {
    let item: MediaItem
    let seriesID: String
    /// Whether every episode gets marked watched (true) or unwatched (false).
    let markWatched: Bool

    var id: String { "\(seriesID)-\(markWatched)" }
    var showTitle: String { item.seriesTitle ?? item.title }
}

/// Marking a whole show or season watched or unwatched rewrites the watch state of all its episodes, so it's
/// confirmed first.
struct BulkWatchChange: Identifiable {
    /// The show or season.
    let item: MediaItem
    /// Whether every episode gets marked watched (true) or unwatched (false).
    let markWatched: Bool

    var id: String { "\(item.id)-\(markWatched)" }
    private var isSeason: Bool { item.kind == .season }

    /// e.g. "Breaking Bad" or "Breaking Bad – Season 2".
    var name: String {
        isSeason ? [item.seriesTitle, item.title].compactMap { $0 }.joined(separator: " – ") : item.title
    }

    var alertTitle: String {
        switch (isSeason, markWatched) {
        case (false, true): String(localized: "Mark Show as Watched?")
        case (false, false): String(localized: "Mark Show as Unwatched?")
        case (true, true): String(localized: "Mark Season as Watched?")
        case (true, false): String(localized: "Mark Season as Unwatched?")
        }
    }
}

extension View {
    /// The alerts behind `actions`: confirmations for changes to a whole show or season, and errors.
    func watchActionAlerts(_ actions: WatchActions) -> some View {
        let state = actions.state
        return alert("Couldn't Update Item", isPresented: state.errorMessage.isPresent()) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(state.wrappedValue.errorMessage ?? "")
        }
        .confirmShowRemoval(state.pendingRemoval) { actions.perform($0) }
        .confirmBulkWatchChange(state.pendingBulkChange) { actions.perform($0) }
        .downloadPrompts(state.downloadPrompt)
    }

    /// Asks the user to confirm a pending show or season change, warning what it does to the watch history.
    ///
    /// An alert, for the same reason as `confirmShowRemoval`.
    fileprivate func confirmBulkWatchChange(_ change: Binding<BulkWatchChange?>, perform: @escaping (BulkWatchChange) -> Void) -> some View {
        alert(
            change.wrappedValue?.alertTitle ?? "",
            isPresented: change.isPresent(),
            presenting: change.wrappedValue
        ) { pending in
            if pending.markWatched {
                Button("Mark as Watched") { perform(pending) }
            } else {
                Button("Mark as Unwatched", role: .destructive) { perform(pending) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            if pending.markWatched {
                Text("Every episode of \(pending.name) will be marked as watched, in all your Jellyfin apps. Their watched dates will be set to now.")
            } else {
                Text("Every episode of \(pending.name) will be marked as unwatched, in all your Jellyfin apps. This resets their play counts and watch dates, and can't be undone.")
            }
        }
    }

    /// Asks the user to confirm a pending Up Next removal, warning what it does to the show's watch history.
    ///
    /// An alert, not a confirmation dialog: on iPad a dialog becomes a popover that has to point at a
    /// view, and attached to a whole list or shelf it points at an arbitrary one.
    fileprivate func confirmShowRemoval(_ removal: Binding<ShowRemoval?>, perform: @escaping (ShowRemoval) -> Void) -> some View {
        alert(
            "Remove from Up Next?",
            isPresented: removal.isPresent(),
            presenting: removal.wrappedValue
        ) { pending in
            if pending.markWatched {
                Button("Mark All Episodes as Watched") { perform(pending) }
            } else {
                Button("Mark All Episodes as Unwatched", role: .destructive) { perform(pending) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            if pending.markWatched {
                Text("Every episode of \(pending.showTitle) will be marked as watched, in all your Jellyfin apps. Their watched dates will be set to now.")
            } else {
                Text("Every episode of \(pending.showTitle) will be marked as unwatched, in all your Jellyfin apps. This resets their play counts and watch dates, and can't be undone.")
            }
        }
    }
}

extension Binding {
    /// Whether an optional is set, for an `isPresented:` parameter. Setting it to false clears the optional.
    func isPresent<Wrapped>() -> Binding<Bool> where Value == Wrapped? {
        Binding<Bool>(
            get: { wrappedValue != nil },
            set: { if !$0 { wrappedValue = nil } }
        )
    }
}
