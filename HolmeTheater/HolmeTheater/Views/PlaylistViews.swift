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
        AsyncContent(load: loadItems, reloadID: reloadID) { items in
            if items.isEmpty {
                ContentUnavailableView("Empty Collection", systemImage: "square.stack", description: Text("There's nothing in this collection yet."))
            } else {
                PosterBrowser(items: items, hero: { viewport in
                    AnyView(
                        ListHero(
                            item: collection,
                            imageURL: collection.heroArtworkURL(among: items),
                            detailsLine: detailsLine(for: items),
                            viewport: viewport
                        ) {
                            heroButtons
                        }
                    )
                })
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

/// A playlist's entries in order, to play through, shuffle, reorder and take things out of.
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

    /// A question about downloading the playlist, waiting for an answer.
    @State private var downloadPrompt: DownloadPrompt?

    /// The size of the list, which decides how tall the hero is.
    @State private var viewport: CGSize = .zero

    var body: some View {
        content
            .themeWash()
            .downloadPrompts($downloadPrompt)
            // What the playlist holds decides how its downloads are doing, and changes as entries are added, moved or removed.
            .onChange(of: entries.map(\.entryID)) {
                appModel.downloads.register(entries, asMembersOf: playlist)
            }
            #if os(tvOS)
            .navigationTitle("")
            #else
            .navigationTitle(playlist.title)
            #endif
            .task { await load() }
            .fullScreenCover(item: $playback) { request in
                PlayerView(item: request.item, queue: request.queue, onStop: { Task { await load() } })
            }
            .alert("Couldn't Change the Playlist", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading where entries.isEmpty:
            ProgressView()
        case .failed(let message) where entries.isEmpty:
            ContentUnavailableView {
                Label("Couldn't Load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { Task { await load() } }
            }
        default:
            list
        }
    }

    private var list: some View {
        #if os(tvOS)
        tvList
        #else
        iosList
        #endif
    }

    #if os(tvOS)
    /// The hero over the entries in a scroll view, as the show page has, so the hero fills the screen and scrolls away the same
    /// way. (A list's rows are inset, and can't have a hero that runs edge to edge.)
    private var tvList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.shelfSpacing) {
                ListHero(
                    item: playlist,
                    imageURL: playlist.heroArtworkURL(among: entries),
                    detailsLine: entries.isEmpty ? nil : summary,
                    viewport: viewport
                ) {
                    heroButtons
                }

                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(entries, id: \.entryID) { entry in
                        row(for: entry)
                    }

                    if entries.isEmpty, case .loaded = phase {
                        ContentUnavailableView("Empty Playlist", systemImage: "list.bullet.rectangle", description: Text("Add movies and episodes from their pages."))
                    }
                }
                .buttonStyle(.card)
                .padding(.horizontal, Layout.contentInset)
                .padding(.bottom)
            }
        }
        // Measured before the safe area is ignored, so the hero can be as tall as the whole screen, as Home's is.
        .onGeometryChange(for: CGSize.self) { proxy in
            CGSize(width: proxy.size.width, height: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom)
        } action: { viewport = $0 }
        .ignoresSafeArea(edges: .top)
    }
    #else
    private var iosList: some View {
        List {
            ListHero(
                item: playlist,
                imageURL: playlist.heroArtworkURL(among: entries),
                detailsLine: entries.isEmpty ? nil : summary,
                viewport: viewport
            ) {
                heroButtons
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            Section {
                ForEach(entries, id: \.entryID) { entry in
                    row(for: entry)
                }
                .onMove(perform: move)
                .onDelete(perform: delete)

                if entries.isEmpty, case .loaded = phase {
                    ContentUnavailableView("Empty Playlist", systemImage: "list.bullet.rectangle", description: Text("Add movies and episodes from their pages."))
                        .listRowBackground(Color.clear)
                }
            }
        }
        // The hero runs under the status and navigation bars, up to the top edge of the screen.
        .ignoresSafeArea(edges: .top)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewport = $0 }
        .navigationBarTitleDisplayMode(.inline)
        // The hero already names the playlist.
        .toolbar(removing: .title)
        .toolbar {
            if !entries.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    DownloadToolbarButton(item: playlist, prompt: $downloadPrompt)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                EditButton()
            }
        }
    }
    #endif

    /// Play and Shuffle, styled like the show page's buttons, and on tvOS, which has no toolbar, the download button.
    private var heroButtons: some View {
        #if os(tvOS)
        HStack(spacing: 24) {
            // The same bordered capsules as the show page's, so they take the theme's color when focused.
            Button(action: play) {
                Label("Play", systemImage: "play.fill")
                    .font(.callout.weight(.semibold))
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
                DownloadToolbarButton(item: playlist, prompt: $downloadPrompt, expandsOnFocus: true)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
            }
        }
        #else
        HStack(spacing: 12) {
            // Dark on white, like the TV app's Play button; the hero's text is white otherwise.
            Button(action: play) {
                Label("Play", systemImage: "play.fill")
                    .font(.headline)
                    .foregroundStyle(.black)
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

    private func play() {
        guard let first = entries.first else { return }
        playback = PlaylistPlayback(item: first, queue: entries)
    }

    private func shuffle() {
        let shuffled = entries.shuffled()
        guard let first = shuffled.first else { return }
        playback = PlaylistPlayback(item: first, queue: shuffled)
    }

    /// "12 items · 18h 40m".
    private var summary: String {
        let count = String(localized: "\(entries.count) items")
        let total = entries.compactMap(\.runtime).reduce(0, +)
        guard total > 0 else { return count }
        let time = Duration.seconds(total).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
        return "\(count) · \(time)"
    }

    private func row(for entry: MediaItem) -> some View {
        Button {
            guard let index = entries.firstIndex(where: { $0.entryID == entry.entryID }) else { return }
            playback = PlaylistPlayback(item: entry, queue: Array(entries[index...]))
        } label: {
            HStack(spacing: 16) {
                ArtworkView(url: entry.rowArtworkURL, aspectRatio: entry.hasWidescreenRowArtwork ? 16.0 / 9.0 : 2.0 / 3.0)
                    .frame(width: entry.hasWidescreenRowArtwork ? rowArtworkWidth : rowArtworkWidth / 2)

                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(entry.captionLines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(index == 0 ? .body : .subheadline)
                            .foregroundStyle(index == 0 ? .primary : .secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
        .contextMenu {
            if let index = entries.firstIndex(where: { $0.entryID == entry.entryID }) {
                if index > 0 {
                    Button("Move Up", systemImage: "arrow.up") { moveEntry(at: index, to: index - 1) }
                }
                if index < entries.count - 1 {
                    Button("Move Down", systemImage: "arrow.down") { moveEntry(at: index, to: index + 1) }
                }
                Button("Remove from Playlist", systemImage: "minus.circle", role: .destructive) { remove(at: [index]) }
            }
        }
    }

    private var rowArtworkWidth: CGFloat {
        #if os(tvOS)
        return 240
        #else
        return 112
        #endif
    }

    // MARK: Loading and editing

    private func load() async {
        do {
            entries = try await appModel.service.children(of: playlist)
            phase = .loaded
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    #if os(iOS)
    private func move(from source: IndexSet, to destination: Int) {
        guard let from = source.first else { return }
        // `move(toOffset:)` counts the gap the item leaves, which the server's index doesn't.
        moveEntry(at: from, to: destination > from ? destination - 1 : destination)
    }

    private func delete(at offsets: IndexSet) {
        remove(at: Array(offsets))
    }
    #endif

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

    /// Takes entries out at once, then tells the server. If that fails, the playlist is fetched again to show what's really there.
    private func remove(at indices: [Int]) {
        let removed = indices.filter(entries.indices.contains).map { entries[$0] }
        entries.remove(atOffsets: IndexSet(indices))
        let entryIDs = removed.compactMap(\.playlistEntryID)
        guard !entryIDs.isEmpty else { return }
        let (service, playlistID) = (appModel.service, playlist.id)
        Task {
            do {
                try await service.removeEntries(withIDs: entryIDs, fromPlaylist: playlistID)
            } catch {
                errorMessage = error.localizedDescription
                await load()
            }
        }
    }
}

private extension MediaItem {
    /// Identifies an entry in a playlist, which can hold the same item more than once.
    var entryID: String { playlistEntryID ?? id }
}
