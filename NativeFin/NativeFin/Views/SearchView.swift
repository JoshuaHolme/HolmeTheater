// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Search-as-you-type over movies, series, and episodes.
struct SearchView: View {
    @Environment(AppModel.self) private var appModel

    @State private var query = ""
    @State private var results: [MediaItem] = []
    @State private var isSearching = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let errorMessage {
                ContentUnavailableView("Search Failed", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else if query.isEmpty {
                ContentUnavailableView("Search", systemImage: "magnifyingglass", description: Text("Find movies, shows, and episodes."))
            } else if results.isEmpty && !isSearching {
                ContentUnavailableView.search(text: query)
            } else {
                List(results) { item in
                    NavigationLink(value: item) {
                        ItemRow(item: item)
                    }
                }
            }
        }
        .navigationTitle("Search")
        .searchable(text: $query)
        // Restarts (and cancels the previous run) whenever the query changes.
        .task(id: query) { await search() }
    }

    /// Runs one debounced search for the current query. Cancelled by SwiftUI when the query changes.
    private func search() async {
        errorMessage = nil
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else {
            results = []
            return
        }

        isSearching = true
        defer { isSearching = false }

        // Debounce typing.
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }

        do {
            results = try await appModel.service.search(term)
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    NavigationStack {
        SearchView()
            .mediaNavigationDestinations()
    }
    .environment(AppModel.preview())
}
