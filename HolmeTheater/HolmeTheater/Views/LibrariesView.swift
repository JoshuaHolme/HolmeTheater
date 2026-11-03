// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
#if os(tvOS)
import GameController
#endif

/// List of the user's libraries; tapping one opens its poster grid.
struct LibrariesView: View {
    @Environment(AppModel.self) private var appModel

    private var cardMinimumWidth: CGFloat {
        #if os(tvOS)
        return 560
        #else
        return 320
        #endif
    }

    var body: some View {
        AsyncContent(load: { try await appModel.service.libraries() }, offersDownloads: true) { libraries in
            ScrollView {
                // As many columns as fit, so a wide screen shows several cards across instead of stretching one.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: cardMinimumWidth), spacing: Layout.cardSpacing)], spacing: Layout.cardSpacing) {
                    ForEach(libraries) { library in
                        NavigationLink(value: library) {
                            CollageCard(title: library.name, systemImage: library.systemImage, cacheKey: "\(appModel.cacheScope)|library-\(library.id)") {
                                await posterURLs(for: library)
                            }
                        }
                        .cardLinkStyle()
                    }
                }
                .padding()
            }
        }
        .navigationTitle("Libraries")
    }

    /// A handful of the library's newest posters for its card.
    private func posterURLs(for library: Library) async -> [URL] {
        var urls = (try? await appModel.service.recentlyAddedItems(in: library))?.compactMap(\.posterURL) ?? []

        // Some libraries, such as collections, have nothing "recently added" to show, but still list items.
        if urls.isEmpty, let items = try? await appModel.service.items(in: library) {
            urls = items.prefix(16).compactMap(\.posterURL)
        }
        return urls
    }
}

/// A wide "poster" for a library or genre: its name over a collage of its artwork, tilted up to the right.
struct CollageCard: View {
    let title: String

    /// An SF Symbol to show beside the title, if any.
    var systemImage: String?

    /// Width divided by height for a tall poster-shaped card, or `nil` for a wide card of fixed height.
    var aspectRatio: CGFloat?

    /// Identifies the card's artwork in ``PosterURLCache``, so scrolling it away and back doesn't fetch it again. Include
    /// ``AppModel/cacheScope``, so another account or server never gets this one's artwork.
    let cacheKey: String

    /// Fetches the artwork for the collage. Runs once, the first time the card appears.
    let loadPosterURLs: () async -> [URL]

    /// Poster artwork for the collage, loaded after the card appears.
    @State private var posterURLs: [URL]

    init(
        title: String,
        systemImage: String? = nil,
        aspectRatio: CGFloat? = nil,
        cacheKey: String,
        loadPosterURLs: @escaping () async -> [URL]
    ) {
        self.title = title
        self.systemImage = systemImage
        self.aspectRatio = aspectRatio
        self.cacheKey = cacheKey
        self.loadPosterURLs = loadPosterURLs
        // Lazy grids discard cards that scroll away, so start from what an earlier copy of this card loaded.
        _posterURLs = State(initialValue: PosterURLCache.urls[cacheKey] ?? [])
    }

    #if os(tvOS)
    @Environment(\.isFocused) private var isFocused

    /// Where the thumb is on the remote's touch surface while this card is focused, from -1 to 1 on each axis.
    /// Only read while focused, so cards that aren't focused don't update as the thumb moves.
    private var thumb: CGSize {
        isFocused ? CGSize(width: RemoteThumb.shared.x, height: RemoteThumb.shared.y) : .zero
    }
    /// Whether this card has asked ``RemoteThumb`` to listen, so it hands the remote back exactly once.
    @State private var usesThumb = false

    private func setUsesThumb(_ wanted: Bool) {
        guard wanted != usesThumb else { return }
        usesThumb = wanted
        if wanted { RemoteThumb.shared.start() } else { RemoteThumb.shared.stop() }
    }
    #else
    private let thumb = CGSize.zero
    #endif

    private var height: CGFloat {
        #if os(tvOS)
        return 280
        #else
        return 150
        #endif
    }

