// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

// Small reusable pieces shared by the browsing screens.

/// Shared layout constants.
enum Layout {
    /// Width of a poster in shelves; larger on tvOS for the "ten-foot" UI.
    static var posterWidth: CGFloat {
        #if os(tvOS)
        return 220
        #else
        return 130
        #endif
    }
}

extension MediaItem {
    /// Whether the item can be played directly (as opposed to being a container like a series).
    var isPlayable: Bool { kind == .movie || kind == .episode }

    /// e.g. "Show Name · S1E3" for episodes; nil for everything else.
    var subtitle: String? {
        guard kind == .episode else { return nil }
        var parts: [String] = []
        if let seriesTitle { parts.append(seriesTitle) }
        if let seasonNumber, let episodeNumber { parts.append("S\(seasonNumber)E\(episodeNumber)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// e.g. "2019 · 1h 52m"; nil if neither year nor runtime is known.
    var metadataLine: String? {
        var parts: [String] = []
        if let year { parts.append(String(year)) }
        if let runtime {
            parts.append(Duration.seconds(runtime).formatted(.units(allowed: [.hours, .minutes], width: .narrow)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension View {
    /// Registers navigation for media items and libraries; apply to the root of each NavigationStack.
    func mediaNavigationDestinations() -> some View {
        navigationDestination(for: MediaItem.self) { ItemDetailView(item: $0) }
            .navigationDestination(for: Library.self) { LibraryView(library: $0) }
            .navigationDestination(for: ShelfDestination.self) { ShelfListView(destination: $0) }
    }

    /// Link style that keeps cards looking like cards (and focusable on tvOS).
    @ViewBuilder
    func cardLinkStyle() -> some View {
        #if os(tvOS)
        buttonStyle(.borderless)
        #else
        buttonStyle(.plain)
        #endif
    }
}

/// Remote image with a placeholder, cropped to a fixed aspect ratio.
struct ArtworkView: View {
    /// The image to load. A nil URL shows the placeholder.
    let url: URL?

    /// Width divided by height, e.g. `2.0 / 3.0` for a poster.
    let aspectRatio: CGFloat

    var body: some View {
        Color.secondary.opacity(0.2)
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .empty where url != nil:
                        ProgressView()
                    default:
                        Image(systemName: "film")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// A poster with a progress bar (if partly watched), a watched checkmark, and the title beneath.
struct PosterCard: View {
    let item: MediaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(url: item.posterURL, aspectRatio: 2.0 / 3.0)
                .overlay(alignment: .bottom) {
                    if let fraction = item.playedFraction {
                        ProgressView(value: fraction)
                            .padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if item.isPlayed {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.white, .green)
                            .padding(6)
                    }
                }

            Text(item.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            if let subtitle = item.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// Horizontally scrolling row of posters under a heading. Each poster navigates to its item.
///
/// If a `destination` is given, the heading is a button (with a chevron) that opens the full list.
struct MediaShelf: View {
    let title: String
    let items: [MediaItem]

    /// Where tapping the heading leads. Nil makes the heading plain text.
    var destination: ShelfDestination?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading
                .padding(.horizontal)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(items) { item in
                        NavigationLink(value: item) {
                            PosterCard(item: item)
                                .frame(width: Layout.posterWidth)
                        }
                        .cardLinkStyle()
                    }
                }
                .padding(.horizontal)
            }
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private var heading: some View {
        if let destination {
            NavigationLink(value: destination) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.title2.bold())
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
    }
}

/// Compact list row: thumbnail plus title and details.
struct ItemRow: View {
    let item: MediaItem

    /// An episode's image is a widescreen still; everything else is a portrait poster.
    private var isEpisode: Bool { item.kind == .episode }

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: item.posterURL, aspectRatio: isEpisode ? 16.0 / 9.0 : 2.0 / 3.0)
                .frame(width: isEpisode ? 100 : 50)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .lineLimit(2)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let metadata = item.metadataLine {
                    Text(metadata)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if item.isPlayed {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }
}

#Preview("PosterCard") {
    HStack(alignment: .top) {
        PosterCard(item: .previewMovie)
        PosterCard(item: .previewPartlyWatched)
        PosterCard(item: .previewWatched)
        PosterCard(item: .previewEpisode)
    }
    .padding()
}

#Preview("MediaShelf") {
    NavigationStack {
        MediaShelf(title: "Continue Watching", items: MediaItem.previewMovies)
            .mediaNavigationDestinations()
    }
    .environment(AppModel.preview())
}

#Preview("ItemRow") {
    List(MediaItem.previewMovies + [.previewEpisode]) { ItemRow(item: $0) }
}

#Preview("ArtworkView") {
    ArtworkView(url: nil, aspectRatio: 16.0 / 9.0)
        .padding()
}
