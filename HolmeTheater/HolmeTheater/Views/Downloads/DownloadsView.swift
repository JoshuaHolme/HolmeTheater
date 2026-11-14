// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

// The Downloads tab itself: what's downloading, then what's saved, organized like the library.

/// A show's page within Downloads: the seasons that have downloaded episodes.
struct DownloadedShowRoute: Hashable { let seriesID: String }

/// A season's page within Downloads: its downloaded episodes.
struct DownloadedSeasonRoute: Hashable { let seasonID: String }

/// The Downloads tab: what's downloading, then what's saved, organized like the library, with movies, and shows with
/// their seasons and episodes.
struct DownloadsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var playingItem: MediaItem?
    @State private var confirmsDeleteAll = false

    private var downloads: DownloadManager { appModel.downloads }

    private var unfinished: [DownloadRecord] { downloads.records.filter { !$0.isComplete } }

    private var movies: [DownloadRecord] { DownloadLibrary.movies(from: downloads.records) }

    /// The shows with downloaded episodes, in name order.
    private var shows: [DownloadLibrary.Show] {
        DownloadLibrary.shows(from: downloads.records) { downloads.store.container(id: $0)?.title }
    }

    var body: some View {
        content
            .themeWash()
            // The system may have removed files since this was last open.
            .onAppear { downloads.verifyFiles() }
            .navigationDestination(for: DownloadedShowRoute.self) { DownloadedShowView(seriesID: $0.seriesID, play: { playingItem = $0 }) }
            .navigationDestination(for: DownloadedSeasonRoute.self) { DownloadedSeasonView(seasonID: $0.seasonID, play: { playingItem = $0 }) }
            .alert("Delete All Downloads?", isPresented: $confirmsDeleteAll) {
                Button("Delete", role: .destructive) { downloads.remove(ids: downloads.records.map(\.id)) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Everything saved on this device is deleted. It all stays on your server.")
            }
            .fullScreenCover(item: $playingItem) { PlayerView(item: $0) }
    }

    @ViewBuilder
    private var content: some View {
        #if os(tvOS)
        tvContent
        #else
        listContent
        #endif
    }

    /// The "more" menu, with what it needs handed in as plain values, so it's only redrawn when one of them changes. It's
    /// separate for that: the page redraws with every tick of an active download's progress, and a menu redrawn under the
    /// viewer's eyes flashes its items.
    private var manageMenu: some View {
        ManageDownloadsMenu(hasUnfinished: !unfinished.isEmpty, confirmsDeleteAll: $confirmsDeleteAll)
            .equatable()
    }

    #if os(tvOS)
    /// Whether the sheet explaining what's experimental about downloads on Apple TV is open.
    @State private var showsNotice = false

    /// A movie's details, opened from its long-press menu (selecting it plays it).
    @State private var detailItem: MediaItem?

    /// The page as the rest of the app's are: a title line with its buttons, then each kind of download as a row of posters.
    private var tvContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.shelfSpacing) {
                tvHeader

                if downloads.records.isEmpty {
                    ContentUnavailableView {
                        Label("No Downloads", systemImage: "arrow.down.circle")
                    } description: {
                        Text("Movies and episodes you download appear here, and can be watched without a connection.")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    if !unfinished.isEmpty {
                        tvSection("Downloading") {
                            VStack(spacing: 16) {
                                ForEach(unfinished) { record in
                                    UnfinishedDownloadRow(record: record)
                                        .padding(20)
                                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
                                }
                            }
                            // The buttons are at the end of full-width rows, so moving down from anywhere above, such as the
                            // Experimental pill, which has nothing right beneath it, reaches them.
                            .tvFocusSection()
                        }
                    }

                    if !movies.isEmpty {
                        tvSection("Movies") {
                            posterGrid {
                                ForEach(movies) { record in
                                    let item = downloads.localized(record.item)
                                    Button { playingItem = item } label: {
                                        PosterCard(item: item, titleLineLimit: 2)
                                    }
                                    .cardLinkStyle()
                                    .contextMenu {
                                        Button("Go to Movie", systemImage: "info.circle") { detailItem = item }
                                        Button("Delete", systemImage: "trash", role: .destructive) { downloads.remove(ids: [record.id]) }
                                    }
                                }
                            }
                        }
                    }

                    if !shows.isEmpty {
                        tvSection("TV Shows") {
                            posterGrid {
                                ForEach(shows, id: \.id) { show in
                                    NavigationLink(value: DownloadedShowRoute(seriesID: show.id)) {
                                        ShowDownloadCard(seriesID: show.id, title: show.title, episodes: show.episodes)
                                    }
                                    .cardLinkStyle()
                                    .deleteAction { downloads.remove(ids: show.episodes.map(\.id)) }
                                }
                            }
                        }
                    }

                    Text("Downloads use \(downloads.totalBytes.formatted(.byteCount(style: .file))) on this device.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        // The page draws its own title, level with its buttons.
        .navigationTitle("")
        .navigationDestination(item: $detailItem) { ItemDetailView(item: $0) }
        .sheet(isPresented: $showsNotice) {
            ScrollView {
                ExperimentalNotice(isPermanent: downloads.store.isPermanent)
                    .padding(60)
            }
        }
    }

    private var tvHeader: some View {
        HStack(spacing: 24) {
            // No title: the tab bar already says "Downloads".
            Spacer(minLength: 24)
            // Downloads here are experimental: a button that says so, which opens what to know before relying on them.
            Button { showsNotice = true } label: {
                Label("Experimental", systemImage: "exclamationmark.triangle.fill")
            }
            .buttonBorderShape(.capsule)
            .tint(.orange)
            if !downloads.records.isEmpty {
                manageMenu
            }
        }
        // Moving up from anywhere along the first row reaches the buttons.
        .tvFocusSection()
        // Up toward the top of the screen, level with the tab bar's label, rather than a row of its own.
        .padding(.top, -90)
    }

    private func tvSection<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Layout.shelfHeadingGap) {
            Text(title)
                .font(Layout.shelfHeadingFont)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func posterGrid<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: Layout.cardSpacing, alignment: .top)], alignment: .leading, spacing: Layout.cardSpacing) {
            content()
        }
        .tvFocusSection()
    }
    #endif

    #if !os(tvOS)
    private var listContent: some View {
        List {
            if !unfinished.isEmpty {
                Section("Downloading") {
                    ForEach(unfinished) { record in
                        UnfinishedDownloadRow(record: record)
                    }
                }
            }

            if !movies.isEmpty {
                Section("Movies") {
                    ForEach(movies) { record in
                        SavedDownloadRow(record: record, play: { playingItem = $0 })
                    }
                }
            }

            if !shows.isEmpty {
                Section("TV Shows") {
                    ForEach(shows, id: \.id) { show in
                        NavigationLink(value: DownloadedShowRoute(seriesID: show.id)) {
                            ShowDownloadRow(seriesID: show.id, title: show.title, episodes: show.episodes)
                        }
                        .deleteAction { downloads.remove(ids: show.episodes.map(\.id)) }
                    }
                }
            }

            if !downloads.records.isEmpty {
                Section {
                    EmptyView()
                } footer: {
                    Text("Downloads use \(downloads.totalBytes.formatted(.byteCount(style: .file))) on this device.")
                }
            }
        }
        .overlay {
            if downloads.records.isEmpty {
                ContentUnavailableView {
                    Label("No Downloads", systemImage: "arrow.down.circle")
                } description: {
                    Text("Movies and episodes you download appear here, and can be watched without a connection.")
                }
            }
        }
        .navigationTitle("Downloads")
        .toolbar {
            if !downloads.records.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    manageMenu
                }
            }
        }
    }
    #endif
}

