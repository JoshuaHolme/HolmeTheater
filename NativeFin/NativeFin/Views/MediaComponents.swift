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
///
/// Long-pressing a poster peeks at the item and opens a menu: "Go to …" plus the same watch-state actions
/// as the shelf's full list. `onChange` is called after one changes something on the server, so the owner
/// can reload.
struct MediaShelf: View {
    let title: String
    let items: [MediaItem]

    /// Where tapping the heading leads. Nil makes the heading plain text.
    var destination: ShelfDestination?

    /// Called after a long-press action has changed the server, so the shelf's owner can reload.
    var onChange: () -> Void = {}

    /// Called to open an item's detail screen. The owner presents it: a navigation destination can't live in
    /// the shelf itself, because shelves sit in a lazy stack, where SwiftUI ignores destinations.
    var onGoTo: (MediaItem) -> Void = { _ in }

    @Environment(AppModel.self) private var appModel

    /// Set when an action fails; shown in an alert.
    @State private var actionError: String?

    /// A show the user chose to remove from Up Next, waiting on their confirmation.
    @State private var pendingRemoval: ShowRemoval?

    /// A whole show or season the user chose to mark watched or unwatched, waiting on their confirmation.
    @State private var pendingBulkChange: BulkWatchChange?

    /// A change the user just made to an item, shown at once while the owner reloads the real data.
    private struct Patch {
        /// The item's new watched state, if the change sets one.
        var isPlayed: Bool?
        /// Whether the change takes the item off this shelf.
        var removed = false
    }

    /// Changes made since `items` last updated, by item ID. Cleared when the reload arrives.
    @State private var patches: [String: Patch] = [:]

