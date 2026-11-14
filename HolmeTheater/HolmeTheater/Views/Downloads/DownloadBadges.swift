// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

// The marks that show a download on artwork and in list rows, and the small row-button helpers the Downloads page uses.

/// The blue arrow in the corner of downloaded artwork, beside the watched checkmark. For a show or season, it means every
/// episode is downloaded.
struct DownloadedBadge: View {
    let item: MediaItem

    /// Nil in previews that don't provide one, which then show no badge.
    @Environment(DownloadManager.self) private var downloads: DownloadManager?

    var body: some View {
        if downloads?.isDownloaded(item) == true {
            Image(systemName: "arrow.down.circle.fill")
                // The same size as the watched badge, which shares the artwork's corner.
                .font(WatchedBadge.font)
                // It sits on artwork that doesn't grow with the text, like the watched badge.
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .foregroundStyle(.white, .blue)
                .artworkOverlayEdge()
                .padding(6)
                .accessibilityLabel("Downloaded")
        }
    }
}

/// A small download mark for list rows, which have no artwork corner to put the badge in.
struct DownloadedRowIcon: View {
    let item: MediaItem

    @Environment(DownloadManager.self) private var downloads: DownloadManager?

    var body: some View {
        if downloads?.isDownloaded(item) == true {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.blue)
                .accessibilityLabel("Downloaded")
        }
    }
}

/// How wide the artwork in a download's row is: a widescreen still, or a poster in the same space. Bigger on Apple TV, which is
/// seen from across a room.
enum DownloadRowArt {
    #if os(tvOS)
    static let still: CGFloat = 176
    #else
    static let still: CGFloat = 86
    #endif
    static var poster: CGFloat { still / 2 }
}

extension View {
    /// The pause, resume and retry buttons at the end of a download's row: on Apple TV a round button, which lights up as a
    /// circle when focused (the borderless style puts a square behind its icon); elsewhere the plain borderless button.
    @ViewBuilder
    func roundRowButton() -> some View {
        #if os(tvOS)
        buttonStyle(.bordered)
            .buttonBorderShape(.circle)
        #else
        buttonStyle(.borderless)
        #endif
    }

    /// Deletes something from a list row: by swiping it on iPhone and iPad, or from its long-press menu on Apple TV, which
    /// has no swiping.
    @ViewBuilder
    func deleteAction(_ title: LocalizedStringKey = "Delete", systemImage: String = "trash", perform: @escaping () -> Void) -> some View {
        #if os(tvOS)
        contextMenu {
            Button(title, systemImage: systemImage, role: .destructive, action: perform)
        }
        #else
        swipeActions {
            Button(role: .destructive, action: perform) {
                Label(title, systemImage: systemImage)
            }
        }
        #endif
    }
}
