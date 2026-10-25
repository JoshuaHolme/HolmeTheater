// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Detail for any item. Movies and episodes get a Play button; series and seasons list their children.
struct ItemDetailView: View {
    let item: MediaItem
    @Environment(AppModel.self) private var appModel

    /// The item being played; setting it presents the full-screen player.
    @State private var playingItem: MediaItem?

    /// A season the user chose to mark watched or unwatched, waiting on their confirmation.
    @State private var pendingBulkChange: BulkWatchChange?

    /// Set when marking a season fails; shown in an alert.
    @State private var actionError: String?

    /// Bumped to reload the list of seasons or episodes after a change on the server.
    @State private var reloadCount = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ArtworkView(url: item.backdropURL ?? item.posterURL, aspectRatio: 16.0 / 9.0)

                VStack(alignment: .leading, spacing: 12) {
                    Text(item.title)
                        .font(.largeTitle.bold())

                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .foregroundStyle(.secondary)
                    }
                    if let metadata = item.metadataLine {
                        Text(metadata)
                            .foregroundStyle(.secondary)
                    }

                    if item.isPlayable {
                        Button {
                            playingItem = item
                        } label: {
                            Label(item.playedFraction == nil ? "Play" : "Resume", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if let overview = item.overview {
                        Text(overview)
                    }

                    if item.kind == .series || item.kind == .season {
                        children
                    }
                }
                .padding(.horizontal)
            }
        }
        .navigationTitle(item.title)
        .fullScreenCover(item: $playingItem) { PlayerView(item: $0) }
        .confirmBulkWatchChange($pendingBulkChange, perform: apply)
        .alert("Couldn't Update Item", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    /// Seasons (for a series) or episodes (for a season), each navigating to its own detail screen.
    private var children: some View {
        AsyncContent(load: { try await appModel.service.children(of: item) }, reloadID: reloadCount) { children in
            VStack(alignment: .leading, spacing: 12) {
                Text(item.kind == .series ? "Seasons" : "Episodes")
                    .font(.title2.bold())

                ForEach(children) { child in
                    ItemRow(item: child, actions: actions(for: child))
                        // A link behind the row, so the row's menu button takes its own taps.
                        .background {
                            NavigationLink(value: child) { Color.clear.contentShape(Rectangle()) }
                                .cardLinkStyle()
                        }
                }
            }
        }
    }

    /// The menu for a row: seasons can be marked watched or unwatched as a whole. Episodes have none here.
    private func actions(for child: MediaItem) -> ItemRowActions? {
        guard child.kind == .season else { return nil }
        return ItemRowActions(
            markWatched: { pendingBulkChange = BulkWatchChange(item: child, markWatched: true) },
            markUnwatched: { pendingBulkChange = BulkWatchChange(item: child, markWatched: false) }
        )
    }

    /// Marks every episode of a season watched or unwatched, once the user has confirmed, then reloads the list.
    private func apply(_ change: BulkWatchChange) {
        let service = appModel.service
        Task {
            do {
                if change.markWatched {
                    try await service.markWatched(change.item)
                } else {
                    try await service.markUnwatched(change.item)
                }
                reloadCount += 1
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

#Preview("Movie") {
    NavigationStack {
        ItemDetailView(item: .previewMovie)
            .mediaNavigationDestinations()
    }
    .environment(AppModel.preview())
}

#Preview("Partly Watched") {
    NavigationStack {
        ItemDetailView(item: .previewPartlyWatched)
            .mediaNavigationDestinations()
    }
    .environment(AppModel.preview())
}

#Preview("Series") {
    NavigationStack {
        ItemDetailView(item: .previewSeries)
            .mediaNavigationDestinations()
    }
    .environment(AppModel.preview())
}

#Preview("Episode") {
    NavigationStack {
        ItemDetailView(item: .previewEpisode)
            .mediaNavigationDestinations()
    }
    .environment(AppModel.preview())
}
