// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

// Small reusable pieces shared by the browsing screens.

/// Shared layout constants.
enum Layout {
    /// Width of a widescreen card in shelves (extras); larger on tvOS.
    static var wideCardWidth: CGFloat {
        #if os(tvOS)
        return 320
        #else
        return 220
        #endif
    }

    /// Width of a poster in shelves; larger on tvOS for the "ten-foot" UI.
    static var posterWidth: CGFloat {
        #if os(tvOS)
        return 260
        #else
        return 130
        #endif
    }

    /// Space between a card's artwork and its caption. On tvOS the focused artwork grows and lifts, and would
    /// otherwise cover the caption.
    static var captionGap: CGFloat {
        #if os(tvOS)
        return 28
        #else
        return 6
        #endif
    }

    /// A shelf's heading. On tvOS the 57-point bold title2 is far larger than the Apple TV app's, whose row headings are
    /// about 30 points and semibold.
    static var shelfHeadingFont: Font {
        #if os(tvOS)
        return .callout.weight(.semibold)
        #else
        return .title2.bold()
        #endif
    }

    /// Space between a shelf's heading and its cards, with the same room for the focused card to lift into.
    static var shelfHeadingGap: CGFloat {
        #if os(tvOS)
        return 24
        #else
        return 8
        #endif
    }

    /// Space between the content's leading edge and the safe area's, for shelves and the carousel's text, so they line up.
    /// Nil is the system's usual padding. On tvOS it's less, to match the Apple TV app's margin.
    static var contentInset: CGFloat? {
        #if os(tvOS)
        return 16
        #else
        return nil
        #endif
    }

    /// Space between one shelf and the next.
    static var shelfSpacing: CGFloat {
        #if os(tvOS)
        return 48
        #else
        return 24
        #endif
    }

    /// Space between cards in a shelf or grid; tvOS needs room for the focused card to lift.
    static var cardSpacing: CGFloat {
        #if os(tvOS)
        return 40
        #else
        return 12
        #endif
    }
}

/// Gives a card its width, which grows with the text size (up to twice as wide) so the caption under the
/// artwork stays readable at accessibility sizes instead of being cut to a few letters.
private struct ScaledCardWidth: ViewModifier {
    private let base: CGFloat
    // The value here is replaced in `init`, where it's set from `base`.
    @ScaledMetric(relativeTo: .subheadline) private var width: CGFloat = 0

    init(base: CGFloat) {
        self.base = base
        _width = ScaledMetric(wrappedValue: base, relativeTo: .subheadline)
    }

    func body(content: Content) -> some View {
        content.frame(width: min(width, base * 2))
    }
}

extension View {
    /// Frames a card at `base` points wide, or wider at larger text sizes. See `ScaledCardWidth`.
    func cardWidth(_ base: CGFloat) -> some View {
        modifier(ScaledCardWidth(base: base))
    }
}

extension MediaItem {
    /// Whether the item can be played directly (as opposed to being a container like a series).
    var isPlayable: Bool { kind == .movie || kind == .episode || kind == .extra }

    /// What tells it apart from the others in a shelf. A playlist can hold the same movie twice, so there it's the entry's
    /// own ID rather than the item's.
    var shelfKey: String { playlistEntryID ?? id }

