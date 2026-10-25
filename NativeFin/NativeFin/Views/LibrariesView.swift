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

    var body: some View {
        AsyncContent(load: { try await appModel.service.items(in: library) }) { items in
            if items.isEmpty {
                ContentUnavailableView("Empty Library", systemImage: "film.stack")
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: Layout.posterWidth), spacing: 12, alignment: .top)],
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
