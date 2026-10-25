// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Where a home-screen shelf's heading leads: the full list behind that shelf.
enum ShelfDestination: Hashable {
    case continueWatching
    /// The next episode of each show being watched.
    case nextUp
    /// Everything recently added to a library (episodes for TV, movies for film).
    case recentlyAdded(Library)

    var title: String {
        switch self {
        case .continueWatching: String(localized: "Continue Watching")
        case .nextUp: String(localized: "Up Next")
        case .recentlyAdded(let library): String(localized: "Recently Added \(library.name)")
        }
    }
}

/// A scrollable list of everything behind a home-screen shelf, loaded a page at a time as you scroll.
struct ShelfListView: View {
    let destination: ShelfDestination
    @Environment(AppModel.self) private var appModel

    @State private var items: [MediaItem] = []

    /// How many items the server has been asked for so far; the offset of the next page.
    @State private var nextOffset = 0
    @State private var hasMore = true
    @State private var isLoading = false
    @State private var errorMessage: String?

    /// Set when marking played or removing an item fails; shown in an alert.
    @State private var actionError: String?

    /// A show the user chose to remove from Up Next, waiting on their confirmation.
    @State private var pendingRemoval: ShowRemoval?

    /// Removing a show from Up Next rewrites the watch state of all its episodes, so it's confirmed first.
    private struct ShowRemoval: Identifiable {
        let item: MediaItem
        let seriesID: String
        /// Whether every episode gets marked watched (true) or unwatched (false).
        let markWatched: Bool

        var id: String { "\(seriesID)-\(markWatched)" }
        var showTitle: String { item.seriesTitle ?? item.title }
    }

    private static let pageSize = 30

    var body: some View {
        // A grid of widescreen cards when the screen is wider than it is tall (landscape iPhone or iPad),
        // otherwise a list of compact rows.
        GeometryReader { proxy in
            if proxy.size.width > proxy.size.height {
                grid
            } else {
                list
            }
        }
        .overlay {
            if items.isEmpty && !hasMore && errorMessage == nil {
                ContentUnavailableView("Nothing Here Yet", systemImage: "film.stack")
            }
        }
        .navigationTitle(destination.title)
        .alert("Couldn't Update Item", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        // An alert, not a confirmation dialog: on iPad a dialog becomes a popover that has to point at a
        // view, and attached to the whole list it points at an arbitrary row.
        .alert(
            "Remove from Up Next?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { removal in
            if removal.markWatched {
                Button("Mark All Episodes as Watched") { remove(removal) }
            } else {
                Button("Mark All Episodes as Unwatched", role: .destructive) { remove(removal) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { removal in
            if removal.markWatched {
                Text("Every episode of \(removal.showTitle) will be marked as watched, in all your Jellyfin apps. Their watched dates will be set to now.")
            } else {
                Text("Every episode of \(removal.showTitle) will be marked as unwatched, in all your Jellyfin apps. This resets their play counts and watch dates, and can't be undone.")
            }
        }
    }

    private var list: some View {
        List {
            ForEach(items) { item in
                ItemRow(item: item, actions: actions(for: item))
                    // A link in the background gives the row navigation without a disclosure chevron, and
                    // leaves the row's menu button free to take its own taps.
                    .background {
                        NavigationLink(value: item) { EmptyView() }
                            .opacity(0)
                    }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                    Button("Retry") { Task { await loadMore() } }
                }
            } else if hasMore {
                // Scrolling this into view loads the next page; it also loads the first one.
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                #if !os(tvOS)
                .listRowSeparator(.hidden)
                #endif
                .task { await loadMore() }
            }
        }
        .listStyle(.plain)
    }

    private var grid: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16, alignment: .top)], spacing: 16) {
                    ForEach(items) { item in
                        ShelfGridCard(item: item, actions: actions(for: item))
                            // The link sits behind the card, so the card's menu button takes its own taps.
                            // `contentShape` makes the clear label tappable.
                            .background {
                                NavigationLink(value: item) { Color.clear.contentShape(Rectangle()) }
                                    .cardLinkStyle()
                            }
                    }
                }

