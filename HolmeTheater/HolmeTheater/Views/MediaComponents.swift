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

/// Remote image with a placeholder, cropped to a fixed aspect ratio.
struct ArtworkView: View {
    /// The image to load. A nil URL shows the placeholder.
    let url: URL?

    /// Width divided by height, e.g. `2.0 / 3.0` for a poster.
    let aspectRatio: CGFloat

    #if os(tvOS)
    private static let cornerRadius: CGFloat = 12
    #else
    private static let cornerRadius: CGFloat = 8
    #endif

    var body: some View {
        Color.secondary.opacity(0.2)
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .empty where url != nil:
                        ProgressView()
                    default:
                        Image(systemName: "film")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
                }
                // The image is purely visual. A fill-scaled image overflows its frame (a widescreen
                // episode still in a portrait slot, say). Clipping hides the overflow but doesn't stop
                // it receiving taps, so without this it would steal taps from neighboring cards.
                .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
            // A faint outline gives artwork whose background matches the screen's (white or black) an edge.
            // It's inset, and the primary color flips with light and dark mode, so it stays subtle on artwork
            // that already stands out.
            .overlay {
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .strokeBorder(.primary.opacity(0.15), lineWidth: 1)
            }
    }
}

/// The text beneath an item's artwork: its first caption line as a title, then the rest as detail lines.
/// See `MediaItem.captionLines` for what each kind of item shows.
struct ItemCaption: View {
    let item: MediaItem

    /// Pads with blank lines up to this many, so cards of different kinds in one row are the same height.
    /// Without it, the row's tallest card squeezes the artwork of the shorter ones.
    var reservedLines = 0

    /// Lines to show instead of the item's usual caption.
    var lines: [String]?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let lines = lines ?? item.captionLines

        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                Text(line)
                    .font(index == 0 ? .subheadline.weight(.medium) : .caption)
                    .foregroundStyle(index == 0 ? .primary : .secondary)
                    // Cards are a fixed width, so at accessibility sizes a one-line title would be cut to a few letters.
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
            }

            ForEach(lines.count..<max(lines.count, reservedLines), id: \.self) { _ in
                Text(" ")
                    .font(.caption)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// The green checkmark in the corner of watched artwork.
struct WatchedBadge: View {
    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            // Large enough to spot at a glance on a busy poster.
            .font(.title)
            // It sits on artwork that doesn't grow with the text (a 130pt poster), so at accessibility sizes it
            // would cover most of the poster.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .foregroundStyle(.white, .green)
            .artworkOverlayEdge()
            .padding(6)
            .accessibilityLabel("Watched")
    }
}

#if os(tvOS)
/// The strip along the bottom of a widescreen card's picture: a play icon, how far through it is, and what's left or
/// how long it is (e.g. "S4, E4 · 33m"), over a fade so it reads on any picture.
private struct WideCardStatus: View {
    let item: MediaItem

    var body: some View {
        if item.playedFraction != nil || item.gridStatusLine != nil {
            HStack(spacing: 10) {
                Image(systemName: "play.fill")
                    .accessibilityHidden(true)

                if let fraction = item.playedFraction {
                    Capsule()
                        .fill(.white.opacity(0.3))
                        .frame(width: 70, height: 4)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(.white)
                                .frame(width: 70 * min(max(fraction, 0), 1))
                        }
                        .accessibilityHidden(true)
                }

                if let status = item.gridStatusLine {
                    Text(status)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .padding(.top, 36)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
            // Square at the top, rounded at the bottom to follow the picture's corners.
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12))
        }
    }
}
#endif

/// A widescreen card: the item's still with a progress bar (if partly watched) and a watched checkmark, and its
/// caption beneath.
struct WideCard: View {
    let item: MediaItem

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.captionGap) {
            ArtworkView(url: item.gridArtworkURL, aspectRatio: 16.0 / 9.0)
                .overlay(alignment: .bottom) {
                    #if os(tvOS)
                    // The play icon, progress and time left over the picture, as in the Apple TV app.
                    WideCardStatus(item: item)
                    #else
                    if let fraction = item.playedFraction {
                        ProgressView(value: fraction)
                            .artworkOverlayEdge()
                            .padding(6)
                    }
                    #endif
                }
                .overlay(alignment: .topTrailing) {
                    if item.showsWatchedBadge {
                        WatchedBadge()
                    }
                }
                .overlay(alignment: .topLeading) { DownloadedBadge(item: item) }
                .focusHighlight()

            // An episode's show is the screen it's on, so it shows only its own title and number. The most lines
            // an extra shows is three (title, kind, length); reserving them keeps the cards the same height.
            ItemCaption(
                item: item,
                reservedLines: item.kind == .episode ? 2 : 3,
                lines: item.kind == .episode ? [item.title, item.episodeAirLine].compactMap { $0 } : nil
            )
        }
        .contentShape(Rectangle())
    }
}

