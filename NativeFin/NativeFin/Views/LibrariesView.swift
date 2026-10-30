// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// List of the user's libraries; tapping one opens its poster grid.
struct LibrariesView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        AsyncContent(load: { try await appModel.service.libraries() }) { libraries in
            List(libraries) { library in
                NavigationLink(value: library) {
                    Label(library.name, systemImage: library.systemImage)
                }
            }
        }
        .navigationTitle("Libraries")
    }
}

/// Every item in one library, as a poster grid.
struct LibraryView: View {
    let library: Library
    @Environment(AppModel.self) private var appModel

    /// The narrowest a poster gets, wider at larger text sizes so captions stay readable.
    @ScaledMetric(relativeTo: .subheadline) private var posterMinimum: CGFloat = Layout.posterWidth

    var body: some View {
        AsyncContent(load: loadItems) { items in
            if items.isEmpty {
                ContentUnavailableView("Empty Library", systemImage: "film.stack")
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: min(posterMinimum, Layout.posterWidth * 2)), spacing: 12, alignment: .top)],
                        spacing: 16
                    ) {
                        ForEach(items) { item in
                            NavigationLink(value: item) {
                                PosterCard(item: item)
                            }
                            .cardLinkStyle()
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle(library.name)
    }

    /// Fetches the library and starts caching its posters in the background.
    private func loadItems() async throws -> [MediaItem] {
        let items = try await appModel.service.items(in: library)

        // The first screen's posters load before the grid shows, so they don't pop in. The next few screens' worth
        // download in the background; a huge library shouldn't flood the network and memory. Posters further down
        // still load as you scroll, and are then cached for next time.
        ImageCache.shared.prefetch(items.dropFirst(18).prefix(42).compactMap(\.posterURL))
        await ImageCache.shared.preload(items.prefix(18).compactMap(\.posterURL))
        return items
    }
}

private extension Library {
    /// The SF Symbol shown beside the library in lists.
    var systemImage: String {
        switch kind {
        case .movies: "film"
        case .tvShows: "tv"
        case .music: "music.note"
        case .other: "folder"
        }
    }
}

#Preview("Libraries") {
    NavigationStack {
        LibrariesView()
            .mediaNavigationDestinations()
    }
    .environment(AppModel.preview())
}

#Preview("Library") {
    NavigationStack {
        LibraryView(library: .previewMovies)
            .mediaNavigationDestinations()
    }
    .environment(AppModel.preview())
}