    /// e.g. "Show Name · S1E3" for episodes; nil for everything else.
    var subtitle: String? {
        guard kind == .episode else { return nil }
        var parts: [String] = []
        if let seriesTitle { parts.append(seriesTitle) }
        if let seasonNumber, let episodeNumber { parts.append("S\(seasonNumber)E\(episodeNumber)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// e.g. "2019 · 1h 52m"; nil if neither year nor runtime is known.
    var metadataLine: String? {
        var parts: [String] = []
        if let year { parts.append(String(year)) }
        if let runtime {
            parts.append(Duration.seconds(runtime).formatted(.units(allowed: [.hours, .minutes], width: .narrow)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// e.g. "Season 1 Episode 3"; nil unless the item has an episode number.
    var seasonEpisodeText: String? {
        switch (seasonNumber, episodeNumber) {
        case let (season?, episode?): String(localized: "Season \(String(season)) Episode \(episode)")
        case let (nil, episode?): String(localized: "Episode \(episode)")
        default: nil
        }
    }

    /// e.g. "Episode 3 · Jan 5, 2001": an episode's number and the day it aired, for where its season is already
    /// known. Whichever part is missing is left out; nil if both are.
    var episodeAirLine: String? {
        var parts: [String] = []
        if let episodeNumber { parts.append(String(localized: "Episode \(episodeNumber)")) }
        if let airDate {
            // A calendar date stored at midnight UTC, so it's read in UTC or it can land on the day before.
            let utc = TimeZone(identifier: "UTC") ?? .gmt
            parts.append(airDate.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: utc)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Whether to show the watched checkmark. An item that's partly watched (it has a resume position) is in
    /// progress, even if the server also flags it as played.
    var showsWatchedBadge: Bool { isPlayed && playedFraction == nil }

    /// The long-press menu's first entry, which opens the item: "Go to Movie", "Go to Episode", and so on.
    var goToMenuTitle: String {
        switch kind {
        case .movie: String(localized: "Go to Movie")
        case .episode: String(localized: "Go to Episode")
        case .series: String(localized: "Go to Show")
        case .season: String(localized: "Go to Season")
        case .extra: String(localized: "Go to Feature")
        case .collection: String(localized: "Go to Collection")
        case .playlist: String(localized: "Go to Playlist")
        case .other: String(localized: "Go to Item")
        }
    }

    /// For a show or season, which of "mark watched" and "mark unwatched" make sense for its episodes: both if
    /// some are watched and some aren't, only "unwatched" if all are watched, only "watched" if none are.
    var containerWatchOptions: (canMarkWatched: Bool, canMarkUnwatched: Bool) {
        if let total = episodeCount, total > 0, let unwatched = unwatchedEpisodeCount {
            return (canMarkWatched: unwatched > 0, canMarkUnwatched: unwatched < total)
        }
        // Without counts, the server's flag can only say everything is watched. If it isn't, it could be a mix
        // or nothing watched, so offer both.
        return isPlayed ? (canMarkWatched: false, canMarkUnwatched: true) : (canMarkWatched: true, canMarkUnwatched: true)
    }

    /// The widescreen image for the landscape shelf grid, falling back through the backdrop to the poster.
    var gridArtworkURL: URL? { thumbnailURL ?? backdropURL ?? posterURL }

    /// The line over a grid card's image, e.g. "S4, E6 · 46m left" or "1h 53m". Nil if there's nothing to say.
    var gridStatusLine: String? {
        var parts: [String] = []
        if kind == .episode, let episodeNumber {
            parts.append(seasonNumber.map { String(localized: "S\(String($0)), E\(episodeNumber)") } ?? String(localized: "E\(episodeNumber)"))
        }
        if let runtime {
            let remaining = playedFraction.map { runtime * (1 - $0) } ?? runtime
            let time = Duration.seconds(remaining).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
            parts.append(playedFraction == nil ? time : String(localized: "\(time) left"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Whether `ItemRow` shows widescreen artwork rather than a portrait poster. Only episodes and movies have
    /// a thumbnail.
    var hasWidescreenRowArtwork: Bool { thumbnailURL != nil }

    /// The artwork `ItemRow` shows: the widescreen thumbnail for episodes and movies, otherwise the poster.
    var rowArtworkURL: URL? {
        hasWidescreenRowArtwork ? thumbnailURL : posterURL
    }

    /// The text shown with an item's artwork, most important first:
    /// - movies and series: title, then release year
    /// - episodes: show title, then episode title, then "Season X Episode X"
    /// - seasons: show title, then season name
    var captionLines: [String] {
        switch kind {
        case .episode:
            [seriesTitle, title, seasonEpisodeText].compactMap { $0 }
        case .season:
            [seriesTitle, title].compactMap { $0 }
        case .movie, .series:
            [title, year.map(String.init)].compactMap { $0 }
        case .collection, .playlist:
            [title]
        case .extra:
            [title, extraLabel, runtime.map { Duration.seconds($0).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow)) }].compactMap { $0 }
        case .other:
            [title]
        }
    }

    /// What VoiceOver reads for an item's card or row: its caption, then how much of it has been watched.
    var accessibilityDescription: String {
        var parts = captionLines
        if showsWatchedBadge {
            parts.append(String(localized: "Watched"))
        } else if let playedFraction {
            let percent = playedFraction.formatted(.percent.precision(.fractionLength(0)))
            parts.append(String(localized: "\(percent) watched"))
        }
        return parts.joined(separator: ", ")
    }
}

extension MediaItem {
    /// What a Play button for this item says.
    ///
    /// For a movie or episode itself, "Play", or "Resume" if it's partly watched. For the episode a show's Play button
    /// starts, "Play First Episode" for season 1 episode 1, otherwise e.g. "Play S2, E4", and "Resume S1, E1" if it's
    /// partly watched, even the first episode.
    ///
    /// - Parameter isShow: Whether the button is for a show, which starts this episode, rather than for the item itself.
    func playButtonTitle(forShow isShow: Bool) -> String {
        let resumes = playedFraction != nil
        guard isShow else { return resumes ? String(localized: "Resume") : String(localized: "Play") }

        if !resumes, seasonNumber == 1, episodeNumber == 1 {
            return String(localized: "Play First Episode")
        }
        guard let number = episodeNumber else {
            return resumes ? String(localized: "Resume") : String(localized: "Play")
        }
        let code = seasonNumber.map { String(localized: "S\(String($0)), E\(number)") } ?? String(localized: "E\(number)")
        return resumes ? String(localized: "Resume \(code)") : String(localized: "Play \(code)")
    }
}

extension View {
    /// Registers navigation for media items and libraries; apply to the root of each NavigationStack.
    func mediaNavigationDestinations() -> some View {
        navigationDestination(for: MediaItem.self) { ItemDetailView(item: $0) }
            .navigationDestination(for: Library.self) { LibraryView(library: $0) }
            .navigationDestination(for: SortedLibrary.self) { LibraryView(library: $0.library, sort: $0.sort) }
            .navigationDestination(for: Genre.self) { GenreView(genre: $0) }
            .navigationDestination(for: ShelfDestination.self) { ShelfListView(destination: $0) }
    }

    /// Gives something drawn over artwork (a badge, a progress bar) a faint edge, so it doesn't vanish into
    /// artwork of a similar color. This plays the role `ArtworkView`'s outline does for the artwork itself;
    /// a soft shadow suits small shapes better than a stroke.
    func artworkOverlayEdge() -> some View {
        shadow(color: .black.opacity(0.4), radius: 2)
    }

    /// On tvOS, makes this view (a card's artwork and its overlays) the part that lifts and shines when the card is
    /// focused. Without it the button style picks the first image it finds, which isn't the whole artwork.
    @ViewBuilder
    func focusHighlight() -> some View {
        #if os(tvOS)
        hoverEffect(.highlight)
        #else
        self
        #endif
    }

    /// On tvOS, makes this view's frame guide focus to what's inside it. Does nothing elsewhere.
    @ViewBuilder
    func tvFocusSection() -> some View {
        #if os(tvOS)
        focusSection()
        #else
        self
        #endif
    }

    /// Link style that keeps cards looking like cards (and focusable on tvOS).
    @ViewBuilder
    func cardLinkStyle() -> some View {
        #if os(tvOS)
        buttonStyle(.borderless)
        #else
        buttonStyle(.plain)
        #endif
    }
}

/// A widescreen card for the landscape shelf grid: the image with a status line and the "more" button along
/// its bottom edge, and the item's caption beneath. It doesn't act on taps itself; see `peek`.
struct ShelfGridCard: View {
    let item: MediaItem
    var actions: ItemRowActions?

    /// Lines to show instead of the item's usual caption.
    var captionLines: [String]?

    /// If given, the card peeks and pops when long-pressed. See `peekAndPop(_:passthrough:isAccessibilityElement:)`.
    var peek: PeekAndPopSpec?

    /// The progress bar's size, scaled with the status text.
    /// The progress bar's thickness, and the shortest it gets when the status text needs the room. Otherwise
    /// it stretches to fill the bar. Scaled with the status text.
    @ScaledMetric(relativeTo: .subheadline) private var progressHeight: CGFloat = 4
    @ScaledMetric(relativeTo: .subheadline) private var progressMinWidth: CGFloat = 32

    /// How far the "more" button's corner reaches in from the edges: the padded button plus a little slack.
    /// Scaled with the button's text style, so it keeps up with larger text.
    @ScaledMetric(relativeTo: .title3) private var menuCornerWidth: CGFloat = 52
    @ScaledMetric(relativeTo: .title3) private var menuCornerHeight: CGFloat = 44

    /// The corner of the image the peek layer leaves for the "more" button, if there is one.
    private var menuCorner: PeekPassthrough {
        actions == nil ? .none : PeekPassthrough(trailing: menuCornerWidth, bottom: menuCornerHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.captionGap) {
            ArtworkView(url: item.gridArtworkURL, aspectRatio: 16.0 / 9.0)
                .overlay(alignment: .bottom) { statusBar }
                .overlay(alignment: .topTrailing) {
                    if item.showsWatchedBadge {
                        WatchedBadge()
                    }
                }
                .overlay(alignment: .topLeading) { DownloadedBadge(item: item) }
                // The status bar's gradient is square; clip it to the image's rounded corners.
                .clipShape(RoundedRectangle(cornerRadius: 8))
                // On tvOS, the artwork with its overlays is what lifts when the card is focused.
                .focusHighlight()
                // The image and the caption each get a peek layer, so the whole card responds. The image's
                // leaves the "more" button's corner alone, and the caption's isn't a second accessibility element.
                .peekAndPop(peek, passthrough: menuCorner)

            ItemCaption(item: item, lines: captionLines)
                .peekAndPop(peek, isAccessibilityElement: false)
        }
        // Make the whole card tappable, including the gaps between the artwork and text.
        .contentShape(Rectangle())
    }

    /// Play icon, progress, episode and time left, and the menu button, over a fade so they read on any image.
    private var statusBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "play.fill")
                .accessibilityHidden(true)

            if let fraction = item.playedFraction {
                // Fills the room between the play icon and the status text, so there's no empty gap.
                Capsule()
                    .fill(.white.opacity(0.3))
                    .frame(minWidth: progressMinWidth, maxWidth: .infinity)
                    .frame(height: progressHeight)
                    .overlay(alignment: .leading) {
                        GeometryReader { proxy in
                            Capsule()
                                .fill(.white)
                                .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                        }
                    }
                    .accessibilityHidden(true)
            }

            if let status = item.gridStatusLine {
                Text(status)
                    .lineLimit(1)
                    // The progress bar gives up its room before the text truncates.
                    .layoutPriority(1)
            }

            // With no progress bar to fill the room, keep the "more" button at the trailing edge.
            if item.playedFraction == nil {
                Spacer()
            }

            #if !os(tvOS)
            if let actions {
                ItemActionsMenu(item: item, actions: actions, overArtwork: true)
            }
            #endif
        }
        .font(.subheadline.weight(.semibold))
        // The bar sits on artwork that doesn't grow with the text, so at accessibility sizes its time left was cut to
        // a few characters. It stops growing at the largest regular size, which still fits.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .foregroundStyle(.white)
        // The same height with or without the "more" button, so every card's bar lines up.
        .frame(minHeight: ItemActionsMenu.minimumTarget)
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.top, 32)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
    }
}

#Preview("PosterCard") {
    HStack(alignment: .top) {
        PosterCard(item: .previewMovie)
        PosterCard(item: .previewPartlyWatched)
        PosterCard(item: .previewWatched)
        PosterCard(item: .previewEpisode)
    }
    .padding()
}

#Preview("MediaShelf") {
    @Previewable @State var goToItem: MediaItem?
    NavigationStack {
        MediaShelf(
            title: "Continue Watching",
            items: MediaItem.previewMovies,
            navigation: ItemNavigation(open: { goToItem = $0 }, play: { _ in })
        )
        .mediaNavigationDestinations()
        .navigationDestination(item: $goToItem) { ItemDetailView(item: $0) }
    }
    .environment(AppModel.preview())
}

/// An episode (which has a subtitle) between cards that don't: all three should get equal artwork.
#Preview("MediaShelf mixed subtitles") {
    @Previewable @State var goToItem: MediaItem?
    NavigationStack {
        MediaShelf(
            title: "Recently Added Shows",
            items: [.previewMovie, .previewEpisode, .previewWatched],
            destination: .continueWatching,
            navigation: ItemNavigation(open: { goToItem = $0 }, play: { _ in })
        )
        .mediaNavigationDestinations()
        .navigationDestination(item: $goToItem) { ItemDetailView(item: $0) }
    }
    .environment(AppModel.preview())
}

#Preview("ItemRow") {
    List(MediaItem.previewMovies + [.previewEpisode]) { ItemRow(item: $0) }
}

#Preview("ShelfGridCard") {
    HStack(alignment: .top, spacing: 16) {
        ShelfGridCard(item: .previewEpisode, actions: ItemRowActions(markWatched: {}, markUnwatched: {}))
        ShelfGridCard(item: .previewPartlyWatched, actions: ItemRowActions(markWatched: {}, markUnwatched: {}))
    }
    .padding()
}

#Preview("ArtworkView") {
    ArtworkView(url: nil, aspectRatio: 16.0 / 9.0)
        .padding()
}
