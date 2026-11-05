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
struct ShowDetailView: View {
    let item: MediaItem
    @Environment(AppModel.self) private var appModel

    /// The episode being played; setting it presents the full-screen player.
    @State private var playingItem: MediaItem?

    /// The episode the Play button starts. Nil until it's loaded, or if the show has no episodes.
    @State private var nextEpisode: MediaItem?

    /// A season change waiting for confirmation, or an error to show.
    @State private var watchState = WatchActionState()

    /// Bumped to reload the show, its next episode and its seasons after a change on the server.
    @State private var reloadCount = 0

    /// The show as the server last described it. Nil until it's fetched again.
    @State private var refreshedItem: MediaItem?

    /// Whether the sheet with the show's full description is showing.
    @State private var showsOverview = false

    /// The size of the visible screen, which sets the hero's height.
    @State private var screenSize: CGSize = .zero

    /// Other shows on the server that resemble this one. Empty until they arrive, or if there are none.
    @State private var similarShows: [MediaItem] = []

    /// The show's special features. Empty until they arrive, or if there are none.
    @State private var specialFeatures: [MediaItem] = []

    /// The height of the details over the hero's bottom-left corner, without the padding around them.
    @State private var detailsHeight: CGFloat = 0

    /// Whether the full list of special features is open.
    @State private var showsFeatureList = false

    /// Whether the full list behind "More Like This" is open.
    @State private var showsSimilar = false

    /// The show a tap or peek in "More Like This" is opening.
    @State private var openedShow: MediaItem?

    /// Whether the first cast portraits have loaded, so the Cast and Crew row can show without them popping in.
    @State private var castReady = false

    /// A favorite change the server hasn't confirmed yet, shown meanwhile.
    @State private var favoriteOverride: Bool?

    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Whether the description can take focus. On tvOS it can't until focus has been moved to Play, so it never
    /// flashes on the description first. (Always true elsewhere, where there's no focus to move.)
    @State private var overviewIsFocusable = Self.startsFocusable

    private static var startsFocusable: Bool {
        #if os(tvOS)
        false
        #else
        true
        #endif
    }

    #if os(tvOS)
    /// The screen's focus scope, so Play can be the first thing focused rather than whatever comes first on the page.
    @Namespace private var focusNamespace
    @Environment(\.resetFocus) private var resetFocus

    /// Whether focus has been settled on Play since the screen first appeared.
    @State private var didSettleFocus = false

    /// Which of the hero's controls has focus, if it's one that's tracked. Setting it moves focus there.
    @FocusState private var focusedControl: HeroControl?

    private enum HeroControl { case play }
    #endif

    /// How many lines a short line of the hero's text gets: two, or all it needs at accessibility sizes, where
    /// two lines would cut off most of it.
    private var shortTextLineLimit: Int? { dynamicTypeSize.isAccessibilitySize ? nil : 2 }

    private var isSeason: Bool { item.kind == .season }
    private var isEpisode: Bool { item.kind == .episode }
    private var isMovie: Bool { item.kind == .movie }

    /// Whether the page is for one thing that plays, rather than something that holds episodes.
    private var isPlayableItem: Bool { isEpisode || isMovie }

    /// The latest copy of the show or season. A season shows only what it has itself (genres, ratings, tagline,
    /// trailer, description, cast), with nothing borrowed from its show.
    private var current: MediaItem { refreshedItem ?? item }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero

                // These pad their own headings and the ends of their rows, so the rows scroll edge to edge.
                if isPlayableItem {
                    // An episode or movie has no rows of episodes or seasons beneath it.
                } else if isSeason {
                    // Already inside the season, so its episodes have no "Go to Season".
                    EpisodeShelf(season: item, reloadID: reloadCount, omitting: [.season], open: { openedShow = $0 }, play: { playingItem = $0 })
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
        }
        // The hero runs under the status and navigation bars, up to the top edge of the screen.
        .ignoresSafeArea(edges: .top)
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
        .onChange(of: nextEpisode?.id) { resetFocus(in: focusNamespace) }
        // An episode or movie has its Play button from the first frame, and the focus engine settles on whatever
        // comes first on the page (the description) before the preference is read. Ask again once it has settled,
        // only the first time so coming back to the page doesn't take focus from where the user was.
        .task {
            guard !didSettleFocus else { return }
            didSettleFocus = true
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
    }

