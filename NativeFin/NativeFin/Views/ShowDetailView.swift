// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
#if os(iOS)
import WebKit
#endif

/// Detail for a show, one of its seasons, or one of its episodes: a full-width hero image running up to the top
/// edge of the screen, with the show's logo, genres and network, synopsis, and a Play button over it. A show's
/// seasons are listed below (or its episodes, if it has a single season); a season's episodes are.
///
/// A season's or episode's page is the show's page narrowed to it: the same hero and rows, showing only what the
/// season or episode itself has. An episode's hero is its own still, under the show's logo.
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

    /// Whether the full list of special features is open.
    @State private var showsFeatureList = false

    /// Whether the full list behind "More Like This" is open.
    @State private var showsSimilar = false

    /// The show a tap or peek in "More Like This" is opening.
    @State private var openedShow: MediaItem?

    /// A favorite change the server hasn't confirmed yet, shown meanwhile.
    @State private var favoriteOverride: Bool?

    @Environment(\.openURL) private var openURL

    private var isSeason: Bool { item.kind == .season }
    private var isEpisode: Bool { item.kind == .episode }

    /// The latest copy of the show or season. A season shows only what it has itself (genres, ratings, tagline,
    /// trailer, description, cast), with nothing borrowed from its show.
    private var current: MediaItem { refreshedItem ?? item }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero

                // These pad their own headings and the ends of their rows, so the rows scroll edge to edge.
                if isEpisode {
                    // An episode has no rows of episodes or seasons beneath it.
                } else if isSeason {
                    // Already inside the season, so its episodes have no "Go to Season".
                    EpisodeShelf(season: item, reloadID: reloadCount, omitting: [.season], open: { openedShow = $0 }, play: { playingItem = $0 })
                } else {
                    ItemChildrenList(item: item, reloadID: reloadCount, open: { openedShow = $0 }, play: { playingItem = $0 }) { watchActions.actions(for: $0) }
                }

                if !specialFeatures.isEmpty {
                    MediaShelf(
                        title: String(localized: "Special Features"),
                        items: specialFeatures,
                        onHeadingTap: { showsFeatureList = true },
                        isWide: true,
                        // Tapping an extra plays it; its peek and "Go to Feature" open its page.
                        navigation: ItemNavigation(open: { openedShow = $0 }, play: { playingItem = $0 })
                    )
                }

                CastAndCrewShelf(people: current.people)

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
        .navigationTitle(item.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        // The logo over the hero already names the show.
        .toolbar(removing: .title)
        .toolbar { toolbarButtons }
        #endif
        .task(id: reloadCount) { await load() }
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
                    .lineLimit(3)
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
                    .lineLimit(2)
            }

            if let tagline = current.tagline {
                Text(tagline)
                    .font(.callout.italic())
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
            }

            if let overview = current.overview {
                TruncatingOverview(text: overview, lineLimit: 3) { showsOverview = true }
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
            ViewThatFits(in: .horizontal) {
                actionButtons(showsTrailerTitle: true, compactPlay: false)
                actionButtons(showsTrailerTitle: false, compactPlay: false)
                actionButtons(showsTrailerTitle: false, compactPlay: true)
            }
            .padding(.top, 4)
        }
        .foregroundStyle(.white)
        // The details sit on a dark fade whatever the appearance, so their secondary colors are the light ones.
        .environment(\.colorScheme, .dark)
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
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.3),
                        .init(color: .black.opacity(0.2), location: 0.45),
                        .init(color: .black.opacity(0.5), location: 0.6),
                        .init(color: .black.opacity(0.7), location: 0.78),
                        .init(color: .black.opacity(0.85), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
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
        HStack(spacing: 12) {
            playButton(compact: compactPlay)
            trailerButton(showsTitle: showsTrailerTitle)
            #if os(tvOS)
            // There's no navigation bar on tvOS, so the favorite and watched buttons sit here. On iOS they're in
            // the toolbar (see `toolbarButtons`).
            favoriteButton
            watchedButton
            #endif
        }
    }

    /// What the watched button does: whether it marks the item watched (or unwatched), and how. Nil if it can't.
    private var watchedChange: (wantsWatched: Bool, perform: () -> Void)? {
        let wantsWatched = isEpisode ? !current.showsWatchedBadge : current.containerWatchOptions.canMarkWatched
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
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
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
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
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
                Label(isEpisode || compact ? ownPlayTitle(for: episode) : playTitle(for: episode), systemImage: "play.fill")
                    .font(.headline)
                    // Dark on white, like the TV app's Play button; the hero's text is white otherwise.
                    .foregroundStyle(.black)
            }
            .buttonStyle(.glassProminent)
            .tint(.white)
            .controlSize(.large)
        }
    }

    /// "Play First Episode" for season 1 episode 1, otherwise e.g. "Play S2, E4". "Resume S1, E1" if it's partly
    /// watched, even the first episode.
    private func ownPlayTitle(for episode: MediaItem) -> String {
        episode.playedFraction != nil ? String(localized: "Resume") : String(localized: "Play")
    }

    private func playTitle(for episode: MediaItem) -> String {
        let resumes = episode.playedFraction != nil
        if !resumes, episode.seasonNumber == 1, episode.episodeNumber == 1 {
            return String(localized: "Play First Episode")
        }
        guard let number = episode.episodeNumber else {
            return resumes ? String(localized: "Resume") : String(localized: "Play")
        }
        let code = episode.seasonNumber.map { String(localized: "S\(String($0)), E\(number)") } ?? String(localized: "E\(number)")
        return resumes ? String(localized: "Resume \(code)") : String(localized: "Play \(code)")
    }

    /// Fetches the episode to play, and the show again (for its full details, and after playback or a change so
    /// the screen shows where the user got to). Keeps what's on screen if either fails; it's only out of date.
    private func load() async {
        if isSeason {
            await loadSeason()
            return
        }
        if isEpisode {
            await loadEpisode()
            return
        }

        // This screen can be reused for another show (one opened from another's "More Like This"), so nothing
        // fetched for the last one may linger.
        if refreshedItem?.id != item.id { refreshedItem = nil }

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
            similarShows = similar
        }
        if let features = try? await features {
            specialFeatures = features
        }
    }

    /// Fetches an episode again (for its cast and where it got to) and its special features. The Play button plays the
    /// episode itself. Keeps what's on screen if any of it fails; it's only out of date.
    private func loadEpisode() async {
        if refreshedItem?.id != item.id { refreshedItem = nil }
        nextEpisode = nextEpisode ?? item

        let service = appModel.service
        async let latest = service.item(id: item.id)
        async let features = service.specialFeatures(of: item)

        if let latest = try? await latest {
            refreshedItem = latest
            nextEpisode = latest
        }
        if let features = try? await features {
            specialFeatures = features
        }
    }

    /// Fetches a season again, its episodes (for what Play starts) and its special features. Keeps
    /// what's on screen if any of it fails; it's only out of date.
    private func loadSeason() async {
        if refreshedItem?.id != item.id { refreshedItem = nil }

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
        WatchActions(service: appModel.service, destination: nil, state: $watchState) { _ in
            reloadCount += 1
        }
    }
}

