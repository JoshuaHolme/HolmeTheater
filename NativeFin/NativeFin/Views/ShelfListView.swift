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

    private static let pageSize = 30

    var body: some View {
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
            } : nil
        )
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
