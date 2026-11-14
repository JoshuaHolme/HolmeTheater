// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

// The hero's buttons: Play, the trailer, favorite, watched, add-to, and the "Go to" links, plus the iOS toolbar and
// the tvOS details sheet's contents.

extension ShowDetailView {
    #if os(tvOS)
    /// "Go to Season" and "Go to Show", as round buttons beside the others, where they apply.
    @ViewBuilder
    var goToButtons: some View {
        if showsSeasonLink, let seasonID = item.seasonID {
            FocusExpandingIconButton("Go to Season", systemImage: "rectangle.stack.fill", font: Self.heroIconFont) { openRelated(id: seasonID) }
        }
        if showsShowLink, let seriesID = item.seriesID {
            FocusExpandingIconButton("Go to Show", systemImage: "tv", font: Self.heroIconFont) { openRelated(id: seriesID) }
        }
    }

    /// Opens the sheet with the full description and everything else known about the show.
    var detailsButton: some View {
        FocusExpandingIconButton("Details", systemImage: "info.circle", font: Self.heroIconFont) { showsDetails = true }
    }

    /// The sheet's heading: the show's name, or for a season or episode what it is, under the show's.
    var detailsTitle: String {
        if isSeason { return [item.seriesTitle, item.seasonTitle].compactMap { $0 }.joined(separator: " · ") }
        return item.title
    }

    /// What the sheet lists besides the description, as label and value, leaving out what isn't known.
    var detailFacts: [(label: String, value: String)] {
        var facts: [(String, String)] = []
        func add(_ label: String.LocalizationValue, _ value: String?) {
            if let value, !value.isEmpty { facts.append((String(localized: label), value)) }
        }
        add("Genres", current.genres.isEmpty ? nil : current.genres.joined(separator: ", "))
        add(isMovie ? "Studio" : "Network", current.network)
        add(isPlayableItem || isSeason ? "Released" : "Status", statusLine)
        add("Rated", current.officialRating)
        add("Ratings", current.ratingsLine(includingOfficialRating: false))
        add("Format", current.technicalLine)
        return facts
    }
    #endif

    /// Play, then Watch Trailer if the show has one, then the favorite button.
    func actionButtons(showsTrailerTitle: Bool, compactPlay: Bool) -> some View {
        HStack(spacing: Self.buttonSpacing) {
            playButton(compact: compactPlay)
            trailerButton(showsTitle: showsTrailerTitle)
            #if os(tvOS)
            detailsButton
            goToButtons
            // There's no navigation bar on tvOS, so the favorite and watched buttons sit here. On iOS they're in
            // the toolbar (see `toolbarButtons`).
            favoriteButton
            addToPlaylistButton
            addToCollectionButton
            watchedButton
            DownloadToolbarButton(item: current, prompt: $watchState.downloadPrompt, expandsOnFocus: true)
                .heroCircleButton()
            #endif
        }
        #if os(tvOS)
        // As wide as the screen, not just the buttons, so a row below reaches them from any card, not only those
        // directly under them. Otherwise moving up from one further along finds nothing above it.
        .frame(maxWidth: .infinity, alignment: .leading)
        #endif
        // Moving focus up from anywhere along the page lands on these buttons.
        .tvFocusSection()
    }

    /// The icons in the hero's round buttons: the size of Home's More Info icon on tvOS.
    static var heroIconFont: Font {
        #if os(tvOS)
        .system(size: 30, weight: .semibold)
        #else
        .headline
        #endif
    }

    /// Space between the hero's buttons.
    /// (See also `heroCircleButton()` for how the round ones are styled.)
    static var buttonSpacing: CGFloat {
        #if os(tvOS)
        return 24
        #else
        return 12
        #endif
    }

    /// What the watched button does: whether it marks the item watched (or unwatched), and how. Nil if it can't.
    var watchedChange: (wantsWatched: Bool, perform: () -> Void)? {
        let wantsWatched = isPlayableItem ? !current.showsWatchedBadge : current.containerWatchOptions.canMarkWatched
        let actions = watchActions.actions(for: item)
        guard let perform = wantsWatched ? actions?.markWatched : actions?.markUnwatched else { return nil }
        return (wantsWatched, perform)
    }

    /// Marks the show, season or episode watched, or unwatched if it all is. For a show or season that changes every
    /// episode in it, so it asks first, like the menus do.
    @ViewBuilder
    var watchedButton: some View {
        if let change = watchedChange {
            FocusExpandingIconButton(
                change.wantsWatched ? "Mark as Watched" : "Mark as Unwatched",
                systemImage: change.wantsWatched ? "eye" : "eye.slash",
                font: Self.heroIconFont,
                iconColor: change.wantsWatched ? .white : .green,
                action: change.perform
            )
        }
    }