extension View {
    /// The alert for a download that couldn't be started. Attach once, at the root: every screen can start a download,
    /// and the tabs keep their screens alive, so an alert on each would all try to show the one error at once.
    func downloadErrorAlert(_ downloads: DownloadManager) -> some View {
        @Bindable var downloads = downloads
        return alert("Couldn't Download", isPresented: $downloads.errorMessage.isPresent()) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(downloads.errorMessage ?? "")
        }
    }
}

#if os(tvOS)
/// The warning at the top of the Downloads page on Apple TV: what can go wrong, in plain words.
struct ExperimentalNotice: View {
    let isPermanent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Experimental", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            Text("Downloads on Apple TV are still being tested. Please read this before you rely on them, especially before a trip.")
                .font(.callout.weight(.semibold))

            ForEach(ExperimentalDownloads.limitations(isPermanent: isPermanent), id: \.self) { line in
                Label {
                    Text(line)
                } icon: {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 8))
                        .padding(.top, 8)
                }
                .font(.callout)
            }
        }
        .padding(.vertical, 8)
        // So the remote can land here and scroll the list, instead of skipping past text that can't be focused.
        .focusable()
        .accessibilityElement(children: .combine)
    }
}
#endif

/// The Downloads page's "more" menu: pause or resume everything, or delete it all.
struct ManageDownloadsMenu: View, Equatable {
    let hasUnfinished: Bool
    @Binding var confirmsDeleteAll: Bool

    @Environment(AppModel.self) private var appModel

    /// Compares what the menu shows, not the binding, so a redraw of the page that changes neither leaves it alone.
    static func == (lhs: ManageDownloadsMenu, rhs: ManageDownloadsMenu) -> Bool {
        lhs.hasUnfinished == rhs.hasUnfinished
    }

    var body: some View {
        let downloads = appModel.downloads
        Menu {
            if hasUnfinished {
                Button("Pause All", systemImage: "pause.circle") { downloads.pause() }
                Button("Resume All", systemImage: "play.circle") { downloads.resume() }
            }
            Button("Delete All Downloads", systemImage: "trash", role: .destructive) { confirmsDeleteAll = true }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        #if os(tvOS)
        .buttonBorderShape(.circle)
        #endif
        .accessibilityLabel("Manage Downloads")
    }
}
