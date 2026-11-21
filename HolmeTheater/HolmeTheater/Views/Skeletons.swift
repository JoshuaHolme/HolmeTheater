// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

// Placeholders shown in place of content that's still loading, laid out like the content so it doesn't jump when it arrives.

/// A rounded block standing in for artwork or a line of text, with a light that sweeps across it. With Reduce Motion on,
/// it stays still.
struct SkeletonBlock: View {
    var cornerRadius: CGFloat = SkeletonBlock.artworkCornerRadius

    /// The corner radius `ArtworkView` uses, so a placeholder card has the same outline as the card that replaces it.
    static var artworkCornerRadius: CGFloat {
        #if os(tvOS)
        return 12
        #else
        return 8
        #endif
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweeping = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        shape
            .fill(Color.secondary.opacity(0.2))
            .overlay {
                if !reduceMotion {
                    GeometryReader { proxy in
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.18), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: proxy.size.width * 0.6)
                        // From just off the leading edge to just past the trailing one.
                        .offset(x: sweeping ? proxy.size.width : -proxy.size.width * 0.6)
                    }
                }
            }
            .clipShape(shape)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { sweeping = true }
            }
    }
}

/// Artwork with two lines of caption beneath, filling the width it's given.
private struct SkeletonTile: View {
    let aspectRatio: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.captionGap) {
            SkeletonBlock()
                .aspectRatio(aspectRatio, contentMode: .fit)
            SkeletonBlock(cornerRadius: 4)
                .frame(height: 12)
            SkeletonBlock(cornerRadius: 4)
                .frame(height: 10)
                .padding(.trailing, 32)
        }
    }
}

/// A poster or widescreen card, with its artwork and two lines of caption.
struct SkeletonCard: View {
    var isWide = false

    var body: some View {
        SkeletonTile(aspectRatio: isWide ? 16 / 9 : 2 / 3)
            .cardWidth(isWide ? Layout.wideCardWidth : Layout.posterWidth)
    }
}

/// A grid of cards, in the columns the grid it stands in for has.
struct SkeletonTileGrid: View {
    let columns: [GridItem]
    var aspectRatio: CGFloat = 2.0 / 3.0
    var count = 12

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Layout.cardSpacing) {
            ForEach(0..<count, id: \.self) { _ in
                SkeletonTile(aspectRatio: aspectRatio)
            }
        }
    }
}

/// Holds placeholders that fill a screen, in a scroll view that doesn't scroll, as the screen they stand in for does.
struct SkeletonScroll<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView { content }
            .scrollDisabled(true)
            .scrollIndicators(.hidden)
    }
}

/// A screen of posters, as a library's or a genre's page is.
struct SkeletonPosterGrid: View {
    var body: some View {
        SkeletonScroll {
            SkeletonTileGrid(columns: [GridItem(.adaptive(minimum: Layout.posterWidth), spacing: Layout.cardSpacing, alignment: .top)], count: 18)
                .padding()
        }
    }
}

/// A row of a list: a picture and two lines of text.
struct SkeletonRow: View {
    var aspectRatio: CGFloat = 2.0 / 3.0

    private var thumbnailWidth: CGFloat {
        #if os(tvOS)
        return 120
        #else
        return 56
        #endif
    }

    var body: some View {
        HStack(spacing: 12) {
            SkeletonBlock()
                .aspectRatio(aspectRatio, contentMode: .fit)
                .frame(width: thumbnailWidth)
            VStack(alignment: .leading, spacing: 8) {
                SkeletonBlock(cornerRadius: 4)
                    .frame(height: 14)
                SkeletonBlock(cornerRadius: 4)
                    .frame(height: 12)
                    .padding(.trailing, 60)
            }
        }
        .padding(.vertical, 6)
    }
}

/// A list of rows.
struct SkeletonRows: View {
    var count = 8
    var aspectRatio: CGFloat = 2.0 / 3.0

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { _ in
                SkeletonRow(aspectRatio: aspectRatio)
            }
        }
    }
}

/// Lines of text, for where a list's rows are loading.
struct SkeletonLines: View {
    var count = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(0..<count, id: \.self) { _ in
                SkeletonBlock(cornerRadius: 4)
                    .frame(height: 16)
            }
        }
        .padding(.vertical, 6)
    }
}

/// A shelf's heading and a row of cards.
struct SkeletonShelf: View {
    var isWide = false
    var cardCount = 6

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.shelfHeadingGap) {
            SkeletonBlock(cornerRadius: 4)
                .frame(width: 160, height: 20)
                .padding(.horizontal, Layout.contentInset)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: Layout.cardSpacing) {
                    ForEach(0..<cardCount, id: \.self) { _ in
                        SkeletonCard(isWide: isWide)
                    }
                }
                .padding(.horizontal, Layout.contentInset)
            }
            .scrollDisabled(true)
            .scrollIndicators(.hidden)
        }
    }
}

/// The Home screen while it loads: the carousel's place, then a few shelves.
struct HomeSkeleton: View {
    /// The carousel's height, where the screen shows one: its place is a block that fills the width and runs up under the
    /// status bar, as the carousel does. Nil where there's none, and the screen's heading sits above the shelves.
    var heroHeight: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.shelfSpacing) {
            #if os(tvOS)
            // The carousel fills the top of the screen on tvOS; the shelves sit below where it ends.
            Color.clear.frame(height: 480)
            #else
            if let heroHeight {
                SkeletonBlock(cornerRadius: 0)
                    .frame(height: heroHeight)
            }
            #endif
            SkeletonShelf(isWide: true, cardCount: 4)
            SkeletonShelf()
            SkeletonShelf()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

#Preview("Home skeleton") {
    ScrollView { HomeSkeleton() }
}
