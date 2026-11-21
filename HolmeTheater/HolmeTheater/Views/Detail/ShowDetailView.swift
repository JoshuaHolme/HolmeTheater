// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Detail for a show, one of its seasons, one of its episodes, or a movie: a full-width hero image running up to the
/// top edge of the screen, with the logo, genres and network (or studio), synopsis, and a Play button over it. A
/// show's seasons are listed below (or its episodes, if it has a single season); a season's episodes are.
///
/// A season's or episode's page is the show's page narrowed to it: the same hero and rows, showing only what the
/// season or episode itself has. An episode's hero is its own still, under the show's logo. A movie's page is the
/// same as a show's, with no episodes or seasons beneath it and "More Like This" for movies.
///
/// The hero's artwork and text are in `ShowDetailView+Hero.swift`; the Play, favorite, watched and other buttons are
/// in `ShowDetailView+Actions.swift`.
struct ShowDetailView: View {
    let item: MediaItem
    @Environment(AppModel.self) var appModel

    /// The episode being played; setting it presents the full-screen player.
    @State var playingItem: MediaItem?

    /// The episode the Play button starts. Nil until it's loaded, or if the show has no episodes.
    @State var nextEpisode: MediaItem?

    /// A season change waiting for confirmation, or an error to show.
    @State var watchState = WatchActionState()

    /// Bumped to reload the show, its next episode and its seasons after a change on the server.
    @State var reloadCount = 0

    /// The show as the server last described it. Nil until it's fetched again.
    @State var refreshedItem: MediaItem?

    /// Whether the sheet with the show's full description is showing.
    @State var showsOverview = false

    #if os(tvOS)
    /// Whether the sheet with everything about the show is open.
    @State var showsDetails = false
    #endif

    /// The size of the visible screen, which sets the hero's height.
    @State var screenSize: CGSize = .zero

    /// Other shows on the server that resemble this one. Empty until they arrive, or if there are none.
    @State var similarShows: [MediaItem] = []

    /// The show's special features. Empty until they arrive, or if there are none.
    @State var specialFeatures: [MediaItem] = []

    #if os(tvOS)
    /// The height of the whole screen, safe areas included, which the hero fills on tvOS as the Home carousel does.
    @State var fullScreenHeight: CGFloat = 0
    #endif

    /// The height of the details over the hero's bottom-left corner, without the padding around them.
    @State var detailsHeight: CGFloat = 0

    /// Whether the full list of special features is open.
    @State var showsFeatureList = false

    /// Whether the full list behind "More Like This" is open.
    @State var showsSimilar = false

    /// The show a tap or peek in "More Like This" is opening.
    @State var openedShow: MediaItem?

    /// Whether the first cast portraits have loaded, so the Cast and Crew row can show without them popping in.
    @State var castReady = false

    /// A favorite change the server hasn't confirmed yet, shown meanwhile.
    @State var favoriteOverride: Bool?

    @Environment(\.openURL) var openURL
    @Environment(\.dynamicTypeSize) var dynamicTypeSize

    /// Whether the description can take focus. On tvOS it can't until focus has been moved to Play, so it never
    /// flashes on the description first. (Always true elsewhere, where there's no focus to move.)
    @State var overviewIsFocusable = Self.startsFocusable

    static var startsFocusable: Bool {
        #if os(tvOS)
        false
        #else
        true
        #endif
    }

    #if os(tvOS)
    /// The screen's focus scope, so Play can be the first thing focused rather than whatever comes first on the page.
    @Namespace var focusNamespace
    @Environment(\.resetFocus) var resetFocus

    /// Whether focus has been settled on Play since the screen first appeared.
    @State var didSettleFocus = false

    /// Which of the hero's controls has focus, if it's one that's tracked. Setting it moves focus there.
    @FocusState var focusedControl: HeroControl?

    /// The hero controls focus can be sent to. Only Play, so far.
    enum HeroControl { case play }
    #endif

    /// How many lines a short line of the hero's text gets: two, or all it needs at accessibility sizes, where
    /// two lines would cut off most of it.
    var shortTextLineLimit: Int? { dynamicTypeSize.isAccessibilitySize ? nil : 2 }

    /// The theme's color, while a theme is showing.
    var themeAccent: Color? { appModel.themeSettings.activeTheme?.accent }

    var isSeason: Bool { item.kind == .season }
    var isEpisode: Bool { item.kind == .episode }
    var isMovie: Bool { item.kind == .movie }

