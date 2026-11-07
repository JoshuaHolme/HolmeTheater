// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// The show's logo, or its name typed out if it has no logo (or the logo can't load).
struct ShowLogo: View {
    let item: MediaItem

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// What to type out instead of the item's own title, if there is no logo. Nil to use the title.
    var fallbackTitle: String?

    /// A cap to use instead of the usual one, for where the logo should be smaller (the Home carousel on tvOS).
    var maxSizeOverride: CGSize?

    private var maxSize: CGSize { maxSizeOverride ?? Self.defaultMaxSize }

    /// The largest the logo gets. Logos vary from wide wordmarks to near-square badges, so both are capped.
    private static var defaultMaxSize: CGSize {
        #if os(tvOS)
        return CGSize(width: 600, height: 220)
        #else
        return CGSize(width: 280, height: 110)
        #endif
    }

    var body: some View {
        if let url = item.logoURL {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: maxSize.width, maxHeight: maxSize.height, alignment: .bottomLeading)
                        .accessibilityLabel(item.title)
                        .accessibilityAddTraits(.isHeader)
                case .empty:
                    // Hold the logo's room while it loads, rather than flashing the name first.
                    Color.clear
                        .frame(width: maxSize.width, height: maxSize.height)
                default:
                    title
                }
            }
        } else {
            title
        }
    }

    private var title: some View {
        Text(fallbackTitle ?? item.title)
            .font(.largeTitle.bold())
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A description cut off at `lineLimit` lines. If it doesn't fit, its last line fades out into a MORE button.
struct TruncatingOverview: View {
    let text: String
    let lineLimit: Int

    /// The color of the text and of MORE. White over the show's artwork; the primary color elsewhere.
    var foreground: Color = .white

    /// Whether the remote can focus the description (on tvOS, where it's a button). A page turns it off while it moves
    /// focus to its Play button, so focus doesn't flash on the description on the way there.
    var isFocusable = true

    /// How the description looks on tvOS, where it's a button rather than text with a MORE button. The defaults are the
    /// usual body text; the show page uses the Home carousel's smaller, dimmer text and wider column.
    var tvFont: Font = .body
    var tvOpacity: Double = 0.75
    var tvMaxWidth: CGFloat = 900

    /// Called when MORE is tapped.
    let onMore: () -> Void

    /// The heights of the text as shown, of all of it at the same width, and of one line.
    @State private var shownHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0
    @State private var lineHeight: CGFloat = 0

    /// The width of the MORE button, which the last line leaves room for.
    @State private var moreWidth: CGFloat = 0

    /// How far the last line fades out before the MORE button.
    private static let fadeWidth: CGFloat = 32

    /// Whether the text needs more lines than it's allowed. Half a point of slack absorbs rounding.
    private var isTruncated: Bool { fullHeight > shownHeight + 0.5 }

    var body: some View {
        #if os(tvOS)
        if isTruncated {
            // The whole description is the button, as in the Apple TV app: selecting it shows all of it. The card style gives
            // it the system's focus platter, and the padding gives that platter room around the text. The negative padding
            // outside takes the room back, so the text sits where it does when it isn't a button.
            Button(action: onMore) {
                tvText.padding(Self.tvPlatterInset)
            }
            .buttonStyle(.card)
            .padding(-Self.tvPlatterInset)
            // Held off the remote while the page moves focus to its Play button.
            .disabled(!isFocusable)
            .accessibilityHint("Shows the full description")
        } else {
            // All of it fits, so there's nothing more to show and nothing to select.
            tvText
        }
        #else
        Text(text)
            .font(.callout)
            // Dimmer than the genre line above it, but brighter than the system's secondary gray, whose
            // transparency lets busy artwork show through, like the TV app's.
            .foregroundStyle(foreground.opacity(0.75))
            .lineLimit(lineLimit)
            // Full width, so the hidden copies below wrap at the same width as the text on screen.
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shownHeight = $0 }
            .background(alignment: .topLeading) { measurements }
            .mask {
                if isTruncated { truncationMask } else { Rectangle() }
            }
            .overlay(alignment: .bottomTrailing) {
                if isTruncated { moreButton }
            }
        #endif
    }

    #if os(tvOS)
    /// How far the focus platter reaches past the text.
    private static var tvPlatterInset: CGFloat { 20 }

    /// The description as text, cut off at `lineLimit` lines. If it's cut off, its last line fades out into MORE, which is a
    /// label here and not a button of its own: the whole description is the button.
    private var tvText: some View {
        Text(text)
            .font(tvFont)
            .foregroundStyle(foreground.opacity(tvOpacity))
            .lineLimit(lineLimit)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: tvMaxWidth, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shownHeight = $0 }
            .background(alignment: .topLeading) { measurements }
            .mask {
                if isTruncated { truncationMask } else { Rectangle() }
            }
            .overlay(alignment: .bottomTrailing) {
                if isTruncated {
                    Text("MORE")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(foreground)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { moreWidth = $0 }
                        .frame(height: lineHeight)
                }
            }
    }
    #endif

    /// The font the text is set in, which the hidden copies that measure it have to match.
    private var bodyFont: Font {
        #if os(tvOS)
        tvFont
        #else
        .callout
        #endif
    }

    /// Invisible copies of the text that measure how tall all of it is, and how tall one line is.
    private var measurements: some View {
        ZStack(alignment: .topLeading) {
            Text(text)
                .font(bodyFont)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
            Text(verbatim: " ")
                .font(bodyFont)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { lineHeight = $0 }
        }
        .hidden()
        .accessibilityHidden(true)
    }

    /// Shows every line in full except the last, which fades out just before the MORE button.
    private var truncationMask: some View {
        VStack(spacing: 0) {
            Rectangle()
            HStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: Self.fadeWidth)
                Color.clear
                    // A little gap, so the text doesn't run up against the glass edge.
                    .frame(width: moreWidth + 6)
            }
            .frame(height: lineHeight)
        }
    }

    private var moreButton: some View {
        Button(action: onMore) {
            Text("MORE")
                .font(.caption.weight(.bold))
                .foregroundStyle(foreground)
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { moreWidth = $0 }
        // The glass is taller than a line of text, so it's centered on the last line and overhangs it a little.
        .frame(height: lineHeight)
        .accessibilityLabel("More")
        .accessibilityHint("Shows the full description")
    }
}