/// A horizontally scrolling row of the show's cast and crew: a round portrait, the name, and the character or job.
/// Hidden if the server lists no one.
private struct CastAndCrewShelf: View {
    let people: [MediaPerson]

    /// The width of one person's column. Larger on tvOS for the "ten-foot" UI.
    private static var cardWidth: CGFloat {
        #if os(tvOS)
        return 260
        #else
        return 130
        #endif
    }

    /// The person a tap or peek is opening, and the one whose photo is showing full screen.
    @State private var openedPerson: MediaPerson?
    @State private var photoPerson: MediaPerson?

    /// Whether the list of everyone is open.
    @State private var showsFullCast = false

    var body: some View {
        if !people.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ShelfHeadingLink(title: "Cast and Crew") { showsFullCast = true }
                    .padding(.horizontal)

                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(people) { person in
                            PersonCard(person: person, size: Self.cardWidth)
                                .frame(width: Self.cardWidth)
                                .personPeek(person, open: { openedPerson = person }, viewPhoto: { photoPerson = person })
                        }
                    }
                    .padding(.horizontal)
                }
                .scrollIndicators(.hidden)
                // Presented from here rather than from a card, because cards sit in a lazy stack, where SwiftUI
                // ignores destinations.
                .navigationDestination(item: $openedPerson) { PersonDetailView(person: $0) }
                .fullScreenCover(item: $photoPerson) { PhotoViewer(person: $0) }
                .navigationDestination(isPresented: $showsFullCast) { CastListView(people: people) }
            }
        }
    }
}