    #if os(iOS)
    /// The favorite and watched buttons for the navigation bar, which keep their place as the page scrolls. They
    /// take the bar's own look, over the artwork or not.
    @ToolbarContentBuilder
    var toolbarButtons: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if showsSeasonLink || showsShowLink {
                Menu {
                    if showsSeasonLink, let seasonID = item.seasonID {
                        Button("Go to Season", systemImage: "rectangle.stack.fill") { openRelated(id: seasonID) }
                    }
                    if showsShowLink, let seriesID = item.seriesID {
                        Button("Go to Show", systemImage: "tv") { openRelated(id: seriesID) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Go To")
            }

            Button {
                toggleFavorite()
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
            }
            .tint(isFavorite ? .red : nil)
            .accessibilityLabel(isFavorite ? "Remove from Favorites" : "Add to Favorites")

            if isPlayableItem || canJoinCollection {
                Menu {
                    if isPlayableItem {
                        Button("Add to Playlist", systemImage: "text.badge.plus") { watchState.playlistItem = current }
                    }
                    if canJoinCollection {
                        Button("Add to Collection", systemImage: "square.stack") { watchState.collectionItem = current }
                    }
                } label: {
                    Image(systemName: "text.badge.plus")
                }
                .accessibilityLabel("Add To")
            }

            // The whole show or season, or the episode or movie itself.
            DownloadToolbarButton(item: current, prompt: $watchState.downloadPrompt)

            if let change = watchedChange {
                Button(action: change.perform) {
                    Image(systemName: change.wantsWatched ? "eye" : "eye.slash")
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
    func trailerButton(showsTitle: Bool) -> some View {
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
    var favoriteButton: some View {
        FocusExpandingIconButton(
            isFavorite ? "Remove from Favorites" : "Add to Favorites",
            systemImage: isFavorite ? "heart.fill" : "heart",
            font: Self.heroIconFont,
            iconColor: isFavorite ? .red : .white,
            action: toggleFavorite
        )
    }

    /// Whether to offer adding this to a collection: it's a movie or a show, not an episode or season, and the user is
    /// allowed to change collections.
    var canJoinCollection: Bool { (isMovie || item.kind == .series) && appModel.canManageCollections }

    /// Opens the sheet for adding a movie or episode to a playlist. Hidden for a show or season, which a playlist doesn't hold.
    @ViewBuilder
    var addToPlaylistButton: some View {
        if isPlayableItem {
            FocusExpandingIconButton(
                "Add to Playlist",
                systemImage: "text.badge.plus",
                font: Self.heroIconFont,
                iconColor: .white,
                action: { watchState.playlistItem = current }
            )
        }
    }

    /// Opens the sheet for adding a movie or show to a collection.
    @ViewBuilder
    var addToCollectionButton: some View {
        if canJoinCollection {
            FocusExpandingIconButton(
                "Add to Collection",
                systemImage: "square.stack",
                font: Self.heroIconFont,
                iconColor: .white,
                action: { watchState.collectionItem = current }
            )
        }
    }

    /// Whether the show is a favorite, counting a change the server hasn't confirmed yet.
    var isFavorite: Bool { favoriteOverride ?? current.isFavorite }

    /// Flips the favorite at once, then tells the server. If that fails, it flips back and shows the error.
    func toggleFavorite() {
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
    func playButton(compact: Bool) -> some View {
        if let episode = nextEpisode {
            Button {
                playingItem = episode
            } label: {
                Label(isPlayableItem || compact ? episode.playButtonTitle(forShow: false) : episode.playButtonTitle(forShow: true), systemImage: "play.fill")
                    #if os(tvOS)
                    .font(.callout.weight(.semibold))
                    #else
                    .font(.headline)
                    #endif
                    #if !os(tvOS)
                    // Dark on white, like the TV app's Play button; the hero's text is white otherwise.
                    .foregroundStyle(.black)
                    #endif
            }
            #if os(tvOS)
            // The same bordered style as the buttons beside it, so all of them take the theme's color when focused (the
            // prominent style draws light gray instead). Play is what's focused first.
            .buttonStyle(.bordered)
            // A pill, as on Home.
            .buttonBorderShape(.capsule)
            // Not on a season's page, where the first unwatched episode is what's focused first.
            .prefersDefaultFocus(!isSeason, in: focusNamespace)
            .focused($focusedControl, equals: .play)
            #else
            .buttonStyle(.glassProminent)
            .tint(.white)
            .controlSize(.large)
            #endif
        }
    }
}