/// The show's name and genres, centered, above its full description.
struct ShowOverviewSheet: View {
    let title: String

    /// A line under the title, e.g. the genres. Nil for none.
    let subtitle: String?

    let overview: String?

    init(item: MediaItem) {
        self.init(title: item.title, subtitle: item.genres.isEmpty ? nil : item.genres.joined(separator: " · "), overview: item.overview)
    }

    init(title: String, subtitle: String?, overview: String?) {
        self.title = title
        self.subtitle = subtitle
        self.overview = overview
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text(title)
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)

                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let overview {
                    Text(overview)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 16)
                }
            }
            .multilineTextAlignment(.center)
            .padding()
            .padding(.top, 8)
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }
}

#if os(tvOS)
/// Everything about a show, season, episode or movie in a glass sheet: its name, tagline, the whole description, then the
/// facts listed under it. The sheet is the system's, so it has the glass look and the Menu button closes it.
///
/// Each block can take focus, because a scroll view on tvOS only scrolls as focus moves down through what's in it.
struct ShowDetailsSheet: View {
    let title: String
    let tagline: String?
    let overview: String?
    let facts: [(label: String, value: String)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(title)
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                    if let tagline {
                        Text(tagline)
                            .font(.title3.italic())
                            .foregroundStyle(.secondary)
                    }
                }
                .focusable()

                if let overview {
                    Text(overview)
                        .font(.body)
                        .focusable()
                }

                ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(fact.label)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(fact.value)
                            .font(.body)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focusable()
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(60)
        }
    }
}
#endif
