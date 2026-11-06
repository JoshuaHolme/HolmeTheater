// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// The shelves the user has chosen (Continue Watching, Up Next, Recently Released and Recently Added for each movie / TV
/// library, and so on), in their order, under an optional carousel. See ``HomeSettings``.
///
/// Instead of a system navigation title, it draws its own large "Home" heading as part of the scrolling content. The
/// profile button is in the navigation bar, as on the other tabs.
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

    /// Changes when the screen needs to load again: after a watch-state change, or when the user changes how the screen is set up.
    private var reloadID: Int {
        var hasher = Hasher()
        hasher.combine(reloadCount)
        hasher.combine(appModel.homeSettings.revision)
        return hasher.finalize()
    }

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

    /// The seasonal theme showing, if any.
    private var theme: AppTheme? { appModel.themeSettings.activeTheme }

    /// Whether the page draws its own heading. On tvOS the sidebar already names the screen, so there's none (it
    /// collided with the hero's title). That includes a holiday theme's greeting; the theme still tints the page.
    private var showsHeader: Bool {
        #if os(tvOS)
        false
        #else
        true
        #endif
    }

    /// One shelf on the home screen.
    private struct Shelf: Identifiable {
        let id: String
        let destination: ShelfDestination
        let items: [MediaItem]
        /// Whether there's more behind the shelf than the items shown, which is when it ends with a See All card.
        let hasMore: Bool
    }

    private struct HomeData {
        /// The newest items on the server, for the carousel at the top. Empty if the user turned the carousel off.
        let hero: [MediaItem]
        /// What each hero's Play button plays, by the hero's ID. A hero with nothing to play is missing.
        let heroPlayTargets: [MediaItem.ID: MediaItem]
        /// The shelves that have something on them, in the order the user chose.
        let shelves: [Shelf]
    }

    var body: some View {
        // Outside the scroll view, so it reports the real safe area, which the scroll view below runs past.
        GeometryReader { proxy in
            let safeArea = proxy.safeAreaInsets
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !showsHero && showsHeader {
                        header
                            .padding(.top, safeArea.top)
                            .padding(.top)
                    }

                    // Loads inside the scroll view, below the header, so the profile button in the bar stays
                    // reachable (e.g. to sign out) even if loading fails.
                    AsyncContent(load: loadHome, reloadID: reloadID, refresher: refresher, pullsToRefresh: false, loadingHeight: loadingHeight(proxy), offersDownloads: true) { data in
                        HomeColumn {
                            if !data.hero.isEmpty {
                                HomeHeroCarousel(
                                    items: data.hero,
                                    playTargets: data.heroPlayTargets,
                                    safeArea: safeArea,
                                    // The whole screen, past the side safe areas the carousel runs under.
                                    screenSize: CGSize(
                                        width: proxy.size.width + safeArea.leading + safeArea.trailing,
                                        height: screenHeight(proxy)
                                    ),
                                    open: { goToItem = $0 },
                                    play: { playingItem = $0 }
                                ) {
                                    if showsHeader { header.foregroundStyle(.white) }
                                }
                                #if os(tvOS)
                                // Scrolled up, the carousel leaves faster than the page, so the first shelf, which moves with the
                                // page, comes away from it and stands on its own, with a gap between them. Read here, not in
                                // the effect, which runs outside the main actor.
                                .visualEffect { [lead = HeroLayout.parallaxLead, travel = HeroLayout.parallaxTravel] content, proxy in
                                    let scrolled = max(0, -proxy.frame(in: .scrollView).minY)
                                    // Only over the first stretch of scrolling, which is when the gap is made. After that the
                                    // carousel goes with the page, and stays in view above the shelves.
                                    return content.offset(y: -min(scrolled, travel) * lead)
                                }
                                // The first shelf rises over the artwork's bottom edge, so its heading and the tops of its
                                // cards show over the hero at rest.
                                .padding(.bottom, -HeroLayout.bottomReserve)
                                #endif
                            }
                            #if os(tvOS)
                            shelvesSection(data.shelves)
                                // The carousel is as wide as the whole screen, which stretches the column past the safe areas.
                                // Without this the rows were that wide too, and scrolled to their ends with the last card
                                // still beyond the screen's edge.
                                .frame(width: proxy.size.width, alignment: .leading)
                            #else
                            ForEach(data.shelves) { shelf in
                                self.shelf(shelf)
                            }
                            #endif
                            if data.shelves.isEmpty {
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
            .background {
                if let theme { ThemeWash(color: theme.accent) }
            }
            .overlay {
                if let theme, appModel.themeSettings.showsEffects {
                    ThemeParticles(effect: theme.effect, topInset: safeArea.top)
                }
            }
            .pullToRefresh { await refresher.refresh() }
        }
        // The title is set so pushed screens can show "Home" on their back button. The bar itself only holds the profile
        // button (added where the tab is made): the heading below already names the screen.
        #if os(tvOS)
        // tvOS draws the title over the content, which here is the hero artwork; the sidebar already says "Home".
        .navigationTitle("")
        #else
        .navigationTitle("Home")
        #endif
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        #endif
        .navigationDestination(item: $goToItem) { ItemDetailView(item: $0) }
        .fullScreenCover(item: $playingItem) { PlayerView(item: $0, onStop: reload) }
    }

    /// The height to center the loading spinner in. On tvOS the page starts at the top edge of the screen with nothing
    /// above it, so the whole screen's height puts the spinner in the middle. Elsewhere the header sits above it, so the
    /// spinner fills what's left of the container.
    private func loadingHeight(_ proxy: GeometryProxy) -> CGFloat? {
        #if os(tvOS)
        screenHeight(proxy)
        #else
        nil
        #endif
    }

    /// The height of the whole screen, safe areas included. The carousel on tvOS is that tall.
    private func screenHeight(_ proxy: GeometryProxy) -> CGFloat {
        #if os(tvOS)
        proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
        #else
        proxy.size.height
        #endif
    }

    #if os(tvOS)
    /// The shelves, starting a little way in so the first heading clears the artwork's bottom edge.
    private func shelvesSection(_ shelves: [Shelf]) -> some View {
        LazyVStack(alignment: .leading, spacing: Layout.shelfSpacing) {
            ForEach(shelves) { shelf in
                self.shelf(shelf)
            }
        }
        // Close under the artwork's edge: the heading and the tops of the first cards show over the artwork, with about as
        // much of them as the Apple TV app's.
        .padding(.top, 12)
    }
    #endif

    /// Whether a shelf shows widescreen cards, with their progress and time left over the picture, as the Apple TV app's
    /// Continue Watching does. Only on tvOS, where there's room; elsewhere every shelf is posters.
    private static func usesWideCards(_ destination: ShelfDestination) -> Bool {
        #if os(tvOS)
        switch destination {
        case .continueWatching, .continueWatchingAndUpNext, .nextUp: true
        default: false
        }
        #else
        false
        #endif
    }

    /// A shelf whose heading opens `destination`'s full list. Its posters play here, and its watch-state
    /// actions reload the whole screen.
    private func shelf(_ shelf: Shelf) -> some View {
        let destination = shelf.destination
        return MediaShelf(
            title: destination.title,
            items: shelf.items,
            destination: destination,
            isWide: Self.usesWideCards(destination),
            hasMore: shelf.hasMore,
            onChange: reload,
            navigation: ItemNavigation(open: { goToItem = $0 }, play: { playingItem = $0 })
        )
    }

    /// Large heading, or a holiday theme's greeting. The profile button is in the navigation bar, above it.
    private var header: some View {
        HStack {
            Text(theme?.greeting(on: appModel.themeSettings.today) ?? String(localized: "Home"))
                .font(.largeTitle.bold())
                // A long greeting shrinks to stay on one line beside the symbol.
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityAddTraits(.isHeader)

            if let theme { ThemeGlyph(theme: theme) }

            Spacer()
        }
        .padding(.horizontal)
    }

    /// How many posters of each shelf load before the shelves show: about what fits across a screen.
    private static let preloadedPostersPerShelf = 6

    /// The carousel's items from the newest ones: movies and shows as they are, and an episode or season as the show it
    /// belongs to. A TV library's newest items are often single episodes, which the carousel should show as the show.
    /// A show that comes up more than once is shown once, where it first appears.
    private static func heroes(from newest: [MediaItem], limit: Int, hidesWatched: Bool, service: any MediaService) async -> [MediaItem] {
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
            .filter { seen.insert($0.id).inserted && ($0.backdropURL != nil || $0.posterURL != nil) && !(hidesWatched && $0.isPlayed) }
            .prefix(limit)
            .map { $0 }
    }

    /// Fetches the sections the user has turned on, and each movie/TV library's recently added items for them and
    /// the carousel. Music and other libraries are skipped, since the app doesn't play them yet.
    private func loadHome() async throws -> HomeData {
        let service = appModel.service
        let settings = appModel.homeSettings
        let sections = settings.visibleSections
        let combined = settings.combinesUpNext
        let allLibraries = try await service.libraries()
        let libraries = allLibraries.filter { $0.kind == .movies || $0.kind == .tvShows }

        // A section's libraries, or nil for all of them. Out of every library, since one of a kind the settings don't
        // list (a mixed library, say) can't have been turned off and still belongs in Continue Watching.
        func ids(_ section: HomeSettings.Section) -> [String]? { settings.libraryIDs(for: section, among: allLibraries) }

        let continueIDs = ids(.continueWatching)
        let nextUpIDs = ids(.nextUp)
        let onThisDayIDs = ids(.onThisDay)
        let wantsResume = sections.contains(.continueWatching)
        let wantsNextUp = sections.contains(.nextUp)
        let wantsOnThisDay = sections.contains(.onThisDay)
        let showsHero = settings.showsHero
        let heroOrder = settings.heroOrder

        async let resume: [MediaItem] = wantsResume
            ? (combined
                ? service.continueWatchingAndUpNext(offset: 0, limit: Self.shelfLimit, libraryIDs: continueIDs)
                : service.resumeItems(offset: 0, limit: Self.shelfLimit, libraryIDs: continueIDs))
            : []
        async let nextUp: [MediaItem] = wantsNextUp
            ? service.nextUpItems(offset: 0, limit: Self.shelfLimit, libraryIDs: nextUpIDs)
            : []
        // Only a shelf, so if it fails the rest of the screen still loads.
        async let onThisDayItems: [MediaItem]? = wantsOnThisDay ? try? await service.itemsOnThisDay(libraryIDs: onThisDayIDs) : []

        // Fetch every library's shelves at once rather than one after another. A library is only asked for what
        // something on screen uses.
        let shelves = try await withThrowingTaskGroup(of: (Int, [MediaItem], [MediaItem]).self) { group in
            for (index, library) in libraries.enumerated() {
                let heroUses = showsHero && settings.heroIncludes(library)
                let wantsAdded = (sections.contains(.recentlyAdded) && settings.includes(library, in: .recentlyAdded))
                    || (heroUses && heroOrder == .recentlyAdded)
                let wantsReleased = (sections.contains(.recentlyReleased) && settings.includes(library, in: .recentlyReleased))
                    || (heroUses && heroOrder == .recentlyReleased)
                guard wantsAdded || wantsReleased else { continue }
                group.addTask {
                    async let added = wantsAdded ? service.recentlyAddedItems(in: library) : []
                    // A failure here only costs this shelf; the rest of the screen still loads.
                    async let released = wantsReleased ? service.recentlyReleasedPage(in: library, offset: 0, limit: Self.shelfLimit + 1) : []
                    return (index, try await added, (try? await released) ?? [])
                }
            }
            var results: [(Int, [MediaItem], [MediaItem])] = []
            for try await result in group { results.append(result) }
            return results
        }
        // They finish in any order; put them back in the server's library order.
        let fetched = shelves.sorted { $0.0 < $1.0 }
        let resumeItems = try await resume
        let nextUpItems = try await nextUp
        let allOnThisDay = await onThisDayItems ?? []
        let onThisDay = Array(allOnThisDay.prefix(Self.shelfLimit))

        let byLibrary = Dictionary(uniqueKeysWithValues: fetched.map { (libraries[$0.0].id, (added: $0.1, released: $0.2)) })

        // Each section's shelves, top to bottom as the user ordered them.
        var homeShelves: [Shelf] = []
        for section in sections {
            switch section {
            case .continueWatching:
                // A full page may have another behind it.
                homeShelves.append(Shelf(id: "continue", destination: combined ? .continueWatchingAndUpNext : .continueWatching, items: resumeItems, hasMore: resumeItems.count >= Self.shelfLimit))
            case .nextUp:
                homeShelves.append(Shelf(id: "nextUp", destination: .nextUp, items: nextUpItems, hasMore: nextUpItems.count >= Self.shelfLimit))
            case .onThisDay:
                homeShelves.append(Shelf(id: "onThisDay", destination: .onThisDay, items: onThisDay, hasMore: allOnThisDay.count > Self.shelfLimit))
            case .recentlyReleased:
                for library in settings.ordered(libraries, for: .recentlyReleased) where settings.includes(library, in: .recentlyReleased) {
                    // One more than the shelf shows was asked for, to know whether there's more.
                    let released = byLibrary[library.id]?.released ?? []
                    homeShelves.append(Shelf(id: "released-\(library.id)", destination: .recentlyReleased(library), items: Array(released.prefix(Self.shelfLimit)), hasMore: released.count > Self.shelfLimit))
                }
            case .recentlyAdded:
                for library in settings.ordered(libraries, for: .recentlyAdded) where settings.includes(library, in: .recentlyAdded) {
                    // The server's latest-media list can't be asked for one more, so a full one may have more behind it.
                    let added = byLibrary[library.id]?.added ?? []
                    homeShelves.append(Shelf(id: "added-\(library.id)", destination: .recentlyAdded(library), items: added, hasMore: added.count >= Self.shelfLimit))
                }
            }
        }
        homeShelves.removeAll { $0.items.isEmpty }

        // The carousel's candidates, best first, from the libraries it's set to use.
        let heroLibraries = showsHero ? libraries.enumerated().filter { settings.heroIncludes($0.element) } : []
        let hasArtwork = { (item: MediaItem) in item.backdropURL != nil || item.posterURL != nil }
        let newest: [MediaItem]
        switch showsHero ? heroOrder : nil {
        case nil:
            newest = []
        case .recentlyAdded?:
            // The newest across libraries, keeping the shelves' order for items with no date (or the same one).
            newest = fetched
                .filter { settings.heroIncludes(libraries[$0.0]) }
                .flatMap(\.1)
                .filter(hasArtwork)
                .enumerated()
                .sorted { a, b in
                    switch (a.element.dateAdded, b.element.dateAdded) {
                    case let (x?, y?) where x != y: x > y
                    case (_?, nil): true
                    case (nil, _?): false
                    default: a.offset < b.offset
                    }
                }
                .map(\.element)
        case .recentlyReleased?:
            newest = fetched
                .filter { settings.heroIncludes(libraries[$0.0]) }
                .flatMap(\.2)
                .filter(hasArtwork)
                .enumerated()
                .sorted { a, b in
                    switch (a.element.releaseDate, b.element.releaseDate) {
                    case let (x?, y?) where x != y: x > y
                    case (_?, nil): true
                    case (nil, _?): false
                    default: a.offset < b.offset
                    }
                }
                .map(\.element)
        case .random?:
            // Picked by the server from everything in the library, not just what's new. A library that fails only
            // costs its share.
            let picks = await withTaskGroup(of: [MediaItem].self) { group in
                for (_, library) in heroLibraries {
                    group.addTask { (try? await service.randomItems(in: library, limit: Self.heroCount * 2)) ?? [] }
                }
                var all: [MediaItem] = []
                for await items in group { all += items }
                return all
            }
            newest = picks.filter(hasArtwork).shuffled()
        }
        let hero = await Self.heroes(from: newest, limit: Self.heroCount, hidesWatched: settings.heroHidesWatched, service: service)

        // The first posters of each shelf are loaded before the shelves show, so they don't pop in. Every other
        // poster starts downloading now, so it's cached by the time you scroll to it.
        let shelfItems = homeShelves.map(\.items)
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

        return HomeData(hero: hero, heroPlayTargets: heroPlayTargets, shelves: homeShelves)
    }
}

#Preview {
    NavigationStack {
        HomeView()
            .mediaNavigationDestinations()
    }
    .environment(AppModel.preview())
}

/// The column that holds the carousel and the shelves. Lazy, so shelves far down the page aren't built until they're near.
/// Not on tvOS: there the first shelf is pulled up over the carousel's bottom edge, so the carousel draws below its layout
/// box. A lazy stack goes by the layout box, so it threw the carousel away while its bottom was still on screen, then had
/// to build it and load its picture again on the way back, which showed as the hero popping out and in. (The shelves are
/// still lazy on tvOS: see `shelvesSection`.)
private struct HomeColumn<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: Layout.shelfSpacing) { content }
        #else
        LazyVStack(alignment: .leading, spacing: Layout.shelfSpacing) { content }
        #endif
    }
}
