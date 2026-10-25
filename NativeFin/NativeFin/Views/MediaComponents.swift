// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

// Small reusable pieces shared by the browsing screens.

/// Shared layout constants.
enum Layout {
    /// Width of a poster in shelves; larger on tvOS for the "ten-foot" UI.
    static var posterWidth: CGFloat {
        #if os(tvOS)
        return 220
        #else
        return 130
        #endif
    }
}

extension MediaItem {
    /// Whether the item can be played directly (as opposed to being a container like a series).
    var isPlayable: Bool { kind == .movie || kind == .episode }

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
        case let (season?, episode?): String(localized: "Season \(season) Episode \(episode)")
        case let (nil, episode?): String(localized: "Episode \(episode)")
        default: nil
        }
    }

    /// Whether to show the watched checkmark. An item that's partly watched (it has a resume position) is in
    /// progress, even if the server also flags it as played.
    var showsWatchedBadge: Bool { isPlayed && playedFraction == nil }

    /// The widescreen image for the landscape shelf grid, falling back through the backdrop to the poster.
    var gridArtworkURL: URL? { thumbnailURL ?? backdropURL ?? posterURL }

    /// The line over a grid card's image, e.g. "S4, E6 · 46m left" or "1h 53m". Nil if there's nothing to say.
    var gridStatusLine: String? {
        var parts: [String] = []
        if kind == .episode, let episodeNumber {
            parts.append(seasonNumber.map { "S\($0), E\(episodeNumber)" } ?? "E\(episodeNumber)")
        }
        if let runtime {
            let remaining = playedFraction.map { runtime * (1 - $0) } ?? runtime
            let time = Duration.seconds(remaining).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
            parts.append(playedFraction == nil ? time : String(localized: "\(time) left"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Whether `ItemRow` shows widescreen artwork (episodes and movies) rather than a portrait poster.
    var hasWidescreenRowArtwork: Bool {
        (kind == .episode || kind == .movie) && thumbnailURL != nil
    }

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
        case .other:
            [title]
        }
    }
}

extension View {
    /// Registers navigation for media items and libraries; apply to the root of each NavigationStack.
    func mediaNavigationDestinations() -> some View {
        navigationDestination(for: MediaItem.self) { ItemDetailView(item: $0) }
            .navigationDestination(for: Library.self) { LibraryView(library: $0) }
            .navigationDestination(for: ShelfDestination.self) { ShelfListView(destination: $0) }
    }

    /// Gives something drawn over artwork (a badge, a progress bar) a faint edge, so it doesn't vanish into
    /// artwork of a similar color. This plays the role `ArtworkView`'s outline does for the artwork itself;
    /// a soft shadow suits small shapes better than a stroke.
    func artworkOverlayEdge() -> some View {
        shadow(color: .black.opacity(0.4), radius: 2)
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
            .clipShape(RoundedRectangle(cornerRadius: 8))
            // A faint outline gives artwork whose background matches the screen's (white or black) an edge.
            // It's inset, and the primary color flips with light and dark mode, so it stays subtle on artwork
            // that already stands out.
            .overlay {
                RoundedRectangle(cornerRadius: 8)
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

    var body: some View {
        let lines = item.captionLines

        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                Text(line)
                    .font(index == 0 ? .subheadline.weight(.medium) : .caption)
                    .foregroundStyle(index == 0 ? .primary : .secondary)
                    .lineLimit(1)
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
            .foregroundStyle(.white, .green)
            .artworkOverlayEdge()
            .padding(6)
            .accessibilityLabel("Watched")
    }
}

/// A poster with a progress bar (if partly watched), a watched checkmark, and the item's caption beneath.
struct PosterCard: View {
    let item: MediaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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

            // Three lines is the most any item shows (an episode); reserving them keeps every card the same height.
            ItemCaption(item: item, reservedLines: 3)
        }
        // Make the whole card tappable, including the gaps between the artwork and text.
        .contentShape(Rectangle())
    }
}

/// Horizontally scrolling row of posters under a heading. Each poster navigates to its item.
///
/// If a `destination` is given, the heading is a button (with a chevron) that opens the full list.
struct MediaShelf: View {
    let title: String
    let items: [MediaItem]

    /// Where tapping the heading leads. Nil makes the heading plain text.
    var destination: ShelfDestination?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading
                .padding(.horizontal)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(items) { item in
                        NavigationLink(value: item) {
                            PosterCard(item: item)
                                .frame(width: Layout.posterWidth)
                        }
                        .cardLinkStyle()
                    }
                }
                .padding(.horizontal)
            }
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private var heading: some View {
        if let destination {
            NavigationLink(value: destination) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.title2.bold())
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
    }
}

/// What the "more" menu on a list row can do to its item.
struct ItemRowActions {
    let markWatched: () -> Void
    let markUnwatched: () -> Void

