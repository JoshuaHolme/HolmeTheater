// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Where a home-screen shelf's heading leads: the full list behind that shelf.
enum ShelfDestination: Hashable {
    case continueWatching
    /// Continue Watching followed by Up Next, as one list.
    case continueWatchingAndUpNext
    /// The next episode of each show being watched.
    case nextUp
    /// Everything recently added to a library (episodes for TV, movies for film).
    case recentlyAdded(Library)
    /// Everything recently released in a library, whenever it was added to it.
    case recentlyReleased(Library)
    /// Movies and shows from every library that first came out on today's date in some year.
    case onThisDay
    /// Other movies or shows on the server that resemble this one.
    case similar(MediaItem)
    /// The special features (extras) of a movie or show.
    case specialFeatures(MediaItem)
    /// The episodes of a season (the only one a mini series has).
    /// - omitsShow: Whether the list's menus leave out "Go to Show", because it was opened from the show's page.
    case episodes(MediaItem, omitsShow: Bool)

    /// The library page a shelf's See All card opens, in the order the shelf is in, for the shelves that are a slice of
    /// one library. Nil for the others, whose See All opens their own list.
    var sortedLibrary: SortedLibrary? {
        switch self {
        case .recentlyAdded(let library): SortedLibrary(library: library, sort: .addedNewest)
        case .recentlyReleased(let library): SortedLibrary(library: library, sort: .releasedNewest)
        default: nil
        }
    }