/// Every cast and crew member as a list of rows.
struct CastListView: View {
    let people: [MediaPerson]

    /// The person a tap or peek is opening, and the one whose photo is showing full screen.
    @State private var openedPerson: MediaPerson?
    @State private var photoPerson: MediaPerson?

    var body: some View {
        List(people) { person in
            row(for: person)
                .personPeek(person, open: { openedPerson = person }, viewPhoto: { photoPerson = person })
        }
        .listStyle(.plain)
        .navigationTitle("Cast and Crew")
        .navigationDestination(item: $openedPerson) { PersonDetailView(person: $0) }
        .fullScreenCover(item: $photoPerson) { PhotoViewer(person: $0) }
    }

    private func row(for person: MediaPerson) -> some View {
        HStack(spacing: 12) {
                PersonPortrait(person: person, size: 56)

                VStack(alignment: .leading, spacing: 2) {
                    Text(person.name)
                        .font(.body.weight(.semibold))
                    if let subtitle = person.subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        .accessibilityElement(children: .combine)
    }
}

/// A person's portrait and name over everything else on the server they're credited on, as posters that open
/// each movie or show.
struct PersonDetailView: View {
    let person: MediaPerson

    @Environment(AppModel.self) private var appModel

    /// Whether the photo is showing full screen.
    @State private var showsPhoto = false

    /// What the server knows about them. Nil until it arrives, or if it can't be fetched; it's only extra.
    @State private var details: PersonDetails?

    /// Whether the sheet with the whole biography is showing.
    @State private var showsBiography = false

    @Environment(\.openURL) private var openURL

    /// A watch-state change waiting for confirmation, or an error to show.
    @State private var watchState = WatchActionState()

    /// Bumped to reload their movies and shows after a change on the server.
    @State private var reloadCount = 0

    /// The movie or show a tap, peek or "Go to …" is opening.
    @State private var openedItem: MediaItem?

    private var watchActions: WatchActions {
        WatchActions(service: appModel.service, destination: nil, state: $watchState) { _ in
            reloadCount += 1
        }
    }

    /// Movies and shows can't be played from here, so only "Go to …" and its peek use this: both open the item.
    private var navigation: ItemNavigation {
        ItemNavigation(open: { openedItem = $0 }, play: { _ in })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 16) {
                    // Tapping the photo opens it full screen, if there is one.
                    Button { showsPhoto = true } label: {
                        PersonPortrait(person: person, size: 120)
                    }
                    .buttonStyle(.plain)
                    .disabled(person.imageURL == nil)
                    .accessibilityLabel("View Photo of \(person.name)")

                    VStack(alignment: .leading, spacing: 4) {
                        Text(person.name)
                            .font(.title2.bold())
                        if let subtitle = person.subtitle {
                            Text(subtitle)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)

                if let details, !details.isEmpty {
                    detailsSection(details)
                }

                AsyncContent(load: { try await appModel.service.items(featuring: person.personID) }, reloadID: reloadCount) { found in
                    credits(found)
                }
            }
            .padding()
        }
        .navigationTitle(person.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .fullScreenCover(isPresented: $showsPhoto) { PhotoViewer(person: person) }
        .sheet(isPresented: $showsBiography) {
            ShowOverviewSheet(title: person.name, subtitle: person.subtitle, overview: details?.biography)
        }
        .task { details = try? await appModel.service.details(ofPerson: person.personID) }
        .watchActionAlerts(watchActions)
        .navigationDestination(item: $openedItem) { ItemDetailView(item: $0) }
        #if !os(tvOS)
        .toolbar {
            if let webpage = details?.webpage {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: webpage)
                }
            }
        }
        #endif
    }