/// A poster with a progress bar (if partly watched), a watched checkmark, and the item's caption beneath.
struct PosterCard: View {
    let item: MediaItem

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.captionGap) {
            ArtworkView(url: item.posterURL, aspectRatio: 2.0 / 3.0)
                .overlay(alignment: .bottom) {
                    if let fraction = item.playedFraction {
                        ProgressView(value: fraction)
                            .artworkOverlayEdge()
                            .padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if item.showsWatchedBadge {
                        WatchedBadge()
                    }
                }
                .overlay(alignment: .topLeading) { DownloadedBadge(item: item) }
                .focusHighlight()

            // Three lines is the most any item shows (an episode); reserving them keeps every card the same height.
            ItemCaption(item: item, reservedLines: 3)
        }
        // Make the whole card tappable, including the gaps between the artwork and text.
        .contentShape(Rectangle())
    }
}

/// Horizontally scrolling row of posters under a heading. Tapping a poster plays its item (or, for a show or
/// season, opens it).
///
/// If a `destination` is given, the heading is a button (with a chevron) that opens the full list.
///
/// Long-pressing a poster peeks at the item and opens a menu: "Go to …" plus the same watch-state actions
/// as the shelf's full list. The detail screen opens from "Go to …" or by tapping the peek. `onChange` is
/// called after an action changes something on the server, so the owner can reload.
struct MediaShelf: View {
    let title: String
    let items: [MediaItem]

    /// Where tapping the heading leads. Nil makes the heading plain text.
    var destination: ShelfDestination?

    /// Called when the heading is tapped, instead of navigating to `destination` by value. For a shelf on a
    /// screen that was opened by an item binding, which can't push a value link (see `ShelfHeadingLink`).
    var onHeadingTap: (() -> Void)?

    /// Whether the cards are widescreen (for extras, which have a still rather than a poster) instead of posters.
    var isWide = false

    /// Whether there's more behind the shelf than it shows. Only then does it end with a See All card.
    var hasMore = true

    /// Menu links to leave out, for a shelf that's inside the screen they lead to.
    var omitting: Set<RelatedLink> = []

    /// Called after a long-press action has changed the server, so the shelf's owner can reload.
    var onChange: () -> Void = {}

    /// Opens and plays items. The owner presents both: a navigation destination can't live in the shelf
    /// itself, because shelves sit in a lazy stack, where SwiftUI ignores destinations.
    let navigation: ItemNavigation

    @Environment(AppModel.self) private var appModel

    /// A change waiting for confirmation, or an error to show.
    @State private var watchState = WatchActionState()

    /// Changes made since `items` last updated, shown at once while the owner reloads. Cleared when the
    /// reload arrives.
    @State private var effects: [WatchEffect] = []

    /// `items` with the user's latest changes applied.
    private var shownItems: [MediaItem] {
        effects.reduce(items) { $0.applying($1) }
    }

