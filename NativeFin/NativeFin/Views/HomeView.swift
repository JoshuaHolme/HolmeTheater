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

    /// How many of the newest items the carousel at the top shows.
    private static let heroCount = 10

    /// Reloads the shelves for a pull to refresh, which is on the scroll view around them.
    @State private var refresher = ContentRefresher()

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

    /// Whether the carousel is showing. When it is, it runs to the top of the screen with the "Home" heading over it;
    /// otherwise (loading, failed, or nothing new) the heading sits above the shelves as usual. Set from the shelves
    /// that are showing, so it always matches what's on screen, not from a load that may yet be thrown away.
    @State private var showsHero = false

    /// One library's "Recently Added …" and "Recently Released …" shelves.
    private struct Row: Identifiable {
        let library: Library
        /// What was added most recently.
        let items: [MediaItem]
        /// What came out most recently, whenever it was added.
        let released: [MediaItem]
        var id: String { library.id }
    }

    private struct HomeData {
        /// The newest items on the server, for the carousel at the top.
        let hero: [MediaItem]
        /// What each hero's Play button plays, by the hero's ID. A hero with nothing to play is missing.
        let heroPlayTargets: [MediaItem.ID: MediaItem]
        let resume: [MediaItem]
        /// Movies and shows that first came out on today's date in some year.
        let onThisDay: [MediaItem]
        let nextUp: [MediaItem]
        let rows: [Row]
    }

    var body: some View {
        // Outside the scroll view, so it reports the real safe area, which the scroll view below runs past.
        GeometryReader { proxy in
            let safeArea = proxy.safeAreaInsets
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !showsHero {
                        header
                            .padding(.top, safeArea.top)
                            .padding(.top)
                    }

                    // Loads inside the scroll view, below the header, so the profile button stays
                    // reachable (e.g. to sign out) even if loading fails.
                    AsyncContent(load: loadHome, reloadID: reloadCount, refresher: refresher, pullsToRefresh: false) { data in
                        LazyVStack(alignment: .leading, spacing: 24) {
                            if !data.hero.isEmpty {
                                HomeHeroCarousel(
                                    items: data.hero,
                                    playTargets: data.heroPlayTargets,
                                    safeArea: safeArea,
                                    // The whole screen, past the side safe areas the carousel runs under.
                                    screenSize: CGSize(
                                        width: proxy.size.width + safeArea.leading + safeArea.trailing,
                                        height: proxy.size.height
                                    ),
                                    open: { goToItem = $0 },
                                    play: { playingItem = $0 }
                                ) {
                                    header.foregroundStyle(.white)
                                }

                            }
                            if !data.resume.isEmpty {
                                shelf(.continueWatching, items: data.resume)
                            }
                            if !data.nextUp.isEmpty {
                                shelf(.nextUp, items: data.nextUp)
                            }
                            if !data.onThisDay.isEmpty {
                                shelf(.onThisDay, items: data.onThisDay)
                            }
                            ForEach(data.rows) { row in
                                // Released above added, since a new release is the likelier thing to want to watch.
                                if !row.released.isEmpty {
                                    shelf(.recentlyReleased(row.library), items: row.released)
                                }
                                if !row.items.isEmpty {
                                    shelf(.recentlyAdded(row.library), items: row.items)
                                }
                            }
                            if data.resume.isEmpty && data.nextUp.isEmpty && data.rows.isEmpty && data.onThisDay.isEmpty {
                                ContentUnavailableView("Nothing Here Yet", systemImage: "film.stack")
                            }
                        }
                        .onChange(of: data.hero.isEmpty, initial: true) { _, isEmpty in showsHero = !isEmpty }
                    }
                }
                .padding(.bottom)
            }
            // The carousel runs under the status bar, up to the top edge of the screen.
            .ignoresSafeArea(edges: .top)
            .pullToRefresh { await refresher.refresh() }
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

    /// How many posters of each shelf load before the shelves show: about what fits across a screen.
    private static let preloadedPostersPerShelf = 6

    /// The carousel's items from the newest ones: movies and shows as they are, and an episode or season as the show it
    /// belongs to. A TV library's newest items are often single episodes, which the carousel should show as the show.
    /// A show that comes up more than once is shown once, where it first appears.
    private static func heroes(from newest: [MediaItem], limit: Int, service: any MediaService) async -> [MediaItem] {
        // Enough to still have `limit` once shows that repeat are gone.
        let candidates = Array(newest.prefix(limit * 3))

        // Every show the episodes and seasons belong to, each once, fetched together in one request.
        var seriesIDs: [String] = []
        for item in candidates where item.kind == .episode || item.kind == .season {
            if let seriesID = item.seriesID, !seriesIDs.contains(seriesID) { seriesIDs.append(seriesID) }
        }
        let shows = (try? await service.items(withIDs: seriesIDs)) ?? []
        let showsByID = Dictionary(shows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var seen = Set<MediaItem.ID>()
        return candidates
            .compactMap { item -> MediaItem? in
                switch item.kind {
                case .episode, .season: item.seriesID.flatMap { showsByID[$0] }
                default: item
                }
            }
            .filter { seen.insert($0.id).inserted && ($0.backdropURL != nil || $0.posterURL != nil) }
            .prefix(limit)
            .map { $0 }
    }

    /// Fetches the resume list and each movie/TV library's recently added items.
    /// Music and other libraries are skipped, since the app doesn't play them yet.
    private func loadHome() async throws -> HomeData {
        let service = appModel.service
        async let resume = service.resumeItems(offset: 0, limit: Self.shelfLimit)
        async let nextUp = service.nextUpItems(offset: 0, limit: Self.shelfLimit)
        // Only a shelf, so if it fails the rest of the screen still loads.
        async let onThisDayItems = try? await service.itemsOnThisDay()
        let libraries = try await service.libraries().filter { $0.kind == .movies || $0.kind == .tvShows }

        // Fetch every library's shelves at once rather than one after another.
        let shelves = try await withThrowingTaskGroup(of: (Int, [MediaItem], [MediaItem]).self) { group in
            for (index, library) in libraries.enumerated() {
                group.addTask {
                    async let added = service.recentlyAddedItems(in: library)
                    // A failure here only costs this shelf; the rest of the screen still loads.
                    async let released = service.recentlyReleasedPage(in: library, offset: 0, limit: Self.shelfLimit)
                    return (index, try await added, (try? await released) ?? [])
                }
            }
            var results: [(Int, [MediaItem], [MediaItem])] = []
            for try await result in group { results.append(result) }
            return results
        }
        // They finish in any order; put them back in the server's library order.
        let rows = shelves
            .sorted { $0.0 < $1.0 }
            .compactMap { index, added, released in
                added.isEmpty && released.isEmpty ? nil : Row(library: libraries[index], items: added, released: released)
            }
        let resumeItems = try await resume
        let nextUpItems = try await nextUp
        let onThisDay = Array((await onThisDayItems ?? []).prefix(Self.shelfLimit))

        // The carousel shows the newest items across every library, which is where a library's shelf starts.
        let newest = rows.flatMap(\.items)
            .filter { $0.backdropURL != nil || $0.posterURL != nil }
            .enumerated()
            .sorted { a, b in
                // Newest first, keeping the shelves' order for items with no date (or the same one).
                switch (a.element.dateAdded, b.element.dateAdded) {
                case let (x?, y?) where x != y: x > y
                case (_?, nil): true
                case (nil, _?): false
                default: a.offset < b.offset
                }
            }
            .map(\.element)
        let hero = await Self.heroes(from: newest, limit: Self.heroCount, service: service)

        // The first posters of each shelf are loaded before the shelves show, so they don't pop in. Every other
        // poster starts downloading now, so it's cached by the time you scroll to it.
        let shelfItems = [resumeItems, nextUpItems] + rows.flatMap { [$0.released, $0.items] } + [onThisDay]
        let firstScreen = shelfItems.flatMap { $0.prefix(Self.preloadedPostersPerShelf) }
        let rest = shelfItems.flatMap { $0.dropFirst(Self.preloadedPostersPerShelf) }
        ImageCache.shared.prefetch(rest.compactMap(\.posterURL))
        await ImageCache.shared.preload(firstScreen.compactMap(\.posterURL))

        // What each hero's Play button plays: a movie itself, or the episode a show is up to. Fetched together.
        let heroPlayTargets = await withTaskGroup(of: (MediaItem.ID, MediaItem?).self) { group in
            for item in hero {
                group.addTask {
                    switch item.kind {
                    case .movie: (item.id, item)
                    case .series: (item.id, try? await service.nextEpisode(in: item))
                    default: (item.id, nil)
                    }
                }
            }
            var targets: [MediaItem.ID: MediaItem] = [:]
            for await (id, target) in group {
                if let target { targets[id] = target }
            }
            return targets
        }

        // The first two heroes are ready before the carousel shows; the others download behind them.
        let heroURLs = hero.compactMap { $0.backdropURL ?? $0.posterURL }
        ImageCache.shared.prefetch(Array(heroURLs.dropFirst(2)))
        await ImageCache.shared.preload(Array(heroURLs.prefix(2)))

        return HomeData(hero: hero, heroPlayTargets: heroPlayTargets, resume: resumeItems, onThisDay: onThisDay, nextUp: nextUpItems, rows: rows)
    }
}

#Preview {
    NavigationStack {
        HomeView()
            .mediaNavigationDestinations()
    }
    .environment(AppModel.preview())
}