    /// When and where they were born (and died), their biography, and a link to read more.
    private func detailsSection(_ details: PersonDetails) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.factLines(for: details).enumerated()), id: \.offset) { _, line in
                // Like the genre line on a show's page: callout size, in the bright primary color.
                Text(line)
                    .font(.callout)
                    .lineLimit(2)
            }

            if let biography = details.biography {
                // The same as the description over a show's artwork: cut off, and if it doesn't fit, a MORE
                // button that opens the whole of it.
                TruncatingOverview(text: biography, lineLimit: 3, foreground: .primary) { showsBiography = true }
                    .padding(.top, 4)
            }

            #if os(iOS)
            if let webpage = details.webpage {
                let title = webpage.host()?.contains("imdb") == true ? String(localized: "View on IMDb") : String(localized: "View on TMDb")
                Link(destination: webpage) {
                    Label(title, systemImage: "arrow.up.right.square")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.glass)
                // Long-press previews the page, and tapping the preview opens it, like the posters.
                .peekAndPop(PeekAndPopSpec(
                    menu: [
                        ItemMenuEntry(id: .openLink, title: String(localized: "Open Link"), systemImage: "arrow.up.right.square") { openURL(webpage) },
                        ItemMenuEntry(id: .copyLink, title: String(localized: "Copy Link"), systemImage: "doc.on.doc") { UIPasteboard.general.url = webpage }
                    ],
                    accessibilityLabel: title,
                    onTap: { openURL(webpage) },
                    onOpen: { openURL(webpage) },
                    peek: WebPagePreview(url: webpage)
                ))
                .padding(.top, 4)
            }
            #endif
        }
    }

    /// e.g. "Born June 1, 1960 (age 65)", "Born in Los Angeles, USA", "Died March 3, 2020 (age 59)".
    private static func factLines(for details: PersonDetails) -> [String] {
        // Birth and death dates are calendar dates stored at midnight UTC, so they're read in UTC.
        let utc = TimeZone(identifier: "UTC") ?? .gmt
        let style = Date.FormatStyle(date: .long, time: .omitted, timeZone: utc)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc

        var lines: [String] = []
        if let born = details.birthDate {
            let end = details.deathDate ?? .now
            let age = calendar.dateComponents([.year], from: born, to: end).year
            // An age is only worth showing for the living; for the dead it's their age at death, shown on that line.
            let ageText = details.deathDate == nil ? age.map { String(localized: " (age \($0))") } ?? "" : ""
            lines.append(String(localized: "Born \(born.formatted(style))") + ageText)
        }
        if let died = details.deathDate {
            let age = details.birthDate.flatMap { calendar.dateComponents([.year], from: $0, to: died).year }
            let ageText = age.map { String(localized: " (age \($0))") } ?? ""
            lines.append(String(localized: "Died \(died.formatted(style))") + ageText)
        }
        if let place = details.birthplace {
            lines.append(String(localized: "Born in \(place)"))
        }
        return lines
    }

    /// The movies, then the shows, each under a heading.
    @ViewBuilder
    private func credits(_ credits: [PersonCredit]) -> some View {
        if credits.isEmpty {
            ContentUnavailableView("Nothing Else on This Server", systemImage: "film.stack")
        } else {
            VStack(alignment: .leading, spacing: 24) {
                posterGrid("Movies", credits.filter { $0.item.kind == .movie })
                posterGrid("Shows", credits.filter { $0.item.kind == .series })
            }
        }
    }

    @ViewBuilder
    private func posterGrid(_ title: LocalizedStringKey, _ credits: [PersonCredit]) -> some View {
        if !credits.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: Layout.posterWidth), spacing: 12, alignment: .top)], spacing: 16) {
                    ForEach(credits) { credit in
                        creditPeek(credit)
                    }
                }
            }
        }
    }

    /// A credit that opens its movie or show when tapped, and peeks and pops when long-pressed, with a menu to
    /// open it or change its watch state.
    @ViewBuilder
    private func creditPeek(_ credit: PersonCredit) -> some View {
        let item = credit.item
        let actions = watchActions.actions(for: item, navigation: navigation)
        #if os(iOS)
        // A UIKit layer over the card, so that tapping the preview can open the item. SwiftUI's preview can't.
        creditCard(credit)
            .peekAndPop(PeekAndPopSpec(
                menu: actions?.menuEntries(for: item) ?? [],
                accessibilityLabel: item.accessibilityDescription,
                onTap: { openedItem = item },
                onOpen: { openedItem = item },
                peek: ItemPeek(item: item)
            ))
        #else
        Button { openedItem = item } label: {
            creditCard(credit)
        }
        .cardLinkStyle()
        .contextMenu {
            ItemActionButtons(entries: actions?.menuEntries(for: item) ?? [])
        } preview: {
            ItemPeek(item: item)
        }
        #endif
    }

    /// A poster with the title and year, then what the person did on it.
    private func creditCard(_ credit: PersonCredit) -> some View {
        let role = credit.roles.compactMap(\.subtitle).joined(separator: ", ")

        return VStack(alignment: .leading, spacing: 6) {
            ArtworkView(url: credit.item.posterURL, aspectRatio: 2.0 / 3.0)
                .overlay(alignment: .topTrailing) {
                    if credit.item.showsWatchedBadge {
                        WatchedBadge()
                    }
                }

            ItemCaption(item: credit.item)

            if !role.isEmpty {
                Text(role)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

extension MediaPerson {
    /// The character for an actor, otherwise the job.
    fileprivate var subtitle: String? {
        switch role {
        case .actor: character
        case .director: String(localized: "Director")
        case .writer: String(localized: "Writer")
        case .producer: String(localized: "Producer")
        case .creator: String(localized: "Creator")
        case .composer: String(localized: "Composer")
        }
    }
}

/// A round portrait, or a person icon if there's none.
private struct PersonPortrait: View {
    let person: MediaPerson

    /// The portrait's width and height.
    let size: CGFloat

    var body: some View {
        // A fixed square, so a long name or character beside it can't squeeze the portrait smaller.
        Color.secondary.opacity(0.2)
            .frame(width: size, height: size)
            .overlay {
                CachedAsyncImage(url: person.imageURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: "person.fill")
                            .font(size > 80 ? .title : .body)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .clipShape(Circle())
    }
}

extension View {
    /// Makes a person's card or row open their page when tapped, and peek and pop when long-pressed, with a menu
    /// to open the page or view their photo. The same way an item's card works on the home screen.
    @ViewBuilder
    fileprivate func personPeek(_ person: MediaPerson, open: @escaping () -> Void, viewPhoto: @escaping () -> Void) -> some View {
        let menu = person.menuEntries(open: open, viewPhoto: viewPhoto)
        #if os(iOS)
        // A UIKit layer over the card, so that tapping the preview can open the page. SwiftUI's preview can't.
        peekAndPop(PeekAndPopSpec(
            menu: menu,
            accessibilityLabel: [person.name, person.subtitle].compactMap { $0 }.joined(separator: ", "),
            onTap: open,
            onOpen: open,
            peek: PersonPeek(person: person)
        ))
        #else
        Button(action: open) { self }
            .cardLinkStyle()
            .contextMenu {
                ItemActionButtons(entries: menu)
            } preview: {
                PersonPeek(person: person)
            }
        #endif
    }
}

extension MediaPerson {
    /// The long-press menu: open their page, and view their photo if they have one.
    fileprivate func menuEntries(open: @escaping () -> Void, viewPhoto: @escaping () -> Void) -> [ItemMenuEntry] {
        var entries = [ItemMenuEntry(id: .goTo, title: String(localized: "Go to Person"), systemImage: "person.crop.circle", perform: open)]
        if imageURL != nil {
            entries.append(ItemMenuEntry(id: .viewPhoto, title: String(localized: "View Photo"), systemImage: "photo", perform: viewPhoto))
        }
        return entries
    }
}

/// What a long-press on a person previews: their photo, name, and what they did.
private struct PersonPeek: View {
    let person: MediaPerson

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkView(url: person.largeImageURL ?? person.imageURL, aspectRatio: 1)

            Text(person.name)
                .font(.subheadline.weight(.medium))

            if let subtitle = person.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: ItemPeek.width)
    }
}

#if os(iOS)
/// A web page, loaded for a link's peek.
private struct WebPagePreview: View {
    let url: URL

    var body: some View {
        WebPageView(url: url)
            .frame(width: ItemPeek.width, height: 440)
    }
}

private struct WebPageView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
}
#endif

/// A person's photo filling the screen. Tap it, or the close button, to dismiss.
private struct PhotoViewer: View {
    let person: MediaPerson

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            CachedAsyncImage(url: person.largeImageURL ?? person.imageURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                case .empty:
                    ProgressView().tint(.white)
                default:
                    Image(systemName: "person.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { dismiss() }
            .accessibilityLabel(person.name)

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .padding(10)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .padding()
            .accessibilityLabel("Close")
        }
        .environment(\.colorScheme, .dark)
    }
}

/// One person: a round portrait, their name, and what they did.
private struct PersonCard: View {
    let person: MediaPerson

    /// The portrait's width and height.
    let size: CGFloat

    var body: some View {
        VStack(spacing: 6) {
            PersonPortrait(person: person, size: size)

            Text(person.name)
                .font(.footnote.weight(.semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let subtitle = person.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .combine)
    }
}

/// The show's logo, or its name typed out if it has no logo (or the logo can't load).
private struct ShowLogo: View {
    let item: MediaItem

    /// What to type out instead of the item's own title, if there is no logo. Nil to use the title.
    var fallbackTitle: String?

    /// The largest the logo gets. Logos vary from wide wordmarks to near-square badges, so both are capped.
    private static var maxSize: CGSize {
        #if os(tvOS)
        return CGSize(width: 600, height: 220)
        #else
        return CGSize(width: 280, height: 110)
        #endif
    }

    var body: some View {
        if let url = item.logoURL {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: Self.maxSize.width, maxHeight: Self.maxSize.height, alignment: .bottomLeading)
                        .accessibilityLabel(item.title)
                        .accessibilityAddTraits(.isHeader)
                case .empty:
                    // Hold the logo's room while it loads, rather than flashing the name first.
                    Color.clear
                        .frame(width: Self.maxSize.width, height: Self.maxSize.height)
                default:
                    title
                }
            }
        } else {
            title
        }
    }

    private var title: some View {
        Text(fallbackTitle ?? item.title)
            .font(.largeTitle.bold())
            .lineLimit(3)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A description cut off at `lineLimit` lines. If it doesn't fit, its last line fades out into a MORE button.
private struct TruncatingOverview: View {
    let text: String
    let lineLimit: Int

    /// The color of the text and of MORE. White over the show's artwork; the primary color elsewhere.
    var foreground: Color = .white

    /// Called when MORE is tapped.
    let onMore: () -> Void

    /// The heights of the text as shown, of all of it at the same width, and of one line.
    @State private var shownHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0
    @State private var lineHeight: CGFloat = 0

    /// The width of the MORE button, which the last line leaves room for.
    @State private var moreWidth: CGFloat = 0

    /// How far the last line fades out before the MORE button.
    private static let fadeWidth: CGFloat = 32

    /// Whether the text needs more lines than it's allowed. Half a point of slack absorbs rounding.
    private var isTruncated: Bool { fullHeight > shownHeight + 0.5 }

    var body: some View {
        Text(text)
            .font(.callout)
            // Dimmer than the genre line above it, but brighter than the system's secondary gray, whose
            // transparency lets busy artwork show through, like the TV app's.
            .foregroundStyle(foreground.opacity(0.75))
            .lineLimit(lineLimit)
            // Full width, so the hidden copies below wrap at the same width as the text on screen.
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shownHeight = $0 }
            .background(alignment: .topLeading) { measurements }
            .mask {
                if isTruncated { truncationMask } else { Rectangle() }
            }
            .overlay(alignment: .bottomTrailing) {
                if isTruncated { moreButton }
            }
    }

    /// Invisible copies of the text that measure how tall all of it is, and how tall one line is.
    private var measurements: some View {
        ZStack(alignment: .topLeading) {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
            Text(verbatim: " ")
                .font(.callout)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { lineHeight = $0 }
        }
        .hidden()
        .accessibilityHidden(true)
    }

    /// Shows every line in full except the last, which fades out just before the MORE button.
    private var truncationMask: some View {
        VStack(spacing: 0) {
            Rectangle()
            HStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: Self.fadeWidth)
                Color.clear
                    // A little gap, so the text doesn't run up against the glass edge.
                    .frame(width: moreWidth + 6)
            }
            .frame(height: lineHeight)
        }
    }

    private var moreButton: some View {
        Button(action: onMore) {
            Text("MORE")
                .font(.caption.weight(.bold))
                .foregroundStyle(foreground)
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { moreWidth = $0 }
        // The glass is taller than a line of text, so it's centered on the last line and overhangs it a little.
        .frame(height: lineHeight)
        .accessibilityLabel("More")
        .accessibilityHint("Shows the full description")
    }
}

/// The show's name and genres, centered, above its full description.
private struct ShowOverviewSheet: View {
    let title: String

    /// A line under the title, e.g. the genres. Nil for none.
    let subtitle: String?

    let overview: String?

    init(item: MediaItem) {
        self.init(title: item.title, subtitle: item.genres.isEmpty ? nil : item.genres.joined(separator: " · "), overview: item.overview)
    }

    init(title: String, subtitle: String?, overview: String?) {
        self.title = title
        self.subtitle = subtitle
        self.overview = overview
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text(title)
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)

                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let overview {
                    Text(overview)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 16)
                }
            }
            .multilineTextAlignment(.center)
            .padding()
            .padding(.top, 8)
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
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