    private var watchActions: WatchActions {
        WatchActions(service: appModel.service, downloads: appModel.downloads, destination: destination, state: $watchState) { effect in
            effects.append(effect)
            onChange()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.shelfHeadingGap) {
            heading
                .padding(.horizontal, Layout.contentInset)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Layout.cardSpacing) {
                    ForEach(shownItems) { item in
                        card(for: item)
                    }
                    #if os(tvOS)
                    seeAllCard
                    #endif
                }
                .padding(.horizontal, Layout.contentInset)
            }
            .scrollIndicators(.hidden)
            // Lets a focused card lift and grow past the edge of the scroll view.
            .scrollClipDisabled()
        }
        // Focus moving up or down lands on this row from anywhere along its width.
        .tvFocusSection()
        // The reload has arrived, so the real data replaces the local changes.
        .onChange(of: items) { effects = [] }
        .watchActionAlerts(watchActions)
    }

    /// A poster that plays its item when tapped, and peeks and pops when long-pressed.
    @ViewBuilder
    private func card(for item: MediaItem) -> some View {
        let actions = watchActions.actions(for: item, navigation: navigation, omitting: omitting)
        #if os(iOS)
        // A UIKit layer over the card, so that tapping the preview can open the item. SwiftUI's preview can't.
        cardBody(for: item)
            .peekAndPop(WatchActions.peekSpec(for: item, actions: actions, navigation: navigation))
        #else
        Button { navigation.tap(item) } label: {
            cardBody(for: item)
        }
        .cardLinkStyle()
        .contextMenu {
            ItemActionButtons(entries: actions?.menuEntries(for: item) ?? [])
        }
        #endif
    }

    /// The card for an item, at the width of the shelf's cards.
    @ViewBuilder
    private func cardBody(for item: MediaItem) -> some View {
        if isWide {
            WideCard(item: item)
                .cardWidth(Layout.wideCardWidth)
        } else {
            PosterCard(item: item)
                .cardWidth(Layout.posterWidth)
        }
    }

    #if os(tvOS)
    /// The last card in a tvOS shelf, which opens the full list. It stands in for the heading link, so the heading
    /// isn't an extra stop for focus above every row.
    @ViewBuilder
    private var seeAllCard: some View {
        if hasMore, onHeadingTap != nil || destination != nil {
            // Exactly the size of a card's artwork, at the top of the row, so it lines up with the posters beside it.
            // Opaque, so nothing behind the row shows through it.
            // Given its width and height outright, so the row's scroll width counts all of it. Worked out from an aspect
            // ratio, the card was laid out narrower than it drew, and the row stopped scrolling with its end off screen.
            let width = isWide ? Layout.wideCardWidth : Layout.posterWidth
            let height = width / (isWide ? 16.0 / 9.0 : 2.0 / 3.0)
            let card = RoundedRectangle(cornerRadius: 12)
                .fill(Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.22, alpha: 1) : UIColor(white: 0.88, alpha: 1) }))
                .frame(width: width, height: height)
                .overlay {
                    VStack(spacing: 12) {
                        Image(systemName: "chevron.right.circle")
                            .font(.largeTitle)
                        Text("See All")
                            .font(.headline)
                    }
                    .foregroundStyle(.secondary)
                }
                .contentShape(RoundedRectangle(cornerRadius: 12))
                .focusHighlight()

            if let onHeadingTap {
                Button(action: onHeadingTap) { card }
                    .cardLinkStyle()
            } else if let sortedLibrary = destination?.sortedLibrary {
                // A slice of a library: the rest of it is on the library's page, in the shelf's order.
                NavigationLink(value: sortedLibrary) { card }
                    .cardLinkStyle()
            } else if let destination {
                NavigationLink(value: destination) { card }
                    .cardLinkStyle()
            }
        }
    }
    #endif

    @ViewBuilder
    private var heading: some View {
        #if os(tvOS)
        Text(title)
            .font(Layout.shelfHeadingFont)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
        #else
        if let onHeadingTap {
            ShelfHeadingLink(title: LocalizedStringKey(title), action: onHeadingTap)
                .accessibilityLabel("\(title), show all")
        } else if let destination {
            NavigationLink(value: destination) {
                // The chevron stays beside the first line when the heading wraps.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                        .font(.title2.bold())
                        .multilineTextAlignment(.leading)
                    Image(systemName: "chevron.right")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }
            .cardLinkStyle()
            .accessibilityLabel("\(title), show all")
        } else {
            Text(title)
                .font(.title2.bold())
        }
        #endif
    }
}

/// What the "more" menu on a list row can do to its item.
///
/// Every action is optional; one that's nil (or doesn't apply to the item) has no menu entry.
struct ItemRowActions {
    /// Opens the item's detail screen: the menu's first entry, "Go to Movie", "Go to Episode", and so on.
    var goTo: (() -> Void)?

    /// Opens the season an episode belongs to, and the show an episode or season belongs to. Nil where they
    /// don't apply. They sit after `goTo` in the menu: episode, season, show.
    var goToSeason: (() -> Void)?
    var goToShow: (() -> Void)?

    /// Marks the item (for a show or season, all its episodes) watched or unwatched. Nil for an item that
    /// can't be watched.
    var markWatched: (() -> Void)?
    var markUnwatched: (() -> Void)?

    /// Takes the item out of Continue Watching. Nil where that doesn't apply, which hides the menu entry.
    var removeFromContinueWatching: (() -> Void)?

    /// The two ways to take an episode's show out of Up Next: mark all of its episodes watched, or unwatched.
    /// Both are nil where that doesn't apply, which hides the "Remove from Up Next" submenu.
    var removeShowWatched: (() -> Void)?
    var removeShowUnwatched: (() -> Void)?

    /// The download entries for the item: download, pause, resume or remove, depending on where its download is. Empty
    /// for anything that can't be downloaded. They're built with the item's download state, so they follow it.
    var downloadEntries: [ItemMenuEntry] = []

