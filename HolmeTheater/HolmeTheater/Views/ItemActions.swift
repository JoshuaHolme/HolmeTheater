// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// What the "more" menu on a list row can do to its item.
///
/// Every action is optional; one that's nil (or doesn't apply to the item) has no menu entry.
struct ItemRowActions {
    /// Opens the item's detail screen: the menu's first entry, "Go to Movie", "Go to Episode", and so on.
    var goTo: (() -> Void)?

    /// Whether selecting the item plays it (on tvOS, where it otherwise opens), so the menu offers "Go to …" and not Play.
    var tapPlays = false

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

    /// Opens the sheet for adding the item to a playlist. Nil for anything a playlist can't hold, which hides the entry.
    var addToPlaylist: (() -> Void)?

    /// Opens the sheet for adding the item to a collection. Nil for anything a collection can't hold.
    var addToCollection: (() -> Void)?

    /// Entries for an item that's in a playlist: move it earlier or later, or take it out. They come last in the menu.
    var playlistEntries: [ItemMenuEntry] = []

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
        case addToPlaylist
        case addToCollection
        case moveEarlier
        case moveLater
        case removeFromPlaylist
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
        // Selecting a card already opens the item, so the menu leads with Play instead of "Go to …". Where selecting
        // plays it, it's the other way round.
        if tapPlays, let goTo {
            entries.append(ItemMenuEntry(id: .goTo, title: item.goToMenuTitle, systemImage: item.kind == .series ? "tv" : "info.circle", perform: goTo))
        } else if let play {
            entries.append(ItemMenuEntry(id: .play, title: item.playButtonTitle(forShow: false), systemImage: "play.fill", perform: play))
        }
        #else
        if let goTo {
            entries.append(ItemMenuEntry(id: .goTo, title: item.goToMenuTitle, systemImage: item.kind == .series ? "tv" : "info.circle", perform: goTo))
        }
        #endif
        if let goToSeason {
            entries.append(ItemMenuEntry(id: .goToSeason, title: String(localized: "Go to Season"), systemImage: "rectangle.stack.fill", perform: goToSeason))
        }
        if let goToShow {
            entries.append(ItemMenuEntry(id: .goToShow, title: String(localized: "Go to Show"), systemImage: "tv", perform: goToShow))
        }
        if let addToPlaylist {
            entries.append(ItemMenuEntry(id: .addToPlaylist, title: String(localized: "Add to Playlist"), systemImage: "text.badge.plus", perform: addToPlaylist))
        }
        if let addToCollection {
            entries.append(ItemMenuEntry(id: .addToCollection, title: String(localized: "Add to Collection"), systemImage: "square.stack", perform: addToCollection))
        }
        return entries + watchEntries(for: item) + downloadEntries + playlistEntries
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
                    systemImage: "eye",
                    perform: markWatched
                ))
            }
            if let markUnwatched, options.canMarkUnwatched {
                entries.append(ItemMenuEntry(
                    id: .markUnwatched,
                    title: isSeason ? String(localized: "Mark Season as Unwatched") : String(localized: "Mark Show as Unwatched"),
                    systemImage: "eye.slash",
                    perform: markUnwatched
                ))
            }
            return entries
        }

        var entries: [ItemMenuEntry] = []

        // A partly watched item offers both, so the user can finish it or start it over.
        if let markWatched, !item.showsWatchedBadge {
            entries.append(ItemMenuEntry(id: .markWatched, title: String(localized: "Mark as Watched"), systemImage: "eye", perform: markWatched))
        }
        if let markUnwatched, item.isPlayed || item.playedFraction != nil {
            entries.append(ItemMenuEntry(id: .markUnwatched, title: String(localized: "Mark as Unwatched"), systemImage: "eye.slash", perform: markUnwatched))
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
                    ItemMenuEntry(id: .markAllEpisodesWatched, title: String(localized: "Mark All Episodes as Watched"), systemImage: "eye", perform: showWatched),
                    ItemMenuEntry(id: .markAllEpisodesUnwatched, title: String(localized: "Mark All Episodes as Unwatched"), systemImage: "eye.slash", perform: showUnwatched)
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
