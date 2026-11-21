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

    /// A watch-state change waiting for confirmation, or an error to show.
    @State private var watchState = WatchActionState()

    /// The item a result's "Go to …" is opening; setting it pushes its detail screen.
    @State private var goToItem: MediaItem?

    /// The item being played; setting it presents the full-screen player.
    @State private var playingItem: MediaItem?

    var body: some View {
        Group {
            if let errorMessage {
                ContentUnavailableView("Search Failed", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else if query.isEmpty {
                GenreBrowser()
            } else if results.isEmpty && !isSearching {
                ContentUnavailableView.search(text: query)
            } else {
                resultsList
            }
        }
        .themeWash()
        #if os(tvOS)
        // tvOS draws the title large over the content, and the search field is already labelled "Search".
        .navigationTitle("")
        #else
        .navigationTitle("Search")
        #endif
        .searchable(text: $query)
        .watchActionAlerts(watchActions)
        .navigationDestination(item: $goToItem) { ItemDetailView(item: $0) }
        .fullScreenCover(item: $playingItem) { PlayerView(item: $0, onStop: { Task { await refreshResults() } }) }
        // Restarts (and cancels the previous run) whenever the query changes.
        .task(id: query) { await search() }
    }

    private var watchActions: WatchActions {
        WatchActions(service: appModel.service, downloads: appModel.downloads, canManageCollections: appModel.canManageCollections, destination: nil, state: $watchState) { effect in
            results = results.applying(effect)
        }
    }

    private var navigation: ItemNavigation {
        ItemNavigation(open: { goToItem = $0 }, play: { playingItem = $0 })
    }

    /// One row per result: poster, title and a line of details, with a menu of actions on the right.
    private var resultsList: some View {
        ScrollView {
            #if os(tvOS)
            // A grid of landscape cards, as in the Apple TV app's search: more results on screen, one focus stop each.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: Layout.cardSpacing, alignment: .top)], spacing: Layout.cardSpacing) {
                ForEach(results) { item in
                    let actions = watchActions.actions(for: item, navigation: navigation)
                    Button { navigation.open(item) } label: {
                        WideCard(item: item)
                    }
                    .cardLinkStyle()
                    .contextMenu { ItemActionButtons(entries: actions?.menuEntries(for: item) ?? []) }
                    .accessibilityLabel(item.accessibilityDescription)
                }
            }
            .padding()
            #else
            LazyVStack(spacing: 0) {
                ForEach(results) { item in
                    SearchResultRow(item: item, actions: watchActions.actions(for: item, navigation: navigation))
                }
            }
            .padding(.horizontal)
            #endif
        }
        .scrollClipDisabled()
    }

    /// Fetches the current results again, e.g. after playback, so their watch state and progress are up to date. Keeps
    /// what's showing if it fails; it's only out of date.
    private func refreshResults() async {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty, let fresh = try? await appModel.service.search(term) else { return }
        // The query changed while this was loading; the search for the new one has the say.
        guard term == query.trimmingCharacters(in: .whitespaces) else { return }
        results = fresh
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
        // A cancelled run has been replaced by a newer one that's still searching, so leave the flag to it.
        defer { if !Task.isCancelled { isSearching = false } }

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

/// A search result: a poster, the title, and what kind of thing it is, with a menu of actions on the right.
private struct SearchResultRow: View {
    let item: MediaItem
    let actions: ItemRowActions?

    private var posterWidth: CGFloat {
        #if os(tvOS)
        return 120
        #else
        return 56
        #endif
    }

    /// "Movie · Comedy · 2012": the kind of item, its first genre, and for a movie its year.
    private var details: String {
        var parts: [String] = []
        switch item.kind {
        case .movie: parts.append(String(localized: "Movie"))
        case .series: parts.append(String(localized: "TV Show"))
        case .season: parts.append(String(localized: "Season"))
        case .episode: parts.append(String(localized: "Episode"))
        case .extra: parts.append(String(localized: "Extra"))
        case .collection: parts.append(String(localized: "Collection"))
        case .playlist: parts.append(String(localized: "Playlist"))
        case .other: break
        }
        if let genre = item.genres.first { parts.append(genre) }
        if item.kind == .movie, let year = item.year { parts.append(String(year)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 16) {
            NavigationLink(value: item) {
                HStack(spacing: 16) {
                    ArtworkView(url: item.posterURL, aspectRatio: 2.0 / 3.0)
                        .frame(width: posterWidth)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.body)
                            .lineLimit(1)
                        Text(details)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .cardLinkStyle()

            if let actions {
                ItemActionsMenu(item: item, actions: actions)
            }
        }
        .padding(.vertical, 10)
        // A divider that starts at the text, not the poster.
        .overlay(alignment: .bottomTrailing) {
            Divider().padding(.leading, posterWidth + 16)
        }
    }
}

/// Genres as a grid of posters, for browsing when nothing has been searched for.
private struct GenreBrowser: View {
    @Environment(AppModel.self) private var appModel

    /// How many posters across for a screen of `size`: five on a TV; elsewhere at least two, and one more for each
    /// `columnWidth` of room, then more still until a poster is a little short of the screen's height, so an iPad or a phone
    /// on its side doesn't get posters taller than the screen, with their names out of sight below.
    private static func columnCount(for size: CGSize) -> Int {
        #if os(tvOS)
        return 5
        #else
        var count = max(2, Int(size.width / columnWidth))
        while count < 8 {
            // The grid's padding is the system's 16 on each side.
            let posterWidth = (size.width - 32 - CGFloat(count - 1) * Layout.cardSpacing) / CGFloat(count)
            guard posterWidth * 1.5 > size.height * 0.9 else { break }
            count += 1
        }
        return count
        #endif
    }

    /// The room each poster takes before another fits: wide enough that iPhone Duo's open inner display (about 670 points
    /// across) still has two.
    private static let columnWidth: CGFloat = 250

    var body: some View {
        AsyncContent(load: { try await appModel.service.genres() }) { genres in
            // A GeometryReader, rather than measuring after layout, so the first frame already has the right columns.
            GeometryReader { proxy in
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Layout.cardSpacing, alignment: .top), count: Self.columnCount(for: proxy.size)), spacing: Layout.cardSpacing) {
                    ForEach(genres) { genre in
                        NavigationLink(value: genre) {
                            CollageCard(title: genre.name, aspectRatio: 2.0 / 3.0, cacheKey: "\(appModel.cacheScope)|genre-\(genre.id)") {
                                // A handful of the genre's posters.
                                let items = (try? await appModel.service.items(in: genre)) ?? []
                                return items.prefix(16).compactMap(\.posterURL)
                            }
                        }
                        .cardLinkStyle()
                    }
                }
                .padding()
            }
            }
        }
    }
}

/// The movies and shows in a genre, as a poster grid.
struct GenreView: View {
    let genre: Genre
    @Environment(AppModel.self) private var appModel

    var body: some View {
        AsyncContent(load: { try await appModel.service.items(in: genre) }) { items in
            PosterBrowser(items: items, title: genre.name, offersGenreFilter: false)
        }
        #if os(tvOS)
        // The browser draws the title itself, level with the sort and filter buttons, as a library's page does.
        .navigationTitle("")
        #else
        .navigationTitle(genre.name)
        #endif
    }
}

#Preview {
    NavigationStack {
        SearchView()
            .mediaNavigationDestinations()
    }
    .environment(AppModel.preview())
}
