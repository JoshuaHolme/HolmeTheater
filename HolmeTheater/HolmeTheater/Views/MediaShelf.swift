// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

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

    /// How far the row's scroll view reaches past the shelf's sides, which its content is padded in by to match. For a shelf
    /// that sits inside the screen's safe areas: the cards aren't clipped there, so they show out to the screen's edge, but a
    /// lazy row stops drawing a card once it leaves the scroll view's own frame, which would be the safe area's edge. So
    /// cards would vanish while still on screen. Reaching out to the screen's edge keeps them until they've gone.
    var bleed: CGFloat = 0

    /// Where the cards report having focus (tvOS), so the screen can put it back on one after something else was in front.
    /// Each card's value is `focusPrefix`, a bar, and the item's ID, so the same item in two shelves isn't confused.
    var focus: FocusState<String?>.Binding?
    var focusPrefix = ""

    /// Menu links to leave out, for a shelf that's inside the screen they lead to.
    var omitting: Set<RelatedLink> = []

    /// The ``MediaItem/shelfKey`` of a card to scroll to and, on tvOS, put focus on once the shelf first shows, e.g. the first
    /// episode that isn't watched. Nil leaves focus to the system.
    var autoFocusItemID: String?

    /// Extra entries for an item's long-press menu, after the usual ones.
    var extraMenuEntries: (MediaItem) -> [ItemMenuEntry] = { _ in [] }

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

    /// The shelf's own record of which card has focus, used when its owner gave nowhere to report it, so the shelf can still
    /// move focus to a card.
    @FocusState private var ownFocus: String?

    /// Whether focus has been moved to ``autoFocusItemID``, which only happens once.
    @State private var didAutoFocus = false

    private var focusBinding: FocusState<String?>.Binding { focus ?? $ownFocus }

    /// `items` with the user's latest changes applied.
    private var shownItems: [MediaItem] {
        effects.reduce(items) { $0.applying($1) }
    }

    private var watchActions: WatchActions {
        WatchActions(service: appModel.service, downloads: appModel.downloads, canManageCollections: appModel.canManageCollections, destination: destination, state: $watchState) { effect in
            effects.append(effect)
            onChange()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.shelfHeadingGap) {
            heading
                .padding(.horizontal, Layout.contentInset)

            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: Layout.cardSpacing) {
                        ForEach(shownItems, id: \.shelfKey) { item in
                            card(for: item)
                        }
                        #if os(tvOS)
                        seeAllCard
                        #endif
                    }
                    .padding(.horizontal, Layout.contentInset)
                    .padding(.horizontal, bleed)
                }
                .padding(.horizontal, -bleed)
                .scrollIndicators(.hidden)
                // Lets a focused card lift and grow past the edge of the scroll view.
                .scrollClipDisabled()
                .task(id: autoFocusItemID) { await moveToAutoFocusItem(proxy) }
            }
        }
        // Focus moving up or down lands on this row from anywhere along its width.
        .tvFocusSection()
        // The reload has arrived, so the real data replaces the local changes.
        .onChange(of: items) { effects = [] }
        .watchActionAlerts(watchActions)
    }

    /// Scrolls to the card that's to have focus, so it's been built, then on tvOS asks for focus on it. Only the first time: it
    /// isn't to pull focus back after the viewer has moved on, or when the shelf reloads.
    private func moveToAutoFocusItem(_ proxy: ScrollViewProxy) async {
        guard let id = autoFocusItemID, !didAutoFocus else { return }
        proxy.scrollTo(id, anchor: .leading)
        #if os(tvOS)
        // After the page has settled and the card has been laid out, which focus can't be given to before.
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return }
        focusBinding.wrappedValue = "\(focusPrefix)|\(id)"
        #endif
        didAutoFocus = true
    }

    /// A poster that plays its item when tapped, and peeks and pops when long-pressed.
    @ViewBuilder
    private func card(for item: MediaItem) -> some View {
        var actions = watchActions.actions(for: item, navigation: navigation, omitting: omitting)
        let extra = extraMenuEntries(item)
        let _ = {
            guard !extra.isEmpty else { return }
            actions = actions ?? ItemRowActions()
            actions?.playlistEntries = extra
        }()
        #if os(iOS)
        // A UIKit layer over the card, so that tapping the preview can open the item. SwiftUI's preview can't.
        cardBody(for: item)
            .peekAndPop(WatchActions.peekSpec(for: item, actions: actions, navigation: navigation))
        #else
        Button { navigation.tap(item) } label: {
            cardBody(for: item)
        }
        .cardLinkStyle()
        .modifier(CardFocusTracking(focus: focusBinding, key: "\(focusPrefix)|\(item.shelfKey)"))
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
