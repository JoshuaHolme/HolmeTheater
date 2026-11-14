// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// A show's seasons: a row of posters under a heading, or the episodes of its only season (a mini series).
struct SeasonsSection: View {
    /// A series.
    let item: MediaItem

    /// Changing this reloads the list, e.g. after a change on the server.
    var reloadID = 0

    /// Opens a season. The owner presents it, because a navigation destination can't live in the row itself, which
    /// sits in a lazy stack, where SwiftUI ignores destinations. The owner also has the only destination for items,
    /// since two on one screen can fight over a push.
    let open: (MediaItem) -> Void

    /// Plays an episode, for a mini series' episode row. The owner presents the player.
    let play: (MediaItem) -> Void

    /// The menu for each row, or nil for none.
    let actions: (MediaItem) -> ItemRowActions?

    @Environment(AppModel.self) private var appModel

    /// Whether the list of every season is open.
    @State private var showsSeasonList = false

    var body: some View {
        AsyncContent(load: {
            let children = try await appModel.service.children(of: item)
            // The seasons' posters load before the row shows, so they don't pop in.
            await ImageCache.shared.preload(children.prefix(6).compactMap(\.posterURL))
            return children
        }, reloadID: reloadID, pullsToRefresh: false) { children in
            VStack(alignment: .leading, spacing: Layout.shelfHeadingGap) {
                if children.count == 1, let season = children.first {
                    // A show with a single season is a mini series: its episodes stand in for the one season.
                    EpisodeShelf(season: season, reloadID: reloadID, omitting: [.show, .season], open: open, play: play)
                } else {
                    ShelfHeadingLink(title: "\(children.count) Seasons") { showsSeasonList = true }
                        .padding(.horizontal, Layout.contentInset)
                    seasonShelf(children)
                }
            }
        }
        .navigationDestination(isPresented: $showsSeasonList) { SeasonListView(series: item) }
    }

    /// A horizontally scrolling row of season posters. It pads its own ends, so it scrolls edge to edge.
    private func seasonShelf(_ seasons: [MediaItem]) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: Layout.cardSpacing) {
                ForEach(seasons) { season in
                    seasonCard(season)
                }
            }
            .padding(.horizontal, Layout.contentInset)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .tvFocusSection()
    }

    /// A season poster that opens the season when tapped, and peeks and pops when long-pressed.
    @ViewBuilder
    private func seasonCard(_ season: MediaItem) -> some View {
        var actions = actions(season)
        let _ = actions?.goTo = { open(season) }
        #if os(iOS)
        // A UIKit layer over the card, so that tapping the preview can open the season, as on the home screen.
        SeasonCard(season: season)
            .cardWidth(Layout.posterWidth)
            .peekAndPop(WatchActions.peekSpec(for: season, actions: actions, navigation: seasonNavigation))
        #else
        Button { open(season) } label: {
            SeasonCard(season: season)
                .frame(width: Layout.posterWidth)
        }
        .cardLinkStyle()
        .contextMenu {
            ItemActionButtons(entries: actions?.menuEntries(for: season) ?? [])
        }
        #endif
    }

    /// Seasons can't be played, so tapping one opens it, like its peek does.
    private var seasonNavigation: ItemNavigation {
        ItemNavigation(open: open, play: { _ in })
    }
}

/// A section heading with a chevron that opens the full list behind the section, like a home-screen shelf's.
///
/// It runs an action rather than navigating by value. A screen that was itself opened by an item binding (a
/// `navigationDestination(item:)`) can't push a value link: the stack puts that screen on top of the new one. So
/// anything pushed from such a screen uses a destination on the screen itself, which the owner of the heading sets.
struct ShelfHeadingLink: View {
    let title: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        #if os(tvOS)
        // Plain text, as on the home screen: the row is the whole list, so there's no chevron to focus above it.
        Text(title)
            .font(Layout.shelfHeadingFont)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
        #else
        Button(action: action) {
            // The chevron stays beside the first line when the heading wraps.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(Layout.shelfHeadingFont)
                    .multilineTextAlignment(.leading)
                Image(systemName: "chevron.right")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
        .cardLinkStyle()
        .accessibilityAddTraits(.isHeader)
        #endif
    }
}

/// A mini series' episodes in a row of widescreen cards, with a heading that opens the list of them all. The same
/// shelf as the home screen's, so tapping plays and a long-press peeks.
struct EpisodeShelf: View {
    /// The show's only season.
    let season: MediaItem
    let reloadID: Int

    /// Menu links to leave out because the screen is already inside them.
    let omitting: Set<RelatedLink>

    /// Whether the row scrolls to the first episode that isn't watched, and puts focus on it (tvOS). For a season's own page,
    /// where that's the episode to carry on with.
    var focusesFirstUnwatched = false

    let open: (MediaItem) -> Void
    let play: (MediaItem) -> Void

    @Environment(AppModel.self) private var appModel

    /// Whether the list of every episode is open.
    @State private var showsList = false