    /// The backdrop, with the show's details stacked over its bottom-left corner.
    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            // A season has the show's logo (or its name, if there is none), then its own name beneath.
            ShowLogo(item: current, fallbackTitle: isSeason || isEpisode ? (item.seriesTitle ?? item.title) : nil)

            if isSeason {
                Text(item.seasonTitle)
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
            } else if isEpisode {
                // The episode's own name, with where it falls in the show beneath.
                Text(item.title)
                    .font(.title2.bold())
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
                    .accessibilityAddTraits(.isHeader)
                if let position = item.seasonEpisodeText {
                    Text(position)
                        .font(.callout)
                }
            }

            // As in the TV app, the short genre line is the bright one and the description recedes beneath it,
            // so the two read as different things without the genres fading into the artwork.
            if let details = detailsLine {
                Text(details)
                    .font(.callout)
                    .lineLimit(shortTextLineLimit)
            }

            if let tagline = current.tagline {
                Text(tagline)
                    .font(.callout.italic())
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(shortTextLineLimit)
            }

            if let overview = current.overview {
                TruncatingOverview(text: overview, lineLimit: 3, isFocusable: overviewIsFocusable) { showsOverview = true }
            }

            // The run (and whether it's over) on one line, the ratings on the next.
            VStack(alignment: .leading, spacing: 2) {
                if let status = statusLine {
                    Text(status)
                }
                if let ratings = ratingsLine {
                    Text(ratings)
                }
                if let technical = current.technicalLine {
                    Text(technical)
                }
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.white.opacity(0.75))

