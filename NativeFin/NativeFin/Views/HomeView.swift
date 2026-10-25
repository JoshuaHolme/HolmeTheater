// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Continue Watching plus a "Recently Added" shelf for each movie / TV library.
///
/// Instead of a system navigation title, it draws its own large "Home" heading with the profile
/// button beside it, as part of the scrolling content, so the two scroll away together.
struct HomeView: View {
    @Environment(AppModel.self) private var appModel

    /// One "Recently Added …" shelf.
    private struct Row: Identifiable {
        let library: Library
        let items: [MediaItem]
        var id: String { library.id }
    }

    private struct HomeData {
        let resume: [MediaItem]
        let rows: [Row]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                    .padding(.top)

                // Loads inside the scroll view, below the header, so the profile button stays
                // reachable (e.g. to sign out) even if loading fails.
                AsyncContent(load: loadHome) { data in
                    LazyVStack(alignment: .leading, spacing: 24) {
                        if !data.resume.isEmpty {
                            MediaShelf(title: ShelfDestination.continueWatching.title, items: data.resume, destination: .continueWatching)
                        }
                        ForEach(data.rows) { row in
                            let destination = ShelfDestination.recentlyAdded(row.library)
                            MediaShelf(title: destination.title, items: row.items, destination: destination)
                        }
                        if data.resume.isEmpty && data.rows.isEmpty {
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
    }

    /// Large heading with the profile button on the same line.
    private var header: some View {
        HStack {
            Text("Home")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)

            Spacer()

            AccountButton()
                .font(.title)
        }
        .padding(.horizontal)
    }

    /// Fetches the resume list and each movie/TV library's recently added items.
    /// Music and other libraries are skipped, since the app doesn't play them yet.
    private func loadHome() async throws -> HomeData {
        let service = appModel.service
        async let resume = service.resumeItems()
        let libraries = try await service.libraries()

        var rows: [Row] = []
        for library in libraries where library.kind == .movies || library.kind == .tvShows {
            let items = try await service.recentlyAddedItems(in: library)
            if !items.isEmpty { rows.append(Row(library: library, items: items)) }
        }
        let resumeItems = try await resume

        // Start downloading every poster now, so they're already cached by the time you scroll to them.
        ImageCache.shared.prefetch((resumeItems + rows.flatMap(\.items)).compactMap(\.posterURL))

        return HomeData(resume: resumeItems, rows: rows)
    }
}

#Preview {
    NavigationStack {
        HomeView()
            .mediaNavigationDestinations()
    }
    .environment(AppModel.preview())
}
