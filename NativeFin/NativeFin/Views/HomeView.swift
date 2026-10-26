// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Continue Watching, Up Next, plus a "Recently Added" shelf for each movie / TV library.
///
/// Instead of a system navigation title, it draws its own large "Home" heading with the profile
/// button beside it, as part of the scrolling content, so the two scroll away together.
struct HomeView: View {
    @Environment(AppModel.self) private var appModel

    /// How many items a home shelf shows; the shelf's heading opens the full list.
    private static let shelfLimit = 16

    /// Bumped to reload the shelves after an item's watch state changes on the server.
    @State private var reloadCount = 0

    private func reload() {
        reloadCount += 1
    }

    /// The item "Go to …" or a tapped card is taking the user to. The destination is here, not in each shelf,
    /// because shelves sit in a lazy stack, where SwiftUI ignores navigation destinations.
    @State private var goToItem: MediaItem?

    /// The item a tapped poster is playing; setting it presents the full-screen player. The shelves reload
    /// when it closes, so they show the latest progress.
    @State private var playingItem: MediaItem?

    /// One "Recently Added …" shelf.
    private struct Row: Identifiable {
        let library: Library
        let items: [MediaItem]
        var id: String { library.id }
    }

    private struct HomeData {
        let resume: [MediaItem]
        let nextUp: [MediaItem]
        let rows: [Row]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                    .padding(.top)

                // Loads inside the scroll view, below the header, so the profile button stays
                // reachable (e.g. to sign out) even if loading fails.
                AsyncContent(load: loadHome, reloadID: reloadCount) { data in
                    LazyVStack(alignment: .leading, spacing: 24) {
                        if !data.resume.isEmpty {
                            shelf(.continueWatching, items: data.resume)
                        }
                        if !data.nextUp.isEmpty {
                            shelf(.nextUp, items: data.nextUp)
                        }
                        ForEach(data.rows) { row in
                            shelf(.recentlyAdded(row.library), items: row.items)
                        }
                        if data.resume.isEmpty && data.nextUp.isEmpty && data.rows.isEmpty {
                            ContentUnavailableView("Nothing Here Yet", systemImage: "film.stack")
                        }
                    }
                }
            }
            .padding(.vertical)
        }
        // The title is still set so pushed screens can show "Home" on their back button;
        // the bar itself is hidden because the header replaces it.
        .navigationTitle("Home")
        .toolbarVisibility(.hidden, for: .navigationBar)
        .navigationDestination(item: $goToItem) { ItemDetailView(item: $0) }
        .fullScreenCover(item: $playingItem) { PlayerView(item: $0, onStop: reload) }
    }

    /// A shelf whose heading opens `destination`'s full list. Its posters play here, and its watch-state
    /// actions reload the whole screen.
    private func shelf(_ destination: ShelfDestination, items: [MediaItem]) -> some View {
        MediaShelf(
            title: destination.title,
            items: items,
            destination: destination,
            onChange: reload,
            navigation: ItemNavigation(open: { goToItem = $0 }, play: { playingItem = $0 })
        )
    }

    /// Large heading with the profile button on the same line.
    private var header: some View {
        HStack {
            Text("Home")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)

            Spacer()

            AccountButton()
        }
        .padding(.horizontal)
    }

    /// Fetches the resume list and each movie/TV library's recently added items.
    /// Music and other libraries are skipped, since the app doesn't play them yet.
    private func loadHome() async throws -> HomeData {
        let service = appModel.service
        async let resume = service.resumeItems(offset: 0, limit: Self.shelfLimit)
        async let nextUp = service.nextUpItems(offset: 0, limit: Self.shelfLimit)
        let libraries = try await service.libraries().filter { $0.kind == .movies || $0.kind == .tvShows }

        // Fetch every library's shelf at once rather than one after another.
        let shelves = try await withThrowingTaskGroup(of: (Int, [MediaItem]).self) { group in
            for (index, library) in libraries.enumerated() {
                group.addTask { (index, try await service.recentlyAddedItems(in: library)) }
            }
            var results: [(Int, [MediaItem])] = []
            for try await result in group { results.append(result) }
            return results
        }
        // They finish in any order; put them back in the server's library order.
        let rows = shelves
            .sorted { $0.0 < $1.0 }
            .compactMap { index, items in items.isEmpty ? nil : Row(library: libraries[index], items: items) }
        let resumeItems = try await resume
        let nextUpItems = try await nextUp

        // Start downloading every poster now, so they're already cached by the time you scroll to them.
        ImageCache.shared.prefetch((resumeItems + nextUpItems + rows.flatMap(\.items)).compactMap(\.posterURL))

        return HomeData(resume: resumeItems, nextUp: nextUpItems, rows: rows)
    }
}

#Preview {
    NavigationStack {
        HomeView()
            .mediaNavigationDestinations()
    }
    .environment(AppModel.preview())
}
