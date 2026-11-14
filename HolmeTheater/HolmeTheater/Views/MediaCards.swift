// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Remote image with a placeholder, cropped to a fixed aspect ratio.
struct ArtworkView: View {
    /// The image to load. A nil URL shows the placeholder.
    let url: URL?

    /// Width divided by height, e.g. `2.0 / 3.0` for a poster.
    let aspectRatio: CGFloat

    #if os(tvOS)
    private static let cornerRadius: CGFloat = 12
    #else
    private static let cornerRadius: CGFloat = 8
    #endif

    var body: some View {
        Color.secondary.opacity(0.2)
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay {
                CachedAsyncImage(url: url) { phase in
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
                // The image is purely visual. A fill-scaled image overflows its frame (a widescreen
                // episode still in a portrait slot, say). Clipping hides the overflow but doesn't stop
                // it receiving taps, so without this it would steal taps from neighboring cards.
                .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
            // A faint outline gives artwork whose background matches the screen's (white or black) an edge.
            // It's inset, and the primary color flips with light and dark mode, so it stays subtle on artwork
            // that already stands out.
            .overlay {
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .strokeBorder(.primary.opacity(0.15), lineWidth: 1)
            }
    }
}

/// The text beneath an item's artwork: its first caption line as a title, then the rest as detail lines.
/// See `MediaItem.captionLines` for what each kind of item shows.
struct ItemCaption: View {
    let item: MediaItem

    /// Pads with blank lines up to this many, so cards of different kinds in one row are the same height.
    /// Without it, the row's tallest card squeezes the artwork of the shorter ones.
    var reservedLines = 0

    /// Lines to show instead of the item's usual caption.
    var lines: [String]?

    /// How many lines the title gets before it's cut off, where a title is worth the room. Nil for the usual one.
    var titleLineLimit: Int?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let lines = lines ?? item.captionLines

        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                Text(line)
                    .font(index == 0 ? .subheadline.weight(.medium) : .caption)
                    .foregroundStyle(index == 0 ? .primary : .secondary)
                    // Cards are a fixed width, so at accessibility sizes a one-line title would be cut to a few letters.
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : (index == 0 ? titleLineLimit ?? 1 : 1))
            }

            ForEach(lines.count..<max(lines.count, reservedLines), id: \.self) { _ in
                Text(" ")
                    .font(.caption)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// The green checkmark in the corner of watched artwork.
struct WatchedBadge: View {
    /// The badge's size, which the download badge shares.
    static var font: Font {
        #if os(tvOS)
        // `.title` is 76 points here, which on a 260-point poster is a badge a third of its width. This is closer to the
        // Apple TV app's.
        .system(size: 36)
        #else
        // Large enough to spot at a glance on a busy poster.
        .title
        #endif
    }

    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(Self.font)
            // It sits on artwork that doesn't grow with the text (a 130pt poster), so at accessibility sizes it
            // would cover most of the poster.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .foregroundStyle(.white, .green)
            .artworkOverlayEdge()
            .padding(6)
            .accessibilityLabel("Watched")
    }
}

#if os(tvOS)
/// The strip along the bottom of a widescreen card's picture, over a fade so it reads on any picture. From the top: the
/// show's logo (or its name, if it has no logo), a play icon with what's left or how long it is (e.g. "S4, E4 · 33m"), and,
/// if it's partly watched, a bar for how far through it is, which has a line of its own so it never crowds the text.
private struct WideCardStatus: View {
    let item: MediaItem

    /// The widest and tallest a logo gets.
    private static let logoMaxSize = CGSize(width: 170, height: 52)

    /// About how much room a logo takes up, whatever its shape. See ``NormalizedLogoLayout``.
    private static let logoArea: CGFloat = 4800

    /// The show an episode belongs to, or the title of anything else (a movie is its own "show").
    private var showName: String {
        item.kind == .episode ? (item.seriesTitle ?? item.title) : item.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            showTitle

            if item.gridStatusLine != nil || item.playedFraction != nil {
                HStack(spacing: 10) {
                    Image(systemName: "play.fill")
                        .accessibilityHidden(true)

                    if let status = item.gridStatusLine {
                        Text(status)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                .font(.caption.weight(.semibold))
            }

            if let fraction = item.playedFraction {
                Capsule()
                    .fill(.white.opacity(0.3))
                    .frame(height: 4)
                    .overlay(alignment: .leading) {
                        GeometryReader { proxy in
                            Capsule()
                                .fill(.white)
                                .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                        }
                    }
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .padding(.top, 36)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom))
        // Square at the top, rounded at the bottom to follow the picture's corners.
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12))
        // Reruns when the card is reused for another item.
        .task(id: item.logoURL) { await loadLogo() }
    }

