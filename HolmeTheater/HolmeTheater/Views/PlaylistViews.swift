// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// A collection (a group of movies or shows, such as a film series) opened as a poster grid.
struct CollectionDetailView: View {
    let collection: MediaItem

    @Environment(AppModel.self) private var appModel

    /// A question about downloading the collection, waiting for an answer.
    @State private var downloadPrompt: DownloadPrompt?

    /// What the collection held when last loaded, for the sheet that takes things out of it.
    @State private var members: [MediaItem] = []

    /// Whether the sheet for taking things out of the collection is showing.
    @State private var showsManage = false

    /// Changing this reloads the collection, after something was taken out of it.
    @State private var reloadID = 0

    /// Whether the collection's members are known, which its download button needs to say how its downloads are doing.
    private var hasMembers: Bool { !(appModel.downloads.groupMembers[collection.id] ?? []).isEmpty }

    /// Whether to offer editing, which the server only allows some users.
    private var canEdit: Bool { hasMembers && appModel.canManageCollections }

    var body: some View {
        AsyncContent(load: loadItems, reloadID: reloadID, placeholder: SkeletonPosterGrid()) { items in
            if items.isEmpty {
                ContentUnavailableView("Empty Collection", systemImage: "square.stack", description: Text("There's nothing in this collection yet."))
            } else {
                PosterBrowser(items: items) { viewport in
                    ListHero(
                        item: collection,
                        style: .artwork(collection.heroArtworkURL(among: items)),
                        detailsLine: detailsLine(for: items),
                        viewport: viewport
                    ) {
                        heroButtons
                    }
                }
            }
        }
        .themeWash()
        .downloadPrompts($downloadPrompt)
        .sheet(isPresented: $showsManage, onDismiss: { reloadID += 1 }) {
            CollectionMembersSheet(collection: collection, members: members)
        }
        #if os(iOS)
        .toolbar {
            if canEdit {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showsManage = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .accessibilityLabel("Edit Collection")
                }
            }
            if hasMembers {
                ToolbarItem(placement: .primaryAction) {
                    DownloadToolbarButton(item: collection, prompt: $downloadPrompt)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        // The hero already names the collection.
        .toolbar(removing: .title)
        #endif
        #if os(tvOS)
        // The hero names the collection, and tvOS would double it.
        .navigationTitle("")
        #else
        .navigationTitle(collection.title)
        #endif
    }

    /// The hero's buttons. On iOS the toolbar has them; there's no navigation bar on tvOS.
    @ViewBuilder
    private var heroButtons: some View {
        #if os(tvOS)
        if hasMembers {
            HStack(spacing: 24) {
                if canEdit {
                    FocusExpandingIconButton(
                        "Edit Collection",
                        systemImage: "pencil",
                        font: .system(size: 30, weight: .semibold),
                        iconColor: .white,
                        action: { showsManage = true }
                    )
                }
                DownloadToolbarButton(item: collection, prompt: $downloadPrompt, expandsOnFocus: true)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
            }
        }
        #endif
    }

    /// e.g. "5 items · Action · Adventure": how many it holds, then its commonest genres.
    private func detailsLine(for items: [MediaItem]) -> String {
        let counts = Dictionary(grouping: items.flatMap(\.genres), by: { $0 }).mapValues(\.count)
        let genres = counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(3).map(\.key)
        return ([String(localized: "\(items.count) items")] + genres).joined(separator: " · ")
    }

    private func loadItems() async throws -> [MediaItem] {
        let items = try await appModel.service.children(of: collection)
        appModel.downloads.register(items, asMembersOf: collection)
        members = items
        await ImageCache.shared.preload(items.prefix(18).compactMap(\.posterURL))
        return items
    }
}

/// A collection's members, each with a button to take it out. The movies and shows themselves stay on the server.
private struct CollectionMembersSheet: View {
    let collection: MediaItem

    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var members: [MediaItem]
    @State private var errorMessage: String?
    /// The member being taken out, so its row can show progress and a second tap does nothing.
    @State private var removing: String?

    init(collection: MediaItem, members: [MediaItem]) {
        self.collection = collection
        _members = State(initialValue: members)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(members) { member in
                    HStack(spacing: 16) {
                        ArtworkView(url: member.posterURL, aspectRatio: 2.0 / 3.0)
                            .frame(width: 48)
                        Text(member.title)
                            .lineLimit(2)
                        Spacer()
                        if removing == member.id {
                            ProgressView()
                        } else {
                            Button {
                                remove(member)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .disabled(removing != nil)
                            .accessibilityLabel("Remove \(member.title) from Collection")
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .overlay {
                if members.isEmpty {
                    ContentUnavailableView("Empty Collection", systemImage: "square.stack")
                }
            }
            .navigationTitle(collection.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func remove(_ member: MediaItem) {
        removing = member.id
        errorMessage = nil
        let (service, collectionID) = (appModel.service, collection.id)
        Task {
            do {
                try await service.removeItems(withIDs: [member.id], fromCollection: collectionID)
                members.removeAll { $0.id == member.id }
            } catch {
                errorMessage = error.localizedDescription
            }
            removing = nil
        }
    }
}

/// What the full-screen player is opened with: an item, and the ones that play after it.
private struct PlaylistPlayback: Identifiable {
    let id = UUID()
    let item: MediaItem
    let queue: [MediaItem]
}

/// A playlist laid out like a TV season: its hero, then its entries in a row of widescreen cards that scrolls sideways. The
/// cards have the watched badge and progress an episode has, selecting one plays from it through the rest of the playlist, and
/// on tvOS focus starts on the first one that isn't watched.
struct PlaylistDetailView: View {
    let playlist: MediaItem

    @Environment(AppModel.self) private var appModel

    private enum Phase {
        case loading
        case loaded
        case failed(String)
    }

    @State private var phase = Phase.loading
    @State private var entries: [MediaItem] = []
    @State private var playback: PlaylistPlayback?
    @State private var errorMessage: String?

    /// An entry's page, which a tap on its menu's "Go to …" is opening.
    @State private var openedItem: MediaItem?

    /// A question about downloading the playlist, waiting for an answer.
    @State private var downloadPrompt: DownloadPrompt?

    /// Marking every entry watched (true) or unwatched (false), waiting for the user to confirm.
    @State private var pendingWatchChange: Bool?

    /// The size of the scroll view, which decides how tall the hero is.
    @State private var viewport: CGSize = .zero

    /// Which card in the row has focus (tvOS), as ``MediaShelf`` reports it: the prefix, a bar, then the entry's key.
    @FocusState private var focusedCard: String?

    /// The picture blurred behind the page: the still of the entry that has focus, or if none has yet, the one that will.
    @State private var backgroundURL: URL?

    private static let focusPrefix = "playlist"

    var body: some View {
        content
            .themeWash(0.5)
            .downloadPrompts($downloadPrompt)
            // What the playlist holds decides how its downloads are doing, and changes as entries are added, moved or removed.
            .onChange(of: entries.map(\.shelfKey)) {
                appModel.downloads.register(entries, asMembersOf: playlist)
            }
            #if os(tvOS)
            // The hero names the playlist, and tvOS would double it.
            .navigationTitle("")
            #else
            .navigationTitle(playlist.title)
            .navigationBarTitleDisplayMode(.inline)
            // The hero already names the playlist.
            .toolbar(removing: .title)
            .toolbar {
                if !entries.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        DownloadToolbarButton(item: playlist, prompt: $downloadPrompt)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            pendingWatchChange = wantsMarkWatched
                        } label: {
                            Image(systemName: wantsMarkWatched ? "eye" : "eye.slash")
                        }
                        .tint(wantsMarkWatched ? nil : .green)
                        .accessibilityLabel(wantsMarkWatched ? "Mark as Watched" : "Mark as Unwatched")
                        // VoiceOver would otherwise announce a checkmark image as "selected", which this is not.
                        .accessibilityRemoveTraits(.isSelected)
                    }
                }
            }
            #endif
            .task { await load() }
            .fullScreenCover(item: $playback) { request in
                PlayerView(item: request.item, queue: request.queue, onStop: { Task { await load() } })
            }
            .navigationDestination(item: $openedItem) { ItemDetailView(item: $0) }
            .alert("Couldn't Change the Playlist", isPresented: $errorMessage.isPresent()) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .alert(
                pendingWatchChange == false ? "Mark Playlist as Unwatched?" : "Mark Playlist as Watched?",
                isPresented: $pendingWatchChange.isPresent(),
                presenting: pendingWatchChange
            ) { watched in
                if watched {
                    Button("Mark as Watched") { setWatched(true) }
                } else {
                    Button("Mark as Unwatched", role: .destructive) { setWatched(false) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { watched in
                if watched {
                    Text("Everything in \(playlist.title) will be marked as watched, in all your Jellyfin apps. Their watched dates will be set to now.")
                } else {
                    Text("Everything in \(playlist.title) will be marked as unwatched, in all your Jellyfin apps. This resets their play counts and watch dates, and can't be undone.")
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading where entries.isEmpty:
            SkeletonScroll { SkeletonRows(count: 8, aspectRatio: 16.0 / 9.0).padding(.horizontal) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Loading")
        case .failed(let message) where entries.isEmpty:
            ContentUnavailableView {
                Label("Couldn't Load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { Task { await load() } }
            }
        default:
            page
        }
    }

    /// The hero, then the entries, in a scroll view like a season's page has, so the hero fills the screen and scrolls away
    /// the same way.
    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Self.rowSpacing) {
                ListHero(
                    item: playlist,
                    // As on a season's page: no artwork behind the details, a sharp poster in the top right.
                    style: .poster(playlist.posterURL ?? entries.first?.posterURL),
                    detailsLine: entries.isEmpty ? nil : summary,
                    viewport: viewport
                ) {
                    heroButtons
                }

                if entries.isEmpty {
                    ContentUnavailableView("Empty Playlist", systemImage: "list.bullet.rectangle", description: Text("Add movies and episodes from their pages."))
                        .frame(maxWidth: .infinity)
                } else {
                    MediaShelf(
                        title: entries.count == 1 ? String(localized: "1 Item") : String(localized: "\(entries.count) Items"),
                        items: entries,
                        isWide: true,
                        hasMore: false,
                        // Reports which card has focus, so the page's background can follow it.
                        focus: $focusedCard,
                        focusPrefix: Self.focusPrefix,
                        autoFocusItemID: firstUnwatched?.shelfKey,
                        extraMenuEntries: menuEntries(for:),
                        onChange: { Task { await load() } },
                        // Selecting an entry plays it and the ones after it; its page is "Go to …" in the menu.
                        navigation: ItemNavigation(open: { openedItem = $0 }, play: { play(from: $0) }, playsOnTap: true)
                    )
                }
            }
            .padding(.bottom)
            // The entry that has focus, blurred, fills the whole page behind the hero and the row, and moves with the page.
            .background(alignment: .top) { BlurredPageBackground(url: backgroundURL) }
        }
        .task(id: "\(focusedCard ?? "")|\(entries.isEmpty)") { await updateBackground() }
        #if os(tvOS)
        // Measured before the safe area is ignored, so the hero can be as tall as the whole screen, as Home's is.
        .onGeometryChange(for: CGSize.self) { proxy in
            CGSize(width: proxy.size.width, height: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom)
        } action: { viewport = $0 }
        #else
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewport = $0 }
        #endif
        // The hero runs under the status and navigation bars, up to the top edge of the screen.
        .ignoresSafeArea(edges: .top)
    }

    /// Space between the hero and the row beneath it.
    private static var rowSpacing: CGFloat {
        #if os(tvOS)
        Layout.shelfSpacing
        #else
        24
        #endif
    }

    // MARK: Background

    /// Changes the blurred background to the still of the entry that has focus.
    ///
    /// Only that one picture is ever loaded, and it's the still the card is already showing, so it's in the image cache. Focus has
    /// to rest on a card for a moment first, so moving quickly along the row doesn't change it on every card. When focus is
    /// somewhere else (on Play, say) the background stays as it was. Before focus has been anywhere, it's the still of the entry
    /// that's about to get it, or on iOS, which has no focus, the one it stays on.
    private func updateBackground() async {
        let target: URL?
        if let key = focusedCard, key.hasPrefix(Self.focusPrefix + "|") {
            let entryKey = String(key.dropFirst(Self.focusPrefix.count + 1))
            target = entries.first { $0.shelfKey == entryKey }?.gridArtworkURL
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
        } else if backgroundURL == nil {
            target = (firstUnwatched ?? entries.first)?.gridArtworkURL ?? playlist.posterURL
        } else {
            return
        }
        guard let target, target != backgroundURL else { return }
        // In memory before the fade starts, so it fades in from the old picture rather than from nothing.
        await ImageCache.shared.preload([target], timeout: .milliseconds(800))
        guard !Task.isCancelled else { return }
        backgroundURL = target
    }

    // MARK: Hero

    /// The first entry that isn't watched, which Play starts from and focus lands on. Nil if everything is.
    private var firstUnwatched: MediaItem? { entries.first { !$0.isPlayed } }

    /// Whether the watched button marks everything watched, rather than unwatched: unless everything already is.
    private var wantsMarkWatched: Bool { !entries.allSatisfy(\.showsWatchedBadge) }

    /// What Play says: "Play" or, for one that's partly watched, "Resume", then the name of the entry it starts from.
    private var playTitle: String {
        guard let start = firstUnwatched ?? entries.first else { return String(localized: "Play") }
        return start.playedFraction == nil ? String(localized: "Play \(start.title)") : String(localized: "Resume \(start.title)")
    }

    /// "12 items · 18h 40m".
    private var summary: String {
        let count = String(localized: "\(entries.count) items")
        let total = entries.compactMap(\.runtime).reduce(0, +)
        guard total > 0 else { return count }
        let time = Duration.seconds(total).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
        return "\(count) · \(time)"
    }

    /// Play and Shuffle, styled like the show page's buttons, and on tvOS, which has no toolbar, the watched and download buttons.
    private var heroButtons: some View {
        #if os(tvOS)
        HStack(spacing: 24) {
            // The same bordered capsules as the show page's, so they take the theme's color when focused.
            Button(action: playNext) {
                Label(playTitle, systemImage: "play.fill")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: 640)
                    .fixedSize()
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .disabled(entries.isEmpty)

            Button(action: shuffle) {
                Label("Shuffle", systemImage: "shuffle")
                    .font(.callout.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .disabled(entries.isEmpty)

            if !entries.isEmpty {
                FocusExpandingIconButton(
                    wantsMarkWatched ? "Mark as Watched" : "Mark as Unwatched",
                    systemImage: wantsMarkWatched ? "eye" : "eye.slash",
                    font: .system(size: 30, weight: .semibold),
                    iconColor: wantsMarkWatched ? .white : .green,
                    action: { pendingWatchChange = wantsMarkWatched }
                )
                DownloadToolbarButton(item: playlist, prompt: $downloadPrompt, expandsOnFocus: true)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
            }
        }
        #else
        HStack(spacing: 12) {
            // Dark on white, like the TV app's Play button; the hero's text is white otherwise.
            Button(action: playNext) {
                Label(playTitle, systemImage: "play.fill")
                    .font(.headline)
                    .foregroundStyle(.black)
                    .lineLimit(1)
                    .frame(maxWidth: 240)
                    .fixedSize()
            }
            .buttonStyle(.glassProminent)
            .tint(.white)
            .controlSize(.large)
            .disabled(entries.isEmpty)

            Button(action: shuffle) {
                Label("Shuffle", systemImage: "shuffle")
                    .font(.headline)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .disabled(entries.isEmpty)
        }
        #endif
    }

    // MARK: Playing

    /// Plays from the first entry that isn't watched, or the start if everything is, through to the end.
    private func playNext() {
        guard let start = firstUnwatched ?? entries.first else { return }
        play(from: start)
    }

    /// Plays an entry and the ones after it.
    private func play(from entry: MediaItem) {
        guard let index = entries.firstIndex(where: { $0.shelfKey == entry.shelfKey }) else { return }
        playback = PlaylistPlayback(item: entries[index], queue: Array(entries[index...]))
    }

    private func shuffle() {
        let shuffled = entries.shuffled()
        guard let first = shuffled.first else { return }
        playback = PlaylistPlayback(item: first, queue: shuffled)
    }

    // MARK: Loading and editing

    private func load() async {
        do {
            let latest = try await appModel.service.children(of: playlist)
            await ImageCache.shared.preload(latest.prefix(4).compactMap(\.gridArtworkURL))
            entries = latest
            phase = .loaded
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// The entries of an entry's long-press menu that belong to a playlist: move it, or take it out.
    private func menuEntries(for entry: MediaItem) -> [ItemMenuEntry] {
        guard let index = entries.firstIndex(where: { $0.shelfKey == entry.shelfKey }) else { return [] }
        var result: [ItemMenuEntry] = []
        if index > 0 {
            result.append(ItemMenuEntry(id: .moveEarlier, title: String(localized: "Move Earlier"), systemImage: "arrow.left", perform: { moveEntry(at: index, to: index - 1) }))
        }
        if index < entries.count - 1 {
            result.append(ItemMenuEntry(id: .moveLater, title: String(localized: "Move Later"), systemImage: "arrow.right", perform: { moveEntry(at: index, to: index + 1) }))
        }
        result.append(ItemMenuEntry(id: .removeFromPlaylist, title: String(localized: "Remove from Playlist"), systemImage: "minus.circle", perform: { remove(at: index) }))
        return result
    }

    /// Moves an entry at once, then tells the server. If that fails, the playlist is fetched again to show what's really there.
    private func moveEntry(at from: Int, to index: Int) {
        guard entries.indices.contains(from), entries.indices.contains(index), from != index else { return }
        let entry = entries.remove(at: from)
        entries.insert(entry, at: index)
        guard let entryID = entry.playlistEntryID else { return }
        let (service, playlistID) = (appModel.service, playlist.id)
        Task {
            do {
                try await service.moveEntry(withID: entryID, inPlaylist: playlistID, to: index)
            } catch {
                errorMessage = error.localizedDescription
                await load()
            }
        }
    }

    /// Takes an entry out at once, then tells the server. If that fails, the playlist is fetched again to show what's really there.
    private func remove(at index: Int) {
        guard entries.indices.contains(index) else { return }
        let removed = entries.remove(at: index)
        guard let entryID = removed.playlistEntryID else { return }
        let (service, playlistID) = (appModel.service, playlist.id)
        Task {
            do {
                try await service.removeEntries(withIDs: [entryID], fromPlaylist: playlistID)
            } catch {
                errorMessage = error.localizedDescription
                await load()
            }
        }
    }

    /// Marks every entry watched or unwatched, once the user has confirmed. They show it at once; if the server refuses any,
    /// the playlist is fetched again to show what's really so, with the reason.
    private func setWatched(_ watched: Bool) {
        entries = entries.map { entry in
            var entry = entry
            entry.isPlayed = watched
            entry.playedFraction = nil
            return entry
        }
        let service = appModel.service
        // The same movie twice in a playlist is still one thing to mark.
        let ids = Array(Set(entries.map(\.id)))
        Task {
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for id in ids {
                        group.addTask {
                            if watched {
                                try await service.markWatched(itemID: id)
                            } else {
                                try await service.markUnwatched(itemID: id)
                            }
                        }
                    }
                    try await group.waitForAll()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            await load()
        }
    }
}
