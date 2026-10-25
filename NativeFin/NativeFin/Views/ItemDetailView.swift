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
    }

    /// Seasons (for a series) or episodes (for a season), each navigating to its own detail screen.
    private var children: some View {
        AsyncContent(load: { try await appModel.service.children(of: item) }) { children in
            VStack(alignment: .leading, spacing: 12) {
                Text(item.kind == .series ? "Seasons" : "Episodes")
                    .font(.title2.bold())

                ForEach(children) { child in
                    NavigationLink(value: child) {
                        ItemRow(item: child)
                    }
                    .cardLinkStyle()
                }
            }
        }
    }
}