    /// Plays the item. Offered first in the menu on tvOS, where selecting a card opens its detail screen rather
    /// than playing it. Nil for anything that can't be played.
    var play: (() -> Void)?
}

/// Compact list row: thumbnail plus title and details.
///
/// If `actions` is given, a "more" button on the right opens a menu of them.
struct ItemRow: View {
    let item: MediaItem

    /// Lines to show instead of the item's usual caption.
    var captionLines: [String]?
    var actions: ItemRowActions?

    /// If given, the row peeks and pops when long-pressed. See `peekAndPop(_:passthrough:isAccessibilityElement:)`.
    var peek: PeekAndPopSpec?

    /// Episodes and movies show a widescreen image; everything else is a portrait poster.
    private var isWidescreen: Bool { item.hasWidescreenRowArtwork }

    private static let stillWidth: CGFloat = 86
    private static let posterWidth: CGFloat = 43

    var body: some View {
        HStack(spacing: 12) {
            // Every row reserves the same width, so titles line up whether the artwork is a poster or a still.
            ArtworkView(url: item.rowArtworkURL, aspectRatio: isWidescreen ? 16.0 / 9.0 : 2.0 / 3.0)
                .frame(width: isWidescreen ? Self.stillWidth : Self.posterWidth)
                .frame(width: Self.stillWidth)

            ItemCaption(item: item, lines: captionLines)

            Spacer()

            DownloadedRowIcon(item: item)

            if item.showsWatchedBadge {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Watched")
            }

            #if !os(tvOS)
            if let actions {
                ItemActionsMenu(item: item, actions: actions)
            }
            #endif
        }
        // The peek layer covers the row except the menu button's end (if it has one), so that button keeps
        // its own taps.
        .peekAndPop(peek, passthrough: actions == nil ? .none : .trailingEdge(ItemActionsMenu.reservedWidth))
    }
}

/// One entry in an item's menu: an action, or a submenu if it has `children`.
///
/// Menus are described with these, not built directly, so the SwiftUI menus and the UIKit long-press menu
/// (see `PeekAndPopCard`) always offer exactly the same things.
struct ItemMenuEntry: Identifiable {
    /// What an entry does, which identifies it within a menu.
    enum ID: Hashable {
        case play
        case goTo
        case goToSeason
        case goToShow
        case markWatched
        case markUnwatched
        case removeFromContinueWatching
        case removeFromUpNext
        case markAllEpisodesWatched
        case markAllEpisodesUnwatched
        case download
        case pauseDownload
        case resumeDownload
        case removeDownload
        case viewPhoto
        case openLink
        case copyLink
    }

    let id: ID
    /// Already localized.
    let title: String
    let systemImage: String
    var perform: (() -> Void)?
    var children: [ItemMenuEntry] = []
}

extension ItemRowActions {
    /// The menu entries for an item: "Go to …" (if given), then the watch-state actions, then the download actions.
    func menuEntries(for item: MediaItem) -> [ItemMenuEntry] {
        var entries: [ItemMenuEntry] = []
        #if os(tvOS)
        // Selecting a card already opens the item, so the menu leads with Play instead of "Go to …".
        if let play {
            entries.append(ItemMenuEntry(id: .play, title: item.playButtonTitle(forShow: false), systemImage: "play.fill", perform: play))
        }
        #else
        if let goTo {
            entries.append(ItemMenuEntry(id: .goTo, title: item.goToMenuTitle, systemImage: "info.circle", perform: goTo))
        }
        #endif
        if let goToSeason {
            entries.append(ItemMenuEntry(id: .goToSeason, title: String(localized: "Go to Season"), systemImage: "square.stack", perform: goToSeason))
        }
        if let goToShow {
            entries.append(ItemMenuEntry(id: .goToShow, title: String(localized: "Go to Show"), systemImage: "tv", perform: goToShow))
        }
        return entries + watchEntries(for: item) + downloadEntries
    }