    /// Where the logo has got to: loading, ready with its empty margin cut off, or not there to show.
    private enum LogoPhase {
        case loading
        case ready(UIImage)
        case unavailable
    }

    @State private var logo: LogoPhase

    init(item: MediaItem) {
        self.item = item
        // From what's already been trimmed, so a card scrolled back into view has its logo on the first frame.
        if let url = item.logoURL {
            if let trimmed = LogoTrimmer.cachedImage(for: url) {
                _logo = State(initialValue: .ready(trimmed))
            } else {
                _logo = State(initialValue: .loading)
            }
        } else {
            _logo = State(initialValue: .unavailable)
        }
    }

    private func loadLogo() async {
        guard let url = item.logoURL else {
            logo = .unavailable
            return
        }
        if let trimmed = LogoTrimmer.cachedImage(for: url) {
            logo = .ready(trimmed)
            return
        }
        logo = .loading
        let trimmed = await LogoTrimmer.trimmedImage(for: url)
        guard !Task.isCancelled else { return }
        logo = trimmed.map { .ready($0) } ?? .unavailable
    }

    /// The show's logo, or its name typed out if it has no logo or the logo can't load.
    @ViewBuilder
    private var showTitle: some View {
        switch logo {
        case .ready(let image):
            // Sized by its shape, so a wide wordmark and a squarer badge look about as big as each other.
            NormalizedLogoLayout(area: Self.logoArea, maxSize: Self.logoMaxSize) {
                Image(uiImage: image).resizable()
            }
            .shadow(color: .black.opacity(0.5), radius: 4)
            .accessibilityLabel(showName)
        case .loading:
            // Holds the logo's room while it loads, rather than flashing the name first.
            Color.clear.frame(height: Self.logoMaxSize.height)
        case .unavailable:
            nameText
        }
    }

    private var nameText: some View {
        Text(showName)
            // The same size as the line under it, but bolder, so it leads without outsizing the logos beside it.
            .font(.caption.weight(.bold))
            .lineLimit(1)
            .shadow(color: .black.opacity(0.5), radius: 4)
    }
}

/// Loads a logo and cuts off the empty (transparent) margin around its artwork, so a logo drawn small in a big canvas isn't
/// sized by the canvas and left looking tiny beside the others. Done once per logo and kept.
private nonisolated enum LogoTrimmer {
    /// Pixels fainter than this (of 255) count as empty, so a barely there glow doesn't keep a margin.
    private static let emptyBelow: UInt8 = 24

    private static let cache = SharedCache<NSURL, UIImage>()

    /// The trimmed logo, if it's been made before.
    static func cachedImage(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    /// The logo at `url` with its empty margin cut off, or nil if it can't be loaded.
    static func trimmedImage(for url: URL) async -> UIImage? {
        if let cached = cachedImage(for: url) { return cached }
        guard let image = await ImageCache.shared.image(for: url) else { return nil }
        // Off the main thread: it looks at every pixel.
        let trimmed = await Task.detached(priority: .userInitiated) { trimmed(image) }.value
        cache.setObject(trimmed, forKey: url as NSURL)
        return trimmed
    }

    /// `image` cut down to the smallest rectangle that holds everything that isn't empty, or `image` itself if there's
    /// nothing to cut (no margin, no transparency, or nothing visible at all).
    private static func trimmed(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let width = cgImage.width, height = cgImage.height
        guard width > 0, height > 0 else { return image }

        // The picture as four bytes a pixel (red, green, blue, alpha), of which only the alpha is read. Row 0 is the top.
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return image }

        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where pixels[(row + x) * 4 + 3] >= emptyBelow {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        // Nothing visible: leave it alone rather than cut it to nothing.
        guard maxX >= minX, maxY >= minY else { return image }

        let box = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        // Hardly any margin: not worth a copy.
        guard box.width < CGFloat(width) * 0.97 || box.height < CGFloat(height) * 0.97,
              let cropped = cgImage.cropping(to: box) else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }
}

/// Sizes its one image so every logo takes up about the same room, whatever its shape. Fitting each into the same box
/// leaves wide wordmarks short (they run out of width first) and squarer badges narrow (they run out of height first), so
/// some look several times the size of others. Here the image's shape sets its size: a given area, so a wide logo comes out
/// short and a squarer one taller, up to a limit on each side.
///
/// It goes by the image it's given, so that should be trimmed of empty margin first (see ``LogoTrimmer``).
private struct NormalizedLogoLayout: SwiftUI.Layout {
    /// The room the logo takes up, in points squared, when neither limit applies.
    let area: CGFloat

    /// The widest and tallest it gets.
    let maxSize: CGSize

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        fittedSize(of: subviews)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let size = fittedSize(of: subviews)
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(size))
    }

    private func fittedSize(of subviews: Subviews) -> CGSize {
        // Asked for no particular size, an image says how big it is.
        guard let natural = subviews.first?.sizeThatFits(.unspecified), natural.width > 0, natural.height > 0 else { return .zero }
        let ratio = natural.width / natural.height
        var height = (area / ratio).squareRoot()
        var width = height * ratio
        if width > maxSize.width {
            width = maxSize.width
            height = width / ratio
        }
        if height > maxSize.height {
            height = maxSize.height
            width = height * ratio
        }
        return CGSize(width: width, height: height)
    }
}
#endif