    var title: String {
        switch self {
        case .continueWatching: String(localized: "Continue Watching")
        case .continueWatchingAndUpNext: String(localized: "Continue Watching")
        case .nextUp: String(localized: "Up Next")
        case .recentlyAdded(let library): String(localized: "Recently Added \(library.name)")
        case .recentlyReleased(let library): String(localized: "Recently Released \(library.name)")
        case .onThisDay: String(localized: "On This Day")
        case .similar: String(localized: "More Like This")
        case .specialFeatures: String(localized: "Special Features")
        case .episodes: String(localized: "Episodes")
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

    /// Set when a refresh was asked for while a page was loading; it runs once the page is in.
    @State private var needsRefresh = false

    /// A watch-state change waiting for confirmation, or an error to show.
    @State private var watchState = WatchActionState()

    /// The item a peek's tap or "Go to …" is opening; setting it pushes its detail screen.
    @State private var goToItem: MediaItem?

    /// The item being played; setting it presents the full-screen player.
    @State private var playingItem: MediaItem?

    private static let pageSize = 30

    var body: some View {
        // A grid of widescreen cards when the screen is wider than it is tall (landscape iPhone or iPad),
        // otherwise a list of compact rows. A GeometryReader, rather than measuring after layout, so the
        // first frame is already the right one and its footer doesn't start a page load that gets cancelled.
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
        #if !os(tvOS)
        .navigationTitle(destination.title)
        #endif
        .themeWash()
        .watchActionAlerts(watchActions)
        .navigationDestination(item: $goToItem) { ItemDetailView(item: $0) }
        // Back from a detail screen, where the user may have played the item or changed its watch state.
        // Every detail screen the list opens goes through `goToItem`, which SwiftUI clears on the way back.
        .onChange(of: goToItem) { oldItem, newItem in
            if oldItem != nil && newItem == nil {
                Task { await refresh() }
            }
        }
        .fullScreenCover(item: $playingItem) {
            PlayerView(item: $0, onStop: { Task { await refresh() } })
        }
    }

    private var watchActions: WatchActions {
        WatchActions(service: appModel.service, downloads: appModel.downloads, destination: destination, state: $watchState) { effect in
            let before = items.count
            items = items.applying(effect)
            // Any rows that went are gone on the server too, so its next page starts that much earlier.
            nextOffset = max(nextOffset - (before - items.count), 0)
        }
    }

    /// What to show under an item in place of its usual caption. A season's episodes are all in the same season, so
    /// each shows its number and air date instead of "Season 1 Episode 3".
    private func captionLines(for item: MediaItem) -> [String]? {
        guard case .episodes = destination, item.kind == .episode else { return nil }
        return [item.title, item.episodeAirLine].compactMap { $0 }
    }

    /// The menu links to leave out: a list of a season's episodes is inside that season, and maybe the show.
    private var omittedLinks: Set<RelatedLink> {
        if case .episodes(_, let omitsShow) = destination { return omitsShow ? [.show, .season] : [.season] }
        return []
    }

    /// Tapping an item plays it; "Go to …" and its peek open it.
    private var navigation: ItemNavigation {
        ItemNavigation(open: { goToItem = $0 }, play: { playingItem = $0 })
    }

    private var list: some View {
        List {
            ForEach(items) { item in
                // Built once and shared by the "more" menu and the long-press menu.
                let actions = watchActions.actions(for: item, navigation: navigation, omitting: omittedLinks)
                tvTarget(for: item, actions: actions) {
                    ItemRow(item: item, captionLines: captionLines(for: item), actions: actions, peek: WatchActions.peekSpec(for: item, actions: actions, navigation: navigation))
                }
            }

            pageFooter
        }
        .listStyle(.plain)
        .pullToRefresh { await refresh() }
    }

    private var grid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                #if os(tvOS)
                // Like the library pages: the title at the leading edge, in the page rather than the navigation bar.
                Text(destination.title)
                    .font(.largeTitle.bold())
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 32)
                #endif
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: Layout.cardSpacing, alignment: .top)], spacing: Layout.cardSpacing) {
                    ForEach(items) { item in
                        let actions = watchActions.actions(for: item, navigation: navigation, omitting: omittedLinks)
                        tvTarget(for: item, actions: actions) {
                            ShelfGridCard(item: item, actions: actions, captionLines: captionLines(for: item), peek: WatchActions.peekSpec(for: item, actions: actions, navigation: navigation))
                        }
                    }
                }

                pageFooter
            }
            .padding()
        }
        .pullToRefresh { await refresh() }
    }

    /// On iOS the peek layer handles taps, so a row or card is shown as it is. On tvOS the row or card is itself
    /// the button, so it has a single focus stop: selecting opens the item, and the actions are in its long-press
    /// menu rather than a separate "…" button.
    @ViewBuilder
    private func tvTarget<Content: View>(for item: MediaItem, actions: ItemRowActions?, @ViewBuilder content: () -> Content) -> some View {
        #if os(tvOS)
        Button { navigation.tap(item) } label: {
            content()
        }
        .cardLinkStyle()
        .contextMenu {
            ItemActionButtons(entries: actions?.menuEntries(for: item) ?? [])
        }
        .accessibilityLabel(item.accessibilityDescription)
        #else
        content()
        #endif
    }

    /// The error and Retry button if a page failed, or else a spinner that loads the next page when it scrolls
    /// into view (which also loads the first). It's keyed on the count, so it asks again if a page doesn't fill
    /// the screen and it's still in view.
    @ViewBuilder
    private var pageFooter: some View {
        if let errorMessage {
            VStack {
                Text(errorMessage)
                    .foregroundStyle(.red)
                Button("Retry") { Task { await loadMore() } }
            }
            .frame(maxWidth: .infinity)
        } else if hasMore {
            ProgressView()
                .frame(maxWidth: .infinity)
                #if !os(tvOS)
                .listRowSeparator(.hidden)
                #endif
                .task(id: items.count) { await loadMore() }
        }
    }

    /// Fetches the next page and appends it. Does nothing if a page is already loading or there are no more.
    /// Runs a refresh that was asked for while it loaded, once it's done.
    private func loadMore() async {
        guard hasMore, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        await appendNextPage()
        isLoading = false

        if needsRefresh {
            // Unstructured: this task is the footer's, which is cancelled if the footer scrolls away.
            Task { await refresh() }
        }
    }

    /// The body of `loadMore()`: fetches the page at `nextOffset` and appends it, or records the error.
    private func appendNextPage() async {
        do {
            let page = try await fetchPage(offset: nextOffset, limit: Self.pageSize)
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

    /// Fetches everything loaded so far again, in one request, and replaces the list with it: after playback or
    /// on coming back from a detail screen, so it shows the latest progress (and on Continue Watching or Up Next,
    /// which items are on it at all).
    ///
    /// If a page is loading, this waits for it (see `loadMore()`), since both change the same state. If the
    /// request fails, the list stays as it is; it's only out of date.
    private func refresh() async {
        guard !isLoading else {
            needsRefresh = true
            return
        }
        needsRefresh = false
        isLoading = true
        defer { isLoading = false }

        let limit = max(nextOffset, Self.pageSize)
        guard let fresh = try? await fetchPage(offset: 0, limit: limit) else { return }
        items = fresh
        nextOffset = fresh.count
        hasMore = fresh.count >= limit
        // Everything loaded so far just loaded fine, so an earlier page's error no longer applies.
        errorMessage = nil
    }

    /// Every library, fetched the first time a page needs them and kept for the pages after.
    @State private var allLibraries: [Library]?

    /// The libraries the user chose for a home section, or nil for all of them. The libraries are only looked up if the
    /// user has turned some off.
    private func libraryIDs(for section: HomeSettings.Section) async throws -> [String]? {
        let settings = appModel.homeSettings
        guard settings.excludesLibraries(in: section) else { return nil }
        let libraries: [Library]
        if let allLibraries {
            libraries = allLibraries
        } else {
            libraries = try await appModel.service.libraries()
            allLibraries = libraries
        }
        return settings.libraryIDs(for: section, among: libraries)
    }

    private func fetchPage(offset: Int, limit: Int) async throws -> [MediaItem] {
        let service = appModel.service
        switch destination {
        case .continueWatching:
            return try await service.resumeItems(offset: offset, limit: limit, libraryIDs: libraryIDs(for: .continueWatching))
        case .continueWatchingAndUpNext:
            return try await service.continueWatchingAndUpNext(offset: offset, limit: limit, libraryIDs: libraryIDs(for: .continueWatching))
        case .nextUp:
            return try await service.nextUpItems(offset: offset, limit: limit, libraryIDs: libraryIDs(for: .nextUp))
        case .recentlyAdded(let library):
            return try await service.recentlyAddedPage(in: library, offset: offset, limit: limit)
        case .recentlyReleased(let library):
            return try await service.recentlyReleasedPage(in: library, offset: offset, limit: limit)
        case .onThisDay:
            // The server can't page these (they're filtered here by date), so it's asked for them all and cut here.
            return Array(try await service.itemsOnThisDay(libraryIDs: libraryIDs(for: .onThisDay)).dropFirst(offset).prefix(limit))
        case .episodes(let season, _):
            // The server pages these, but a season is short and in order, so it's asked for them all and cut here.
            return Array(try await service.children(of: season).dropFirst(offset).prefix(limit))
        case .specialFeatures(let item):
            // Like similar items, these have no paging on the server and there are few.
            return Array(try await service.specialFeatures(of: item).dropFirst(offset).prefix(limit))
        case .similar(let item):
            // The server has no paging for these, and there are few, so it's asked for them all and cut here.
            return Array(try await service.similarItems(to: item).dropFirst(offset).prefix(limit))
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