    var body: some View {
        Color.secondary.opacity(0.2)
            .frame(maxWidth: .infinity)
            .modifier(CardShape(aspectRatio: aspectRatio, height: height))
            .overlay {
                // The artwork is the back layer: it drifts against the thumb, a little.
                GeometryReader { geometry in
                    LibraryCollage(urls: posterURLs, size: geometry.size)
                }
                .offset(x: -thumb.width * 10, y: thumb.height * 10)
                .allowsHitTesting(false)
            }
            // Darkens the edge the name sits on so it stays readable over the artwork.
            .overlay {
                LinearGradient(
                    colors: [.black.opacity(0.85), .black.opacity(0.5), .clear],
                    startPoint: aspectRatio == nil ? .leading : .bottom,
                    endPoint: aspectRatio == nil ? .trailing : .center
                )
            }
            .overlay(alignment: aspectRatio == nil ? .leading : .bottomLeading) {
                titleView
                    .font(.title2.weight(.bold))
                    // A long name wraps onto a second line on a tall card, and otherwise shrinks, rather than breaking
                    // mid-word or being cut off.
                    .lineLimit(aspectRatio == nil ? 1 : 2)
                    .multilineTextAlignment(.leading)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(.white)
                    .padding(20)
                    // The name is the front layer: it moves with the thumb, further than the artwork, so the posters
                    // underneath peek out from behind it.
                    .offset(x: thumb.width * 18, y: -thumb.height * 18)
            }
            .animation(.smooth(duration: 0.12), value: thumb)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.primary.opacity(0.15), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16))
            #if os(tvOS)
            // Lifts and tilts the whole card under the system's focus effect.
            .hoverEffect(.highlight)
            .onChange(of: isFocused) { _, focused in
                setUsesThumb(focused)
            }
            // Scrolled away or the screen left while focused: it no longer needs the remote.
            .onDisappear { setUsesThumb(false) }
            #endif
            .task { await loadPosters() }
    }

    @ViewBuilder
    private var titleView: some View {
        if let systemImage {
            Label(title, systemImage: systemImage)
        } else {
            Text(title)
        }
    }

    private func loadPosters() async {
        guard posterURLs.isEmpty else { return }
        let urls = await loadPosterURLs()
        guard !Task.isCancelled else { return }
        PosterURLCache.urls[cacheKey] = urls
        // Make sure the images are on disk, so a card that comes back doesn't go to the network.
        ImageCache.shared.prefetch(urls)
        posterURLs = urls
    }
}

/// The artwork each ``CollageCard`` has loaded, which outlives the card itself.
@MainActor
private enum PosterURLCache {
    static var urls: [String: [URL]] = [:]
}

/// Sizes a card either to a fixed height, or to a poster-shaped aspect ratio.
private struct CardShape: ViewModifier {
    let aspectRatio: CGFloat?
    let height: CGFloat

    func body(content: Content) -> some View {
        if let aspectRatio {
            content.aspectRatio(aspectRatio, contentMode: .fit)
        } else {
            content.frame(height: height)
        }
    }
}

#if os(tvOS)
/// Follows the thumb on the Siri Remote's touch surface, so views can move in layers as it slides around.
@MainActor @Observable
private final class RemoteThumb {
    static let shared = RemoteThumb()

    /// The thumb's position, from -1 to 1 on each axis, and 0 when it's lifted.
    private(set) var x: CGFloat = 0
    private(set) var y: CGFloat = 0

    /// How many cards want the thumb. Focus moving from one card to the next can start the new one before stopping the
    /// old one, so the remote is only handed back when none do.
    private var users = 0

    /// Starts listening to the remote, for a card that's just been focused. Each call needs a matching ``stop()``.
    func start() {
        users += 1
        // Every call installs the same handler, so a remote that connected since the last call gets it too.
        for pad in GCController.controllers().compactMap(\.microGamepad) {
            pad.reportsAbsoluteDpadValues = true
            pad.dpad.valueChangedHandler = { _, x, y in
                Task { @MainActor in
                    RemoteThumb.shared.x = CGFloat(x)
                    RemoteThumb.shared.y = CGFloat(y)
                }
            }
        }
    }

    /// Stops listening, for a card that's lost focus. Once no card is listening, the remote goes back to how the
    /// system had it, so nothing else in the app inherits absolute thumb positions or this handler.
    func stop() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        for pad in GCController.controllers().compactMap(\.microGamepad) {
            pad.dpad.valueChangedHandler = nil
            pad.reportsAbsoluteDpadValues = false
        }
        x = 0
        y = 0
    }
}
#endif