/// A widescreen card: the item's still with a progress bar (if partly watched) and a watched checkmark, and its
/// caption beneath.
struct WideCard: View {
    let item: MediaItem

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.captionGap) {
            ArtworkView(url: item.gridArtworkURL, aspectRatio: 16.0 / 9.0)
                .overlay(alignment: .bottom) {
                    #if os(tvOS)
                    // The play icon, progress and time left over the picture, as in the Apple TV app.
                    WideCardStatus(item: item)
                    #else
                    if let fraction = item.playedFraction {
                        ProgressView(value: fraction)
                            .artworkOverlayEdge()
                            .padding(6)
                    }
                    #endif
                }
                .overlay(alignment: .topTrailing) {
                    if item.showsWatchedBadge {
                        WatchedBadge()
                    }
                }
                .overlay(alignment: .topLeading) { DownloadedBadge(item: item) }
                .focusHighlight()

            // An episode's show is the screen it's on, so it shows only its own title and number. The most lines
            // an extra shows is three (title, kind, length); reserving them keeps the cards the same height.
            ItemCaption(
                item: item,
                reservedLines: item.kind == .episode ? 2 : 3,
                lines: item.kind == .episode ? [item.title, item.episodeAirLine].compactMap { $0 } : nil
            )
        }
        .contentShape(Rectangle())
    }
}

#if os(tvOS)
/// How far through an item you are, as a bar along the bottom of its poster. Drawn here rather than by the system's
/// progress view, which sat against the poster's corner (where its rounded edge clipped it) when the card was focused. This
/// is inset the same way focused or not, and is in the theme's color (the app's tint) on a faint track.
private struct PosterProgressBar: View {
    let fraction: Double

    var body: some View {
        Capsule()
            .fill(.white.opacity(0.35))
            .frame(height: 6)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(.tint)
                        .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                }
            }
            .artworkOverlayEdge()
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .accessibilityHidden(true)
    }
}
#endif

/// A poster with a progress bar (if partly watched), a watched checkmark, and the item's caption beneath.
struct PosterCard: View {
    let item: MediaItem

    /// How many lines the title gets before it's cut off.
    var titleLineLimit: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.captionGap) {
            ArtworkView(url: item.posterURL, aspectRatio: 2.0 / 3.0)
                .overlay(alignment: .bottom) {
                    if let fraction = item.playedFraction {
                        #if os(tvOS)
                        PosterProgressBar(fraction: fraction)
                        #else
                        ProgressView(value: fraction)
                            .artworkOverlayEdge()
                            .padding(6)
                        #endif
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if item.showsWatchedBadge {
                        WatchedBadge()
                    }
                }
                .overlay(alignment: .topLeading) { DownloadedBadge(item: item) }
                .focusHighlight()

            // Three lines is the most any item shows (an episode); reserving them keeps every card the same height.
            ItemCaption(item: item, reservedLines: 3, titleLineLimit: titleLineLimit)
        }
        // Make the whole card tappable, including the gaps between the artwork and text.
        .contentShape(Rectangle())
    }
}

/// Reports a card's focus to a shelf's owner, if it gave somewhere to report it to.
struct CardFocusTracking: ViewModifier {
    let focus: FocusState<String?>.Binding?
    let key: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if let focus {
            content.focused(focus, equals: key)
        } else {
            content
        }
    }
}