    /// Bumped to reload the episodes after a change on the server.
    @State private var reloadCount = 0

    var body: some View {
        AsyncContent(load: {
            let episodes = try await appModel.service.children(of: season)
            // The first episodes' stills load before the row shows, so they don't pop in.
            await ImageCache.shared.preload(episodes.prefix(4).compactMap(\.gridArtworkURL))
            return episodes
        }, reloadID: reloadID + reloadCount, pullsToRefresh: false) { episodes in
            if !episodes.isEmpty {
                MediaShelf(
                    title: episodes.count == 1 ? String(localized: "1 Episode") : String(localized: "\(episodes.count) Episodes"),
                    items: episodes,
                    onHeadingTap: { showsList = true },
                    isWide: true,
                    omitting: omitting,
                    autoFocusItemID: focusesFirstUnwatched ? episodes.first { !$0.isPlayed }?.shelfKey : nil,
                    onChange: { reloadCount += 1 },
                    // Inside the season, selecting an episode plays it; its page is "Go to Episode" in the menu.
                    navigation: ItemNavigation(open: open, play: play, playsOnTap: true)
                )
            }
        }
        .navigationDestination(isPresented: $showsList) { ShelfListView(destination: .episodes(season, omitsShow: omitting.contains(.show))) }
    }
}

/// Every season of a show as a list of rows, with the same menus and peeks as the shelf.
struct SeasonListView: View {
    let series: MediaItem

    @Environment(AppModel.self) private var appModel

    /// A watch-state change waiting for confirmation, or an error to show.
    @State private var watchState = WatchActionState()

    /// Bumped to reload the seasons after a change on the server.
    @State private var reloadCount = 0

    /// The season a tap, peek or "Go to Season" is opening.
    @State private var openedSeason: MediaItem?

    private var watchActions: WatchActions {
        WatchActions(service: appModel.service, downloads: appModel.downloads, canManageCollections: appModel.canManageCollections, destination: nil, state: $watchState) { _ in
            reloadCount += 1
        }
    }

    /// Seasons can't be played, so tapping one opens it, like its peek does.
    private var navigation: ItemNavigation {
        ItemNavigation(open: { openedSeason = $0 }, play: { _ in })
    }

    var body: some View {
        AsyncContent(load: { try await appModel.service.children(of: series) }, reloadID: reloadCount) { seasons in
            List(seasons) { season in
                // Built once and shared by the "more" menu and the long-press menu.
                // Already inside the show, so there's no "Go to Show".
                let actions = watchActions.actions(for: season, navigation: navigation, omitting: [.show])
                let row = ItemRow(item: season, captionLines: [season.seasonTitle, season.seasonDetailLine].compactMap { $0 }, actions: actions, peek: WatchActions.peekSpec(for: season, actions: actions, navigation: navigation))
                #if os(tvOS)
                // The row is the button, so it has one focus stop; its actions are in the long-press menu.
                Button { openedSeason = season } label: { row.padding(12) }
                    .buttonStyle(.card)
                    .contextMenu { ItemActionButtons(entries: actions?.menuEntries(for: season) ?? []) }
                    .accessibilityLabel(season.accessibilityDescription)
                #else
                row
                #endif
            }
            .listStyle(.plain)
        }
        .navigationTitle("Seasons")
        .watchActionAlerts(watchActions)
        .navigationDestination(item: $openedSeason) { ItemDetailView(item: $0) }
    }
}

extension MediaItem {
    /// "Season 2", or the server's name for it (e.g. "Specials") if it has no regular number.
    var seasonTitle: String {
        guard let number = episodeNumber, number > 0 else { return title }
        return String(localized: "Season \(String(number))") // a year-like number has no thousands separator
    }

    /// e.g. "8 Episodes · 2021". Whichever part the server didn't give is left out.
    var seasonDetailLine: String? {
        var parts: [String] = []
        if let episodeCount {
            parts.append(episodeCount == 1 ? String(localized: "1 Episode") : String(localized: "\(episodeCount) Episodes"))
        }
        if let year {
            parts.append(year.formatted(.number.grouping(.never)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A season's poster with "Season X" beneath it, then its episode count and the year it came out.
private struct SeasonCard: View {
    let season: MediaItem

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.captionGap) {
            ArtworkView(url: season.posterURL, aspectRatio: 2.0 / 3.0)
                .overlay(alignment: .topTrailing) {
                    if season.showsWatchedBadge {
                        WatchedBadge()
                    }
                }
                .overlay(alignment: .topLeading) { DownloadedBadge(item: season) }
                // The artwork is what lifts and shines on focus, as on the other posters.
                .focusHighlight()

            #if os(tvOS)
            // The same caption as the other posters, so the row looks like them.
            ItemCaption(item: season, reservedLines: 2, lines: [season.seasonTitle, season.seasonDetailLine].compactMap { $0 })
            #else
            VStack(alignment: .leading, spacing: 2) {
                Text(season.seasonTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)

                if let subtitle = season.seasonDetailLine {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                }
            }
            #endif
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