    /// Whether the page is for one thing that plays, rather than something that holds episodes.
    var isPlayableItem: Bool { isEpisode || isMovie }

    /// The latest copy of the show or season. A season shows only what it has itself (genres, ratings, tagline,
    /// trailer, description, cast), with nothing borrowed from its show.
    var current: MediaItem { refreshedItem ?? item }

    var body: some View {
        ScrollView {
            // On tvOS the same space between rows as on Home.
            VStack(alignment: .leading, spacing: Self.rowSpacing) {
                hero
                    #if os(tvOS)
                    // The first row rises over the artwork's bottom edge, as on Home, so its heading and the tops of its
                    // cards show over the hero at rest.
                    // Scrolled up, the hero leaves faster than the page, so the first row comes away from it and stands
                    // on its own, as on Home. Read here, not in the effect, which runs outside the main actor.
                    // A season's hero doesn't leave early: its artwork is the whole page's, so it scrolls with the page.
                    .visualEffect { [lead = usesPosterArtwork ? 0 : Self.parallaxLead, travel = Self.parallaxTravel] content, proxy in
                        let scrolled = max(0, -proxy.frame(in: .scrollView).minY)
                        return content.offset(y: -min(scrolled, travel) * lead)
                    }
                    // A little further down, as Home's first shelf is, so its heading clears the artwork's edge.
                    .padding(.bottom, 12 - HeroLayout.bottomReserve)
                    #endif

                // These pad their own headings and the ends of their rows, so the rows scroll edge to edge.
                if isPlayableItem {
                    // An episode or movie has no rows of episodes or seasons beneath it.
                } else if isSeason {
                    // Already inside the season, so its episodes have no "Go to Season".
                    EpisodeShelf(season: item, reloadID: reloadCount, omitting: [.season], focusesFirstUnwatched: true, open: { openedShow = $0 }, play: { playingItem = $0 })
                } else {
                    SeasonsSection(item: item, reloadID: reloadCount, open: { openedShow = $0 }, play: { playingItem = $0 }) { watchActions.actions(for: $0) }
                }

                if !specialFeatures.isEmpty {
                    MediaShelf(
                        title: String(localized: "Special Features"),
                        items: specialFeatures,
                        onHeadingTap: { showsFeatureList = true },
                        isWide: true,
                        // An extra has no page of its own: tapping it, or opening its peek, plays it.
                        navigation: ItemNavigation(open: { openedShow = $0 }, play: { playingItem = $0 })
                    )
                }

                // Held back until the portraits that show first have loaded, so the row appears with its pictures
                // instead of the pictures popping in after it.
                if castReady {
                    CastAndCrewShelf(people: current.people)
                        .transition(.opacity)
                }

                if !similarShows.isEmpty {
                    // Padded and scrolled by the shelf itself, like the rows above. Its owner opens what's tapped.
                    MediaShelf(
                        title: String(localized: "More Like This"),
                        items: similarShows,
                        onHeadingTap: { showsSimilar = true },
                        navigation: ItemNavigation(open: { openedShow = $0 }, play: { playingItem = $0 })
                    )
                }
            }
            .padding(.bottom)
            // A season's blurred poster fills the whole page behind its sections, and scrolls with them.
            .background(alignment: .top) {
                if usesPosterArtwork { seasonPageBackground }
            }
        }
        #if os(tvOS)
        // Measured before the safe area is ignored, so the hero can be as tall as the whole screen, as Home's is.
        .onGeometryChange(for: CGFloat.self) { $0.size.height + $0.safeAreaInsets.top + $0.safeAreaInsets.bottom } action: { fullScreenHeight = $0 }
        #endif
        // The hero runs under the status and navigation bars, up to the top edge of the screen.
        .ignoresSafeArea(edges: .top)
        .themeWash(0.5)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { screenSize = $0 }
        #if os(tvOS)
        // tvOS draws the title over the content, doubling the logo or title the hero already shows.
        .navigationTitle("")
        #else
        .navigationTitle(item.title)
        #endif
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        // The logo over the hero already names the show.
        .toolbar(removing: .title)
        .toolbar { toolbarButtons }
        #endif
        #if os(tvOS)
        .focusScope(focusNamespace)
        // Play appears once its episode has loaded, after focus has already settled somewhere else.
        // A season's focus goes to its first unwatched episode, which its shelf asks for, so Play doesn't take it back.
        .onChange(of: nextEpisode?.id) { if !isSeason { resetFocus(in: focusNamespace) } }
        // An episode or movie has its Play button from the first frame, and the focus engine settles on whatever
        // comes first on the page (the description) before the preference is read. Ask again once it has settled,
        // only the first time so coming back to the page doesn't take focus from where the user was.
        .task {
            guard !didSettleFocus else { return }
            didSettleFocus = true
            if isSeason {
                // Focus goes to the first unwatched episode (see `EpisodeShelf`), not Play; the description can take it
                // from there on.
                try? await Task.sleep(for: .milliseconds(150))
                overviewIsFocusable = true
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            resetFocus(in: focusNamespace)
            // The preference above is only a hint to the focus engine, so also ask for Play outright, once the page
            // has had time to lay out.
            try? await Task.sleep(for: .milliseconds(350))
            focusedControl = .play
            // Focus is on Play now (or there's no Play button), so the description can take it from here on.
            try? await Task.sleep(for: .milliseconds(150))
            overviewIsFocusable = true
        }
        #endif
        .task(id: reloadCount) { await load() }
        // How many seasons the show has, for whether an episode links to its season.
        .task {
            if isEpisode, let seriesID = item.seriesID {
                SeasonCountCache.shared.prefetch(seriesID: seriesID, service: appModel.service)
            }
        }
        .pullToRefresh { await load() }
        .task(id: current.people.map(\.id)) { await preloadCastPortraits() }
        .fullScreenCover(item: $playingItem) {
            PlayerView(item: $0, onStop: { reloadCount += 1 })
        }
        .watchActionAlerts(watchActions)
        .navigationDestination(item: $openedShow) { ItemDetailView(item: $0) }
        .navigationDestination(isPresented: $showsFeatureList) { ShelfListView(destination: .specialFeatures(item)) }
        .navigationDestination(isPresented: $showsSimilar) { ShelfListView(destination: .similar(item)) }
        // Presented from here rather than the hero, so it doesn't inherit the hero's forced dark appearance.
        .sheet(isPresented: $showsOverview) {
            ShowOverviewSheet(item: current)
        }
        #if os(tvOS)
        .sheet(isPresented: $showsDetails) {
            ShowDetailsSheet(title: detailsTitle, tagline: current.tagline, overview: current.overview, facts: detailFacts)
        }
        #endif
    }

    /// Whether there's a season page to go to: an episode's season, unless its show has only the one, whose page would be the
    /// show's own. The count is fetched if it isn't known yet, and the link waits for it.
    var showsSeasonLink: Bool {
        guard isEpisode, item.seasonID != nil, let seriesID = item.seriesID,
              let count = SeasonCountCache.shared.count(ofSeries: seriesID) else { return false }
        return count > 1
    }

    /// Whether there's a show page to go to: from an episode or a season.
    var showsShowLink: Bool { (isEpisode || isSeason) && item.seriesID != nil }

    /// Opens the season or show with this ID, or shows why it couldn't.
    func openRelated(id: String) {
        Task {
            do {
                openedShow = try await appModel.service.item(id: id)
            } catch {
                watchState.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Loading

    /// How many cast portraits are loaded before the Cast and Crew row shows: about as many as fit on screen at once.
    private static let preloadedPortraitCount = 12

    /// The longest to wait for those portraits before showing the row anyway.
    private static let portraitPreloadTimeout = Duration.seconds(2)

    /// Fetches the episode to play, and the show again (for its full details, and after playback or a change so
    /// the screen shows where the user got to). Keeps what's on screen if either fails; it's only out of date.
    /// Clears what was fetched for another item. This screen can be reused for a different one (one opened from
    /// another's "More Like This"), and a request that then fails must not leave the last item's rows showing.
    private func discardStaleState() {
        guard refreshedItem?.id != item.id else { return }
        refreshedItem = nil
        nextEpisode = nil
        similarShows = []
        specialFeatures = []
    }

    private func load() async {
        if isSeason {
            await loadSeason()
            return
        }
        if isPlayableItem {
            await loadPlayableItem()
            return
        }

        discardStaleState()

        let service = appModel.service
        async let episode = service.nextEpisode(in: item)
        async let latest = service.item(id: item.id)
        async let similar = service.similarItems(to: item)
        async let features = service.specialFeatures(of: item)

        if let episode = try? await episode {
            nextEpisode = episode
        }
        if let latest = try? await latest {
            refreshedItem = latest
            SeasonCountCache.shared.record(latest.seasonCount, ofSeries: latest.id)
        }
        if let similar = try? await similar {
            await ImageCache.shared.preload(similar.prefix(6).compactMap(\.posterURL))
            similarShows = similar
        }
        if let features = try? await features {
            await ImageCache.shared.preload(features.prefix(4).compactMap(\.gridArtworkURL))
            specialFeatures = features
        }
    }

    /// Loads the first cast portraits into the image cache, then shows the Cast and Crew row. Starts downloading the
    /// rest in the background. The row never waits more than a moment for them on a slow network.
    private func preloadCastPortraits() async {
        let people = current.people
        guard !people.isEmpty else { return }

        let first = people.prefix(Self.preloadedPortraitCount).compactMap(\.imageURL)

        // Already in memory (coming back to the page, say): nothing to wait for.
        if first.allSatisfy({ ImageCache.shared.cachedImage(for: $0) != nil }) {
            castReady = true
            return
        }
        // These are other people (the screen was reused), so the row waits for their portraits.
        castReady = false

        ImageCache.shared.prefetch(people.dropFirst(Self.preloadedPortraitCount).compactMap(\.imageURL))

        await ImageCache.shared.preload(first, timeout: Self.portraitPreloadTimeout)
        withAnimation { castReady = true }
    }

    /// Fetches an episode or movie again (for its cast and where it got to), its special features and, for a movie, similar
    /// movies. The Play button plays the item itself. Keeps what's on screen if any of it fails; it's only out of date.
    private func loadPlayableItem() async {
        discardStaleState()
        nextEpisode = nextEpisode ?? item

        let service = appModel.service
        async let latest = service.item(id: item.id)
        async let features = service.specialFeatures(of: item)
        // Only movies have a "More Like This"; the server has none for an episode.
        async let similar = isMovie ? service.similarItems(to: item) : []

        if let latest = try? await latest {
            refreshedItem = latest
            nextEpisode = latest
        }
        if let features = try? await features {
            // The stills load before the row shows, so they don't pop in.
            await ImageCache.shared.preload(features.prefix(4).compactMap(\.gridArtworkURL))
            specialFeatures = features
        }
        if let similar = try? await similar {
            await ImageCache.shared.preload(similar.prefix(6).compactMap(\.posterURL))
            similarShows = similar
        }
    }

    /// Fetches a season again, its episodes (for what Play starts) and its special features. Keeps
    /// what's on screen if any of it fails; it's only out of date.
    private func loadSeason() async {
        discardStaleState()

        let service = appModel.service
        async let latest = service.item(id: item.id)
        async let episodes = service.children(of: item)
        async let features = service.specialFeatures(of: item)

        if let latest = try? await latest {
            refreshedItem = latest
        }
        if let episodes = try? await episodes {
            // The one that's partly watched, or the first unwatched, else the first.
            nextEpisode = episodes.first { $0.playedFraction != nil || !$0.isPlayed } ?? episodes.first
        }
        if let features = try? await features {
            specialFeatures = features
        }
    }

    /// Reloads the screen after a season is marked watched or unwatched, which changes the next episode too.
    var watchActions: WatchActions {
        WatchActions(service: appModel.service, downloads: appModel.downloads, canManageCollections: appModel.canManageCollections, destination: nil, state: $watchState) { _ in
            reloadCount += 1
        }
    }
}

#Preview("Show") {
    NavigationStack {
        ShowDetailView(item: .previewSeries)
            .mediaNavigationDestinations()
    }
    .environment(AppModel.preview())
}

#Preview("Long Description") {
    NavigationStack {
        ShowDetailView(item: MediaItem(
            id: "preview-series-long",
            title: "Sample Show",
            kind: .series,
            overview: String(repeating: "A placeholder synopsis long enough to be cut off over the hero, so it ends in a MORE button. ", count: 4),
            year: 2022,
            runtime: nil,
            posterURL: nil,
            backdropURL: nil,
            playedFraction: nil,
            isPlayed: false,
            seriesTitle: nil,
            seasonNumber: nil,
            episodeNumber: nil,
            genres: ["Comedy", "Drama"],
            network: "Sample Network"
        ))
        .mediaNavigationDestinations()
    }
    .environment(AppModel.preview())
}