            // The trailer's label gives way to just its icon if the row doesn't fit.
            #if os(tvOS)
            // The row is never too wide for a TV (there's no trailer button), so there's nothing to choose between.
            // Choosing could rebuild the Play button as the hero's size settles, and lose the focus given to it.
            actionButtons(showsTrailerTitle: false, compactPlay: false)
                .padding(.top, 4)
            #else
            ViewThatFits(in: .horizontal) {
                actionButtons(showsTrailerTitle: true, compactPlay: false)
                actionButtons(showsTrailerTitle: false, compactPlay: false)
                actionButtons(showsTrailerTitle: false, compactPlay: true)
            }
            .padding(.top, 4)
            #endif
        }
        .foregroundStyle(.white)
        // The details sit on a dark fade whatever the appearance, so their secondary colors are the light ones.
        .environment(\.colorScheme, .dark)
        // How tall the details are, so the fade behind them can reach up past their top.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { detailsHeight = $0 }
        .padding(.horizontal)
        .padding(.bottom, 20)
        // If the details make the hero taller than its usual height, some artwork still shows above them, clear
        // of the navigation bar.
        .padding(.top, Self.minArtworkAboveDetails)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: heroMinHeight, alignment: .bottom)
        // The artwork runs edge to edge, past the side safe areas (e.g. under a sidebar tab bar in landscape),
        // while the details stay inside them.
        .background { backdrop.ignoresSafeArea(edges: .horizontal) }
    }

    /// The hero's usual height, like the TV app's: no taller than its width allows at `heroAspectRatio`, which keeps it
    /// short in portrait, and no more than `heroFraction` of the screen, which keeps it from filling a landscape
    /// screen. Taller only if the details need it.
    private var heroMinHeight: CGFloat {
        min(screenSize.height * Self.heroFraction, screenSize.width / Self.heroAspectRatio)
    }

    /// The hero's narrowest shape, width divided by height.
    private static let heroAspectRatio: CGFloat = 1.4

    /// The most of the screen's height the hero fills.
    private static var heroFraction: CGFloat {
        #if os(tvOS)
        return 1
        #else
        return 0.75
        #endif
    }

    /// The least artwork left showing above the details.
    private static var minArtworkAboveDetails: CGFloat {
        #if os(tvOS)
        return 0
        #else
        return 120
        #endif
    }

    /// How fast the artwork moves as the screen scrolls up, relative to the scrolling: 0.5 is half as fast.
    private static let parallaxSpeed: CGFloat = 0.5

    /// The show's backdrop (or poster, if it has none), filling the hero and darkening toward the bottom so the
    /// details read over any image.
    ///
    /// Like the TV app's, it scrolls with parallax: scrolling up, the artwork moves slower than the page, so it
    /// slides away behind the details; pulling down past the top, it stretches to fill the gap above it.
    private var backdrop: some View {
        // Read here rather than inside the effects, which run outside the main actor.
        let lag = 1 - Self.parallaxSpeed

        return Color.black
            .overlay {
                CachedAsyncImage(url: heroImageURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    }
                }
                // Purely visual; the overflow from filling the frame shouldn't take taps.
                .allowsHitTesting(false)
                // Scrolled up, the artwork is pushed back down by part of the distance, so it moves slower than
                // the page. What's pushed past the hero's bottom is clipped below.
                .visualEffect { content, proxy in
                    let top = proxy.frame(in: .scrollView).minY
                    return content.offset(y: top < 0 ? -top * lag : 0)
                }
            }
            .clipped()
            .overlay {
                // Eased rather than linear: it starts gently, so the artwork's top half is untouched, then deepens
                // behind the details. Easing also avoids the visible edge a straight ramp leaves where it begins.
                GeometryReader { proxy in
                    LinearGradient(
                        stops: scrimStops(heroHeight: proxy.size.height),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }
            // Pulled down past the top, the backdrop grows from its bottom edge to cover the gap the overscroll
            // opens above it. After the clip, so the growth isn't clipped away.
            .visualEffect { content, proxy in
                let top = proxy.frame(in: .scrollView).minY
                let height = proxy.size.height
                let scale = top > 0 && height > 0 ? (height + top) / height : 1
                return content.scaleEffect(scale, anchor: .bottom)
            }
            .accessibilityHidden(true)
    }

    /// Where the fade over the backdrop begins, as a fraction of the hero's height, when the details are short.
    private static let usualScrimStart: CGFloat = 0.3

    /// How far above the details the fade begins, so their first line isn't over bare artwork.
    private static let scrimLead: CGFloat = 60

    /// The fade's opacity at each fraction of its length, easing in from nothing to the strongest.
    private static let scrimProfile: [(position: CGFloat, opacity: Double)] = [
        (0, 0), (0.214, 0.2), (0.429, 0.5), (0.686, 0.7), (1, 0.85)
    ]

    /// The stops of the fade that darkens the backdrop behind the details.
    ///
    /// It usually begins 30% of the way down. With larger text or more lines the details are taller and would reach
    /// up past that, onto bare artwork where white text can be unreadable, so the fade begins above their top
    /// instead. The same shape is stretched over whatever length it has.
    private func scrimStops(heroHeight: CGFloat) -> [Gradient.Stop] {
        var start = Self.usualScrimStart
        if heroHeight > 0, detailsHeight > 0 {
            // The details, their bottom padding, and a little lead-in above them.
            let covered = detailsHeight + 20 + Self.scrimLead
            start = min(start, max(0, 1 - covered / heroHeight))
        }
        return Self.scrimProfile.map { step in
            Gradient.Stop(color: .black.opacity(step.opacity), location: start + (1 - start) * step.position)
        }
    }

    /// e.g. "Comedy · Drama · HBO": the genres, then the network the show aired on. Nil if neither is known.
    private var detailsLine: String? {
        let parts = current.genres + [current.network].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The hero's image: an episode's own still, otherwise the backdrop (or poster, if there is none).
    private var heroImageURL: URL? {
        isEpisode ? current.thumbnailURL ?? current.backdropURL ?? current.posterURL : current.backdropURL ?? current.posterURL
    }

    /// e.g. "Jan 5, 2001 · 45m": the day an episode aired and how long it runs. Nil if neither is known.
    private var episodeInfoLine: String? {
        var parts: [String] = []
        if let aired = current.airDate {
            // A calendar date stored at midnight UTC, so it's read in UTC or it can land on the day before.
            let utc = TimeZone(identifier: "UTC") ?? .gmt
            parts.append(aired.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: utc)))
        }
        if let runtime = current.runtime {
            parts.append(Duration.seconds(runtime).formatted(.units(allowed: [.hours, .minutes], width: .narrow)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// e.g. "Ended · 1999–2006" or "Continuing · 2019–Present": whether the show is still running, then the years
    /// it has run. Nil if the server says neither.
    private var statusLine: String? {
        // A season says how many episodes it has and when it came out; an episode, when it aired and how long it is.
        if current.kind == .season { return current.seasonDetailLine }
        if current.kind == .episode { return episodeInfoLine }
        // A movie says when it came out and how long it is.
        if current.kind == .movie { return current.metadataLine }

        let status: String? = switch current.status?.lowercased() {
        case "ended": String(localized: "Ended")
        case "continuing": String(localized: "Continuing")
        default: current.status
        }

        var years: String?
        if let start = current.year {
            let first = start.formatted(.number.grouping(.never))
            if let end = current.endYear, end != start {
                years = "\(first)–\(end.formatted(.number.grouping(.never)))"
            } else if current.endYear == nil, current.status?.lowercased() == "continuing" {
                years = "\(first)–" + String(localized: "Present")
            } else {
                years = first
            }
        }

        let parts = [status, years].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// e.g. "TV-MA · ★ 8.7 · 92% Critics": the content rating, the audience score out of 10, then the critics'
    /// score. Nil if none is known.
    private var ratingsLine: String? {
        let score = current.communityRating.map { "★ " + $0.formatted(.number.precision(.fractionLength(1))) }
        let critics = current.criticRating.map { String(localized: "\(Int($0.rounded()))% Critics") }
        let parts = [current.officialRating, score, critics].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Play, then Watch Trailer if the show has one, then the favorite button.
    private func actionButtons(showsTrailerTitle: Bool, compactPlay: Bool) -> some View {
        HStack(spacing: Self.buttonSpacing) {
            playButton(compact: compactPlay)
            trailerButton(showsTitle: showsTrailerTitle)
            #if os(tvOS)
            // There's no navigation bar on tvOS, so the favorite and watched buttons sit here. On iOS they're in
            // the toolbar (see `toolbarButtons`).
            favoriteButton
            watchedButton
            DownloadToolbarButton(item: current, prompt: $watchState.downloadPrompt)
                .heroCircleButton()
            #endif
        }
        // Moving focus up from anywhere along the page lands on these buttons.
        .tvFocusSection()
    }

    /// Space between the hero's buttons.
    /// (See also `heroCircleButton()` for how the round ones are styled.)
    private static var buttonSpacing: CGFloat {
        #if os(tvOS)
        return 24
        #else
        return 12
        #endif
    }

    /// What the watched button does: whether it marks the item watched (or unwatched), and how. Nil if it can't.
    private var watchedChange: (wantsWatched: Bool, perform: () -> Void)? {
        let wantsWatched = isPlayableItem ? !current.showsWatchedBadge : current.containerWatchOptions.canMarkWatched
        let actions = watchActions.actions(for: item)
        guard let perform = wantsWatched ? actions?.markWatched : actions?.markUnwatched else { return nil }
        return (wantsWatched, perform)
    }

    /// Marks the show, season or episode watched, or unwatched if it all is. For a show or season that changes every
    /// episode in it, so it asks first, like the menus do.
    @ViewBuilder
    private var watchedButton: some View {
        if let change = watchedChange {
            Button(action: change.perform) {
                Image(systemName: change.wantsWatched ? "checkmark.circle" : "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(change.wantsWatched ? .white : .green)
            }
            .heroCircleButton()
            .accessibilityLabel(change.wantsWatched ? "Mark as Watched" : "Mark as Unwatched")
        }
    }

    #if os(iOS)
    /// The favorite and watched buttons for the navigation bar, which keep their place as the page scrolls. They
    /// take the bar's own look, over the artwork or not.
    @ToolbarContentBuilder
    private var toolbarButtons: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                toggleFavorite()
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
            }
            .tint(isFavorite ? .red : nil)
            .accessibilityLabel(isFavorite ? "Remove from Favorites" : "Add to Favorites")

            // The whole show or season, or the episode or movie itself.
            DownloadToolbarButton(item: current, prompt: $watchState.downloadPrompt)

            if let change = watchedChange {
                Button(action: change.perform) {
                    Image(systemName: change.wantsWatched ? "checkmark.circle" : "checkmark.circle.fill")
                }
                .tint(change.wantsWatched ? nil : .green)
                .accessibilityLabel(change.wantsWatched ? "Mark as Watched" : "Mark as Unwatched")
                // VoiceOver would otherwise announce a checkmark image as "selected", which this is not.
                .accessibilityRemoveTraits(.isSelected)
            }
        }
    }
    #endif

    /// Opens the show's trailer on the web. Hidden if it has none, and on tvOS, which has no browser.
    @ViewBuilder
    private func trailerButton(showsTitle: Bool) -> some View {
        #if !os(tvOS)
        if let url = current.trailerURL {
            Button {
                openURL(url)
            } label: {
                if showsTitle {
                    Label("Watch Trailer", systemImage: "play.rectangle")
                        .font(.headline)
                } else {
                    Image(systemName: "play.rectangle")
                        .font(.headline)
                }
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .accessibilityLabel("Watch Trailer")
        }
        #endif
    }

    /// Adds the show to the user's favorites, or takes it off.
    private var favoriteButton: some View {
        Button {
            toggleFavorite()
        } label: {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .font(.headline)
                .foregroundStyle(isFavorite ? .red : .white)
        }
        .heroCircleButton()
        .accessibilityLabel(isFavorite ? "Remove from Favorites" : "Add to Favorites")
    }

    /// Whether the show is a favorite, counting a change the server hasn't confirmed yet.
    private var isFavorite: Bool { favoriteOverride ?? current.isFavorite }

    /// Flips the favorite at once, then tells the server. If that fails, it flips back and shows the error.
    private func toggleFavorite() {
        let wanted = !isFavorite
        favoriteOverride = wanted
        let service = appModel.service
        let id = item.id
        Task {
            do {
                try await service.setFavorite(wanted, itemID: id)
            } catch {
                favoriteOverride = !wanted
                watchState.errorMessage = error.localizedDescription
            }
        }
    }

    /// Plays the next episode, or resumes it if it's partly watched. Hidden if the show has no episodes.
    @ViewBuilder
    private func playButton(compact: Bool) -> some View {
        if let episode = nextEpisode {
            Button {
                playingItem = episode
            } label: {
                Label(isPlayableItem || compact ? ownPlayTitle(for: episode) : playTitle(for: episode), systemImage: "play.fill")
                    .font(.headline)
                    #if !os(tvOS)
                    // Dark on white, like the TV app's Play button; the hero's text is white otherwise.
                    .foregroundStyle(.black)
                    #endif
            }
            #if os(tvOS)
            // The same bordered style as the buttons beside it, so all of them take the theme's color when focused (the
            // prominent style draws light gray instead). Play is what's focused first.
            .buttonStyle(.bordered)
            .prefersDefaultFocus(true, in: focusNamespace)
            .focused($focusedControl, equals: .play)
            #else
            .buttonStyle(.glassProminent)
            .tint(.white)
            .controlSize(.large)
            #endif
        }
    }

    /// What the Play button says for `episode`; see ``MediaItem/playButtonTitle(forShow:)``.
    private func ownPlayTitle(for episode: MediaItem) -> String {
        episode.playButtonTitle(forShow: false)
    }

    private func playTitle(for episode: MediaItem) -> String {
        episode.playButtonTitle(forShow: true)
    }

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

    /// How many cast portraits are loaded before the Cast and Crew row shows: about as many as fit on screen at once.
    private static let preloadedPortraitCount = 12

    /// The longest to wait for those portraits before showing the row anyway.
    private static let portraitPreloadTimeout = Duration.seconds(2)

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
    private var watchActions: WatchActions {
        WatchActions(service: appModel.service, downloads: appModel.downloads, destination: nil, state: $watchState) { _ in
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

private extension View {
    /// The look of the hero's round icon buttons: Liquid Glass on iOS, and the standard bordered circle on tvOS, where
    /// a glass button is drawn all the time rather than only when it has focus.
    @ViewBuilder
    func heroCircleButton() -> some View {
        #if os(tvOS)
        buttonStyle(.bordered)
            .buttonBorderShape(.circle)
        #else
        buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
        #endif
    }
}