    /// `items` with the user's latest changes applied.
    private var shownItems: [MediaItem] {
        items.compactMap { item in
            guard let patch = patches[item.id] else { return item }
            if patch.removed { return nil }

            var item = item
            if let isPlayed = patch.isPlayed {
                item.isPlayed = isPlayed
                // A show or season marked as a whole has all its episodes watched, or none.
                if item.kind == .series || item.kind == .season {
                    item.unwatchedEpisodeCount = isPlayed ? 0 : item.episodeCount
                }
            }
            // Marking watched or unwatched both clear the resume position.
            item.playedFraction = nil
            return item
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading
                .padding(.horizontal)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(shownItems) { item in
                        card(for: item)
                    }
                }
                .padding(.horizontal)
            }
            .scrollIndicators(.hidden)
        }
        // The reload has arrived, so the real data replaces the local changes.
        .onChange(of: items) { patches = [:] }
        .alert("Couldn't Update Item", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .confirmShowRemoval($pendingRemoval, perform: remove)
        .confirmBulkWatchChange($pendingBulkChange, perform: apply)
    }

    /// Marks every episode of a show or season watched or unwatched, once the user has confirmed.
    private func apply(_ change: BulkWatchChange) {
        let item = change.item
        perform(
            { service in
                if change.markWatched {
                    try await service.markWatched(item)
                } else {
                    try await service.markUnwatched(item)
                }
            },
            then: { patches[item.id] = Patch(isPlayed: change.markWatched) }
        )
    }

    /// A poster that opens its item when tapped, and peeks and pops when long-pressed.
    @ViewBuilder
    private func card(for item: MediaItem) -> some View {
        #if os(iOS)
        // A UIKit layer over the card, so that tapping the preview can open the item. SwiftUI's preview can't.
        PosterCard(item: item)
            .frame(width: Layout.posterWidth)
            .peekAndPop(
                menu: menuEntries(for: item),
                accessibilityLabel: item.captionLines.joined(separator: ", "),
                onOpen: { onGoTo(item) }
            ) {
                ItemPeek(item: item)
            }
        #else
        NavigationLink(value: item) {
            PosterCard(item: item)
                .frame(width: Layout.posterWidth)
        }
        .cardLinkStyle()
        .contextMenu {
            ItemActionButtons(entries: menuEntries(for: item))
        } preview: {
            ItemPeek(item: item)
        }
        #endif
    }

    /// The long-press menu: "Go to …", then the watch-state actions.
    private func menuEntries(for item: MediaItem) -> [ItemMenuEntry] {
        let goTo = ItemMenuEntry(title: goToTitle(for: item), systemImage: "info.circle", perform: { onGoTo(item) })
        return [goTo] + (actions(for: item)?.menuEntries(for: item) ?? [])
    }

    private func goToTitle(for item: MediaItem) -> String {
        switch item.kind {
        case .movie: String(localized: "Go to Movie")
        case .episode: String(localized: "Go to Episode")
        case .series: String(localized: "Go to Show")
        case .season: String(localized: "Go to Season")
        case .other: String(localized: "Go to Item")
        }
    }

    /// The watch-state actions for an item, or nil for things that can't be watched (series and seasons).
    /// These match the ones in `ShelfListView`, so a shelf and its full list offer the same choices.
    private func actions(for item: MediaItem) -> ItemRowActions? {
        // A show or season marks all its episodes, after a confirmation.
        if item.kind == .series || item.kind == .season {
            return ItemRowActions(
                markWatched: { pendingBulkChange = BulkWatchChange(item: item, markWatched: true) },
                markUnwatched: { pendingBulkChange = BulkWatchChange(item: item, markWatched: false) }
            )
        }
        guard item.isPlayable else { return nil }

        // Either change clears the resume position, so on Continue Watching the item leaves the shelf. On
        // Up Next a watched episode is replaced by the one after it, so it leaves too.
        let leavesOnWatched = destination == .continueWatching || destination == .nextUp
        let leavesOnUnwatched = destination == .continueWatching

        return ItemRowActions(
            markWatched: {
                perform({ try await $0.markWatched(item) }, then: {
                    patches[item.id] = Patch(isPlayed: true, removed: leavesOnWatched)
                })
            },
            markUnwatched: {
                perform({ try await $0.markUnwatched(item) }, then: {
                    patches[item.id] = Patch(isPlayed: false, removed: leavesOnUnwatched)
                })
            },
            removeFromContinueWatching: destination == .continueWatching ? {
                perform({ try await $0.removeFromContinueWatching(item) }, then: {
                    patches[item.id] = Patch(removed: true)
                })
            } : nil,
            removeShowWatched: upNextRemoval(for: item, markWatched: true),
            removeShowUnwatched: upNextRemoval(for: item, markWatched: false)
        )
    }

    /// Asks to remove an episode's show from Up Next, or nil off the Up Next shelf or if the show is unknown.
    private func upNextRemoval(for item: MediaItem, markWatched: Bool) -> (() -> Void)? {
        guard destination == .nextUp, let seriesID = item.seriesID else { return nil }
        return { pendingRemoval = ShowRemoval(item: item, seriesID: seriesID, markWatched: markWatched) }
    }

    /// Marks every episode of the show watched or unwatched, once the user has confirmed.
    private func remove(_ removal: ShowRemoval) {
        perform(
            { service in
                if removal.markWatched {
                    try await service.markSeriesWatched(seriesID: removal.seriesID)
                } else {
                    try await service.markSeriesUnwatched(seriesID: removal.seriesID)
                }
            },
            then: {
                // Every episode of the show is off Up Next.
                for item in items where item.seriesID == removal.seriesID {
                    patches[item.id] = Patch(removed: true)
                }
            }
        )
    }

    /// Runs a server change, shows its effect on the shelf at once, then tells the owner to reload so the
    /// shelf matches the server.
    ///
    /// - Parameters:
    ///   - change: The server call.
    ///   - localChange: Applies the same change to `patches`. It only runs if the server call succeeded.
    private func perform(
        _ change: @escaping @Sendable (any MediaService) async throws -> Void,
        then localChange: @escaping () -> Void
    ) {
        let service = appModel.service
        Task {
            do {
                try await change(service)
                localChange()
                onChange()
            } catch {
                actionError = error.localizedDescription
            }
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

/// One entry in an item's menu: an action, or a submenu if it has `children`.
///
/// Menus are described with these, not built directly, so the SwiftUI menus and the UIKit long-press menu
/// (see `PeekAndPopCard`) always offer exactly the same things.
struct ItemMenuEntry: Identifiable {
    /// Already localized.
    let title: String
    let systemImage: String
    var perform: (() -> Void)?
    var children: [ItemMenuEntry] = []

    var id: String { title }
}

extension ItemRowActions {
    /// The watch-state entries for an item.
    func menuEntries(for item: MediaItem) -> [ItemMenuEntry] {
        // A show or season covers all its episodes, so what's on offer depends on how many are watched.
        if item.kind == .series || item.kind == .season {
            let isSeason = item.kind == .season
            let options = item.containerWatchOptions
            var entries: [ItemMenuEntry] = []
            if options.canMarkWatched {
                entries.append(ItemMenuEntry(
                    title: isSeason ? String(localized: "Mark Season as Watched") : String(localized: "Mark Show as Watched"),
                    systemImage: "checkmark.circle",
                    perform: markWatched
                ))
            }
            if options.canMarkUnwatched {
                entries.append(ItemMenuEntry(
                    title: isSeason ? String(localized: "Mark Season as Unwatched") : String(localized: "Mark Show as Unwatched"),
                    systemImage: "arrow.uturn.backward.circle",
                    perform: markUnwatched
                ))
            }
            return entries
        }

        var entries: [ItemMenuEntry] = []

        // A partly watched item offers both, so the user can finish it or start it over.
        if !item.showsWatchedBadge {
            entries.append(ItemMenuEntry(title: String(localized: "Mark as Watched"), systemImage: "checkmark.circle", perform: markWatched))
        }
        if item.isPlayed || item.playedFraction != nil {
            entries.append(ItemMenuEntry(title: String(localized: "Mark as Unwatched"), systemImage: "arrow.uturn.backward.circle", perform: markUnwatched))
        }
        if let remove = removeFromContinueWatching {
            entries.append(ItemMenuEntry(title: String(localized: "Remove from Continue Watching"), systemImage: "minus.circle", perform: remove))
        }
        if let showWatched = removeShowWatched, let showUnwatched = removeShowUnwatched {
            entries.append(ItemMenuEntry(
                title: String(localized: "Remove from Up Next"),
                systemImage: "minus.circle",
                children: [
                    ItemMenuEntry(title: String(localized: "Mark All Episodes as Watched"), systemImage: "checkmark.circle", perform: showWatched),
                    ItemMenuEntry(title: String(localized: "Mark All Episodes as Unwatched"), systemImage: "arrow.uturn.backward.circle", perform: showUnwatched)
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

/// Removing a show from Up Next rewrites the watch state of all its episodes, so it's confirmed first.
struct ShowRemoval: Identifiable {
    let item: MediaItem
    let seriesID: String
    /// Whether every episode gets marked watched (true) or unwatched (false).
    let markWatched: Bool

    var id: String { "\(seriesID)-\(markWatched)" }
    var showTitle: String { item.seriesTitle ?? item.title }
}

/// Marking a whole show or season watched or unwatched rewrites the watch state of all its episodes, so it's
/// confirmed first.
struct BulkWatchChange: Identifiable {
    /// The show or season.
    let item: MediaItem
    /// Whether every episode gets marked watched (true) or unwatched (false).
    let markWatched: Bool

    var id: String { "\(item.id)-\(markWatched)" }
    private var isSeason: Bool { item.kind == .season }

    /// e.g. "Breaking Bad" or "Breaking Bad – Season 2".
    var name: String {
        isSeason ? [item.seriesTitle, item.title].compactMap { $0 }.joined(separator: " – ") : item.title
    }

    var alertTitle: String {
        switch (isSeason, markWatched) {
        case (false, true): String(localized: "Mark Show as Watched?")
        case (false, false): String(localized: "Mark Show as Unwatched?")
        case (true, true): String(localized: "Mark Season as Watched?")
        case (true, false): String(localized: "Mark Season as Unwatched?")
        }
    }
}

extension View {
    /// Asks the user to confirm a pending show or season change, warning what it does to the watch history.
    ///
    /// An alert, for the same reason as `confirmShowRemoval`.
    func confirmBulkWatchChange(_ change: Binding<BulkWatchChange?>, perform: @escaping (BulkWatchChange) -> Void) -> some View {
        alert(
            change.wrappedValue?.alertTitle ?? "",
            isPresented: Binding(
                get: { change.wrappedValue != nil },
                set: { if !$0 { change.wrappedValue = nil } }
            ),
            presenting: change.wrappedValue
        ) { pending in
            if pending.markWatched {
                Button("Mark as Watched") { perform(pending) }
            } else {
                Button("Mark as Unwatched", role: .destructive) { perform(pending) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            if pending.markWatched {
                Text("Every episode of \(pending.name) will be marked as watched, in all your Jellyfin apps. Their watched dates will be set to now.")
            } else {
                Text("Every episode of \(pending.name) will be marked as unwatched, in all your Jellyfin apps. This resets their play counts and watch dates, and can't be undone.")
            }
        }
    }

    /// Asks the user to confirm a pending Up Next removal, warning what it does to the show's watch history.
    ///
    /// An alert, not a confirmation dialog: on iPad a dialog becomes a popover that has to point at a
    /// view, and attached to a whole list or shelf it points at an arbitrary one.
    func confirmShowRemoval(_ removal: Binding<ShowRemoval?>, perform: @escaping (ShowRemoval) -> Void) -> some View {
        alert(
            "Remove from Up Next?",
            isPresented: Binding(
                get: { removal.wrappedValue != nil },
                set: { if !$0 { removal.wrappedValue = nil } }
            ),
            presenting: removal.wrappedValue
        ) { pending in
            if pending.markWatched {
                Button("Mark All Episodes as Watched") { perform(pending) }
            } else {
                Button("Mark All Episodes as Unwatched", role: .destructive) { perform(pending) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            if pending.markWatched {
                Text("Every episode of \(pending.showTitle) will be marked as watched, in all your Jellyfin apps. Their watched dates will be set to now.")
            } else {
                Text("Every episode of \(pending.showTitle) will be marked as unwatched, in all your Jellyfin apps. This resets their play counts and watch dates, and can't be undone.")
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
        .frame(width: 320)
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
            ItemActionButtons(entries: actions.menuEntries(for: item))
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