    /// Takes the item out of Continue Watching. Nil where that doesn't apply, which hides the menu entry.
    var removeFromContinueWatching: (() -> Void)?

    /// The two ways to take an episode's show out of Up Next: mark all of its episodes watched, or unwatched.
    /// Both are nil where that doesn't apply, which hides the "Remove from Up Next" submenu.
    var removeShowWatched: (() -> Void)?
    var removeShowUnwatched: (() -> Void)?
}

/// Compact list row: thumbnail plus title and details.
///
/// If `actions` is given, a "more" button on the right opens a menu of them.
struct ItemRow: View {
    let item: MediaItem
    var actions: ItemRowActions?

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

            ItemCaption(item: item)

            Spacer()

            if item.showsWatchedBadge {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Watched")
            }

            if let actions {
                ItemActionsMenu(item: item, actions: actions)
            }
        }
    }
}

/// The "more" (…) button and the menu of watch-state actions it opens.
struct ItemActionsMenu: View {
    let item: MediaItem
    let actions: ItemRowActions

    /// Whether the button sits on top of artwork, where it's white so it reads against any image.
    var overArtwork = false

    var body: some View {
        Menu {
            // A partly watched item offers both, so the user can finish it or start it over.
            if !item.showsWatchedBadge {
                Button("Mark as Watched", systemImage: "checkmark.circle", action: actions.markWatched)
            }
            if item.isPlayed || item.playedFraction != nil {
                Button("Mark as Unwatched", systemImage: "arrow.uturn.backward.circle", action: actions.markUnwatched)
            }
            if let remove = actions.removeFromContinueWatching {
                Button("Remove from Continue Watching", systemImage: "minus.circle", action: remove)
            }
            if let showWatched = actions.removeShowWatched, let showUnwatched = actions.removeShowUnwatched {
                Menu("Remove from Up Next", systemImage: "minus.circle") {
                    Button("Mark All Episodes as Watched", systemImage: "checkmark.circle", action: showWatched)
                    Button("Mark All Episodes as Unwatched", systemImage: "arrow.uturn.backward.circle", action: showUnwatched)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(overArtwork ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .padding(8)
                .contentShape(Rectangle())
        }
        // Plain leaves the label's color alone. Tinting the menu instead would gray its items' icons too.
        .buttonStyle(.plain)
        .accessibilityLabel("More")
    }
}

/// A widescreen card for the landscape shelf grid: the image with a status line and the "more" button along
/// its bottom edge, and the item's caption beneath. It doesn't navigate; the grid puts a link behind it.
struct ShelfGridCard: View {
    let item: MediaItem
    var actions: ItemRowActions?

    private static let progressWidth: CGFloat = 36

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(url: item.gridArtworkURL, aspectRatio: 16.0 / 9.0)
                .overlay(alignment: .bottom) { statusBar }
                .overlay(alignment: .topTrailing) {
                    if item.showsWatchedBadge {
                        WatchedBadge()
                    }
                }
                // The status bar's gradient is square; clip it to the image's rounded corners.
                .clipShape(RoundedRectangle(cornerRadius: 8))

            ItemCaption(item: item)
        }
        // Make the whole card tappable, including the gaps between the artwork and text.
        .contentShape(Rectangle())
    }

    /// Play icon, progress, episode and time left, and the menu button, over a fade so they read on any image.
    private var statusBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "play.fill")
                .accessibilityHidden(true)

            if let fraction = item.playedFraction {
                Capsule()
                    .fill(.white.opacity(0.3))
                    .frame(width: Self.progressWidth, height: 3)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(.white)
                            .frame(width: Self.progressWidth * fraction)
                    }
                    .accessibilityHidden(true)
            }

            if let status = item.gridStatusLine {
                Text(status)
                    .lineLimit(1)
            }

            Spacer()

            if let actions {
                ItemActionsMenu(item: item, actions: actions, overArtwork: true)
            }
        }
        .font(.caption)
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.top, 20)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
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
    NavigationStack {
        MediaShelf(title: "Continue Watching", items: MediaItem.previewMovies)
            .mediaNavigationDestinations()
    }
    .environment(AppModel.preview())
}

/// An episode (which has a subtitle) between cards that don't: all three should get equal artwork.
#Preview("MediaShelf mixed subtitles") {
    NavigationStack {
        MediaShelf(
            title: "Recently Added Shows",
            items: [.previewMovie, .previewEpisode, .previewWatched],
            destination: .continueWatching
        )
        .mediaNavigationDestinations()
    }
    .environment(AppModel.preview())
}

#Preview("ItemRow") {
    List(MediaItem.previewMovies + [.previewEpisode]) { ItemRow(item: $0) }
}

#Preview("ArtworkView") {
    ArtworkView(url: nil, aspectRatio: 16.0 / 9.0)
        .padding()
}
