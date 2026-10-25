// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Where a home-screen shelf's heading leads: the full list behind that shelf.
enum ShelfDestination: Hashable {
    case continueWatching
    /// Everything recently added to a library (episodes for TV, movies for film).
    case latest(Library)

    var title: String {
        switch self {
        case .continueWatching: "Continue Watching"
        case .latest(let library): "Latest in \(library.name)"
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

    private static let pageSize = 30

    var body: some View {
        List {
            ForEach(items) { item in
                NavigationLink(value: item) {
                    ItemRow(item: item)
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
            // The server returns the whole resume list at once, so there's only ever one page.
            return offset == 0 ? try await service.resumeItems() : []
        case .latest(let library):
            return try await service.recentlyAdded(in: library, offset: offset, limit: Self.pageSize)
        }
    }
}

#Preview("Latest in TV Shows") {
    NavigationStack {
        ShelfListView(destination: .latest(Library(id: "lib-shows", name: "TV Shows", kind: .tvShows)))
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