    /// The watch-state entries for an item.
    private func watchEntries(for item: MediaItem) -> [ItemMenuEntry] {
        // A show or season covers all its episodes, so what's on offer depends on how many are watched.
        if item.kind == .series || item.kind == .season {
            let isSeason = item.kind == .season
            let options = item.containerWatchOptions
            var entries: [ItemMenuEntry] = []
            if let markWatched, options.canMarkWatched {
                entries.append(ItemMenuEntry(
                    id: .markWatched,
                    title: isSeason ? String(localized: "Mark Season as Watched") : String(localized: "Mark Show as Watched"),
                    systemImage: "checkmark.circle",
                    perform: markWatched
                ))
            }
            if let markUnwatched, options.canMarkUnwatched {
                entries.append(ItemMenuEntry(
                    id: .markUnwatched,
                    title: isSeason ? String(localized: "Mark Season as Unwatched") : String(localized: "Mark Show as Unwatched"),
                    systemImage: "arrow.uturn.backward.circle",
                    perform: markUnwatched
                ))
            }
            return entries
        }

        var entries: [ItemMenuEntry] = []

        // A partly watched item offers both, so the user can finish it or start it over.
        if let markWatched, !item.showsWatchedBadge {
            entries.append(ItemMenuEntry(id: .markWatched, title: String(localized: "Mark as Watched"), systemImage: "checkmark.circle", perform: markWatched))
        }
        if let markUnwatched, item.isPlayed || item.playedFraction != nil {
            entries.append(ItemMenuEntry(id: .markUnwatched, title: String(localized: "Mark as Unwatched"), systemImage: "arrow.uturn.backward.circle", perform: markUnwatched))
        }
        if let remove = removeFromContinueWatching {
            entries.append(ItemMenuEntry(id: .removeFromContinueWatching, title: String(localized: "Remove from Continue Watching"), systemImage: "minus.circle", perform: remove))
        }
        if let showWatched = removeShowWatched, let showUnwatched = removeShowUnwatched {
            entries.append(ItemMenuEntry(
                id: .removeFromUpNext,
                title: String(localized: "Remove from Up Next"),
                systemImage: "minus.circle",
                children: [
                    ItemMenuEntry(id: .markAllEpisodesWatched, title: String(localized: "Mark All Episodes as Watched"), systemImage: "checkmark.circle", perform: showWatched),
                    ItemMenuEntry(id: .markAllEpisodesUnwatched, title: String(localized: "Mark All Episodes as Unwatched"), systemImage: "arrow.uturn.backward.circle", perform: showUnwatched)
                ]
            ))
        }
        return entries
    }
}

/// Menu entries as SwiftUI buttons: the contents of the "more" button's menu and of a long-press menu.
struct ItemActionButtons: View {
    let entries: [ItemMenuEntry]

    var body: some View {
        ForEach(entries) { entry in
            if entry.children.isEmpty {
                Button(entry.title, systemImage: entry.systemImage) { entry.perform?() }
            } else {
                Menu(entry.title, systemImage: entry.systemImage) {
                    ForEach(entry.children) { child in
                        Button(child.title, systemImage: child.systemImage) { child.perform?() }
                    }
                }
            }
        }
    }
}

/// What a long-press on a card peeks at: a widescreen image, the item's caption, and a bit of its synopsis.
struct ItemPeek: View {
    let item: MediaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkView(url: item.gridArtworkURL, aspectRatio: 16.0 / 9.0)

            ItemCaption(item: item)

            if let overview = item.overview {
                Text(overview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
        }
        .padding(12)
        .frame(width: Self.width)
    }

    /// How wide a peek is. The peek's UIKit host sizes itself to this too.
    static let width: CGFloat = 320
}

/// The "more" (…) button and the menu of watch-state actions it opens.
struct ItemActionsMenu: View {
    let item: MediaItem
    let actions: ItemRowActions

    /// Whether the button sits on top of artwork, where it's white so it reads against any image.
    var overArtwork = false

    /// How much room, from the trailing edge, a peek layer leaves for this button so it keeps its own taps:
    /// the padded label plus some slack for a finger.
    static let reservedWidth: CGFloat = 56

    /// The smallest the button's touch target gets, in each direction.
    static let minimumTarget: CGFloat = 44

    var body: some View {
        Menu {
            ItemActionButtons(entries: actions.menuEntries(for: item))
        } label: {
            Image(systemName: "ellipsis")
                // Over artwork it's the card's main control, so it's larger and bolder, like the status text.
                .font(overArtwork ? .title3.weight(.bold) : .body)
                .foregroundStyle(overArtwork ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                // Over artwork it sits at the card's bottom edge, so it's padded less vertically to sit low.
                .padding(.horizontal, overArtwork ? 10 : 8)
                .padding(.vertical, overArtwork ? 6 : 8)
                // At least the 44-point minimum touch target, whatever the text size.
                .frame(minWidth: Self.minimumTarget, minHeight: Self.minimumTarget)
                .contentShape(Rectangle())
        }
        // Plain leaves the label's color alone. Tinting the menu instead would gray its items' icons too.
        .buttonStyle(.plain)
        .accessibilityLabel("More")
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
        VStack(alignment: .leading, spacing: 6) {
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
