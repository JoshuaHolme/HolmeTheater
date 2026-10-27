// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Detail for any item. Movies, shows, seasons and episodes have their own screen, ``ShowDetailView``. A special
/// feature has none (it only plays), and anything else gets a simpler one.
struct ItemDetailView: View {
    let item: MediaItem

    var body: some View {
        if item.kind == .series || item.kind == .season || item.kind == .episode || item.kind == .movie {
            ShowDetailView(item: item)
        } else {
            StandardItemDetailView(item: item)
        }
    }
}

/// Detail for anything without a screen of its own, which isn't a special feature.
private struct StandardItemDetailView: View {
    let item: MediaItem
    @Environment(AppModel.self) private var appModel

    /// The item being played; setting it presents the full-screen player.
    @State private var playingItem: MediaItem?

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
                }
                .padding(.horizontal)
            }
        }
        .navigationTitle(item.title)
        .fullScreenCover(item: $playingItem) {
            PlayerView(item: $0, onStop: { Task { await refresh() } })
        }
    }

    /// Fetches the item again after playback, so the screen shows where the user got to. Keeps what's on
    /// screen if that fails; it's only out of date.
    private func refresh() async {
        guard let latest = try? await appModel.service.item(id: item.id) else { return }
        refreshedItem = latest
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
