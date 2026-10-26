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

    /// A season change waiting for confirmation, or an error to show.
    @State private var watchState = WatchActionState()

    /// Bumped to reload the list of seasons or episodes after a change on the server.
    @State private var reloadCount = 0

    /// The item as the server last described it, fetched again after playback. Nil until then.
    @State private var refreshedItem: MediaItem?

    /// The latest copy of the item: its progress (and so Play or Resume) is up to date after playback.
    private var current: MediaItem { refreshedItem ?? item }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ArtworkView(url: current.backdropURL ?? current.posterURL, aspectRatio: 16.0 / 9.0)

                VStack(alignment: .leading, spacing: 12) {
                    Text(current.title)
                        .font(.largeTitle.bold())

                    if let subtitle = current.subtitle {
                        Text(subtitle)
                            .foregroundStyle(.secondary)
                    }
                    if let metadata = current.metadataLine {
                        Text(metadata)
                            .foregroundStyle(.secondary)
                    }

                    if current.isPlayable {
                        Button {
                            playingItem = current
                        } label: {
                            Label(current.playedFraction == nil ? "Play" : "Resume", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if let overview = current.overview {
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
        .fullScreenCover(item: $playingItem) {
            PlayerView(item: $0, onStop: { Task { await refresh() } })
        }
        .watchActionAlerts(watchActions)
    }

    /// Fetches the item again after playback, so the screen shows where the user got to. Keeps what's on
    /// screen if that fails; it's only out of date.
    private func refresh() async {
        guard let latest = try? await appModel.service.item(id: item.id) else { return }
        refreshedItem = latest
    }

    /// Reloads the seasons or episodes after a change, so their watched counts come from the server.
    private var watchActions: WatchActions {
        WatchActions(service: appModel.service, destination: nil, state: $watchState) { _ in
            reloadCount += 1
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
        return watchActions.actions(for: child)
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