                if let errorMessage {
                    VStack {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                        Button("Retry") { Task { await loadMore() } }
                    }
                } else if hasMore {
                    // Scrolling this into view loads the next page. Keying on the count asks again if a page
                    // doesn't fill the screen and this is still in view.
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .task(id: items.count) { await loadMore() }
                }
            }
            .padding()
        }
    }

    /// The row menu for an item, or nil for things that can't be watched (series and seasons).
    private func actions(for item: MediaItem) -> ItemRowActions? {
        guard item.isPlayable else { return nil }
        let isContinueWatching = destination == .continueWatching

        // Either change clears the resume position, so on Continue Watching the item leaves the list.
        return ItemRowActions(
            markWatched: {
                // On Up Next, a watched episode is replaced by the one after it, so it leaves the list too.
                update(item, removesRow: isContinueWatching || destination == .nextUp, isPlayed: true) {
                    try await $0.markWatched(item)
                }
            },
            markUnwatched: {
                update(item, removesRow: isContinueWatching, isPlayed: false) { try await $0.markUnwatched(item) }
            },
            removeFromContinueWatching: isContinueWatching ? {
                update(item, removesRow: true) { try await $0.removeFromContinueWatching(item) }
            } : nil,
            removeShowWatched: upNextRemoval(for: item, markWatched: true),
            removeShowUnwatched: upNextRemoval(for: item, markWatched: false)
        )
    }

    /// Asks to remove an episode's show from Up Next, or nil off the Up Next list or if the show is unknown.
    private func upNextRemoval(for item: MediaItem, markWatched: Bool) -> (() -> Void)? {
        guard destination == .nextUp, let seriesID = item.seriesID else { return nil }
        return { pendingRemoval = ShowRemoval(item: item, seriesID: seriesID, markWatched: markWatched) }
    }

    /// Marks every episode of the show watched or unwatched, then drops its rows from the list.
    ///
    /// Like `update`, the list only changes once the server has confirmed.
    private func remove(_ removal: ShowRemoval) {
        let service = appModel.service
        Task {
            do {
                if removal.markWatched {
                    try await service.markSeriesWatched(seriesID: removal.seriesID)
                } else {
                    try await service.markSeriesUnwatched(seriesID: removal.seriesID)
                }
                let before = items.count
                items.removeAll { $0.seriesID == removal.seriesID }
                // Those rows are gone, so the next page starts earlier on the server too.
                nextOffset = max(nextOffset - (before - items.count), 0)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    /// Runs a server change to `item`'s watch state, then reflects it in the list.
    ///
    /// The list only changes if the server call succeeds, so it never disagrees with the server.
    ///
    /// - Parameters:
    ///   - removesRow: Whether the change takes the item out of this list, so its row goes away.
    ///   - isPlayed: The item's new watched state, if the change sets one. A resume position is always cleared.
    private func update(
        _ item: MediaItem,
        removesRow: Bool,
        isPlayed: Bool? = nil,
        change: @escaping @Sendable (any MediaService) async throws -> Void
    ) {
        let service = appModel.service
        Task {
            do {
                try await change(service)
                if removesRow {
                    items.removeAll { $0.id == item.id }
                    // The row is gone, so the next page starts earlier on the server too.
                    nextOffset = max(nextOffset - 1, 0)
                } else if let index = items.firstIndex(where: { $0.id == item.id }) {
                    items[index].isPlayed = isPlayed ?? items[index].isPlayed
                    items[index].playedFraction = nil
                }
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    /// Fetches the next page and appends it. Does nothing if a page is already loading or there are no more.
    private func loadMore() async {
        guard hasMore, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let page = try await fetchPage(offset: nextOffset)
            // The list scrolled away (or the screen closed) while loading; the footer will ask again.
            guard !Task.isCancelled else { return }

            // Items added on the server mid-scroll can shift the pages, so skip anything already shown.
            let known = Set(items.map(\.id))
            items += page.filter { !known.contains($0.id) }
            nextOffset += page.count

            // Cache this page's artwork now so rows already have their pictures when you scroll to them.
            ImageCache.shared.prefetch(page.compactMap(\.rowArtworkURL))
            hasMore = page.count >= Self.pageSize
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func fetchPage(offset: Int) async throws -> [MediaItem] {
        let service = appModel.service
        switch destination {
        case .continueWatching:
            return try await service.resumeItems(offset: offset, limit: Self.pageSize)
        case .nextUp:
            return try await service.nextUpItems(offset: offset, limit: Self.pageSize)
        case .recentlyAdded(let library):
            return try await service.recentlyAddedPage(in: library, offset: offset, limit: Self.pageSize)
        }
    }
}

#Preview("Recently Added TV Shows") {
    NavigationStack {
        ShelfListView(destination: .recentlyAdded(Library(id: "lib-shows", name: "TV Shows", kind: .tvShows)))
            .mediaNavigationDestinations()
    }
    .environment(AppModel.preview())
}

#Preview("Continue Watching") {
    NavigationStack {
        ShelfListView(destination: .continueWatching)
            .mediaNavigationDestinations()
    }
    .environment(AppModel.preview())
}
