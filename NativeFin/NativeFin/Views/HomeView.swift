// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Continue Watching plus a "latest" shelf for each movie / TV library.
struct HomeView: View {
    @Environment(AppModel.self) private var appModel

    /// One "Latest in …" shelf.
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
        AsyncContent(load: loadHome) { data in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if !data.resume.isEmpty {
                        MediaShelf(title: "Continue Watching", items: data.resume)
                    }
                    ForEach(data.rows) { row in
                        MediaShelf(title: "Latest in \(row.library.name)", items: row.items)
                    }
                    if data.resume.isEmpty && data.rows.isEmpty {
                        ContentUnavailableView("Nothing Here Yet", systemImage: "film.stack")
                    }
                }
                .padding(.vertical)
            }
        }
        .navigationTitle("Home")
    }

    /// Fetches the resume list and each movie/TV library's latest items.
    /// Music and other libraries are skipped, since the app doesn't play them yet.
    private func loadHome() async throws -> HomeData {
        let service = appModel.service
        async let resume = service.resumeItems()
        let libraries = try await service.libraries()

        var rows: [Row] = []
        for library in libraries where library.kind == .movies || library.kind == .tvShows {
            let items = try await service.latestItems(in: library)
            if !items.isEmpty { rows.append(Row(library: library, items: items)) }
        }
        return HomeData(resume: try await resume, rows: rows)
    }
}