/// Vertical posters in staggered rows, tilted so they lean to the right. Bigger than the card it sits in, so the
/// rotated edges are never visible; the card clips it.
///
/// With only a few posters they're shown bigger, and each extra poster makes them smaller, until they settle at the
/// size the busiest libraries have. Posters repeat when there aren't enough to cover the card.
private struct LibraryCollage: View {
    let urls: [URL]
    let size: CGSize

    private let spacing: CGFloat = 8
    private let tilt = 30.0

    var body: some View {
        let count = urls.count
        // Nothing to lay out until the artwork is known. Showing a guess first would visibly rearrange itself.
        if count == 0 {
            Color.clear
        } else {
            collage(count: count)
        }
    }

    @ViewBuilder
    private func collage(count: Int) -> some View {
        let radians = tilt * .pi / 180

        // How much room the rotated card takes up, to know how many posters are needed to cover it.
        let coverWidth = size.width * cos(radians) + size.height * sin(radians)
        let coverHeight = size.width * sin(radians) + size.height * cos(radians)

        // A lone poster is a single piece big enough to cover the card on its own, with no seams or repeats.
        let isSingle = count == 1

        // The size a poster has once there are plenty; a few posters are bigger than this.
        let standardHeight = size.height * 0.62
        let fillWidth = isSingle ? coverWidth : size.width / CGFloat(count)
        let posterHeight = max(standardHeight, fillWidth * 1.5)
        let posterWidth = posterHeight * 2 / 3

        let columns = isSingle ? 1 : min(12, Int(ceil(coverWidth / (posterWidth + spacing))) + 3)
        let rows = isSingle ? 1 : min(8, Int(ceil(coverHeight / (posterHeight + spacing))) + 2)

        VStack(spacing: spacing) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: spacing) {
                    ForEach(0..<columns, id: \.self) { column in
                        ArtworkView(url: url(row: row, column: column), aspectRatio: 2.0 / 3.0)
                            .frame(width: posterWidth, height: posterHeight)
                    }
                }
                // Alternate rows are shifted half a poster, like bricks, split either side of center so the
                // collage stays centered and covers both edges of the card.
                .offset(x: isSingle ? 0 : (row.isMultiple(of: 2) ? -posterWidth / 4 : posterWidth / 4))
            }
        }
        // Clockwise, so the posters lean to the right.
        .rotationEffect(.degrees(tilt))
        .fixedSize()
        .frame(width: size.width, height: size.height)
    }

    /// The poster for a slot, repeating the available artwork if the library has fewer items than slots.
    private func url(row: Int, column: Int) -> URL? {
        guard !urls.isEmpty else { return nil }
        return urls[(row * 3 + column) % urls.count]
    }
}

/// Every item in one library, as a poster grid.
struct LibraryView: View {
    let library: Library
    @Environment(AppModel.self) private var appModel

    var body: some View {
        AsyncContent(load: loadItems) { items in
            PosterBrowser(items: items)
        }
        .navigationTitle(library.name)
    }

    /// Fetches the library and starts caching its posters in the background.
    private func loadItems() async throws -> [MediaItem] {
        let items = try await appModel.service.items(in: library)

        // The first screen's posters load before the grid shows, so they don't pop in. The next few screens' worth
        // download in the background; a huge library shouldn't flood the network and memory. Posters further down
        // still load as you scroll, and are then cached for next time.
        ImageCache.shared.prefetch(items.dropFirst(18).prefix(42).compactMap(\.posterURL))
        await ImageCache.shared.preload(items.prefix(18).compactMap(\.posterURL))
        return items
    }
}

private extension Library {
    /// The SF Symbol shown beside the library in lists.
    var systemImage: String {
        switch kind {
        case .movies: "film"
        case .tvShows: "tv"
        case .music: "music.note"
        case .other: "folder"
        }
    }
}

#Preview("Libraries") {
    NavigationStack {
        LibrariesView()
            .mediaNavigationDestinations()
    }
    .environment(AppModel.preview())
}

#Preview("Library") {
    NavigationStack {
        LibraryView(library: .previewMovies)
            .mediaNavigationDestinations()
    }
    .environment(AppModel.preview())
}
