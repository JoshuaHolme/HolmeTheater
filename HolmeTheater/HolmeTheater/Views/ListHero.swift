// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// How a ``ListHero`` shows its artwork.
enum ListHeroStyle {
    /// Like a movie's or show's: a backdrop that runs edge to edge and darkens toward the bottom, behind the details.
    case artwork(URL?)

    /// Like a season's: no artwork of its own, only a sharp poster in the top right. The page behind it, which the owner
    /// supplies (see ``BlurredPageBackground``), is what shows through.
    case poster(URL?)
}

/// The hero at the top of a collection's or playlist's page, with the name (or logo), a line of details, the description and
/// the buttons stacked over its bottom-left corner, over either a backdrop or a poster (see ``ListHeroStyle``).
///
/// Put it first in a scroll view that ignores the top safe area, so the artwork runs up under the navigation bar.
struct ListHero<Buttons: View>: View {
    /// The collection or playlist.
    let item: MediaItem

    /// What's behind the details.
    let style: ListHeroStyle

    /// A line under the name, e.g. "12 items · 18h 40m". Nil for none.
    let detailsLine: String?

    /// The size of the scroll view the hero is in, which decides how tall it is.
    let viewport: CGSize

    /// The buttons under the description, e.g. Play.
    @ViewBuilder let buttons: Buttons

    @Environment(AppModel.self) private var appModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var showsOverview = false

    /// How tall the details are, so the fade behind them can reach up past their top.
    @State private var detailsHeight: CGFloat = 0

    private var themeAccent: Color? { appModel.themeSettings.activeTheme?.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ShowLogo(item: item, maxSizeOverride: Self.logoSize)

            if let detailsLine {
                Text(detailsLine)
                    #if os(tvOS)
                    .font(.system(size: 30, weight: .medium))
                    #else
                    .font(.callout)
                    #endif
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            }

            if let overview = item.overview, !overview.isEmpty {
                #if os(tvOS)
                Text(overview)
                    .font(.system(size: 29))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(3)
                    .frame(maxWidth: 1300, alignment: .leading)
                #else
                TruncatingOverview(text: overview, lineLimit: 3) { showsOverview = true }
                #endif
            }

            buttons
                .padding(.top, 4)
                // As wide as the screen, so a row below reaches them from any card on tvOS, not only those directly under them.
                .frame(maxWidth: .infinity, alignment: .leading)
                .tvFocusSection()
        }
        .foregroundStyle(.white)
        // The details sit on a dark fade whatever the appearance, so their secondary colors are the light ones.
        .environment(\.colorScheme, .dark)
        #if os(tvOS)
        .shadow(color: .black.opacity(0.55), radius: 8)
        #endif
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { detailsHeight = $0 }
        // The same margin as the rest of the app's pages, so they line up.
        .padding(.horizontal, Layout.contentInset)
        // A poster hero leaves room for the first row, which rises over its bottom edge on tvOS, as on a season's page: there's
        // no edge for it to cross.
        .padding(.bottom, 20 + (isPoster ? HeroLayout.bottomReserve : 0))
        // If the details make the hero taller than its usual height, some artwork still shows above them, clear of the
        // navigation bar.
        .padding(.top, Self.minArtworkAboveDetails)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: minHeight, alignment: .bottom)
        // The artwork runs edge to edge, past the side safe areas, while the details stay inside them.
        .background {
            Group {
                switch style {
                case .artwork(let url): backdrop(url)
                case .poster(let url): cornerPoster(url)
                }
            }
            .ignoresSafeArea(edges: .horizontal)
        }
        #if os(tvOS)
        // A little further down, as a season page's first row is, so its heading clears the hero.
        .padding(.bottom, isPoster ? 12 - HeroLayout.bottomReserve : 0)
        #endif
        .sheet(isPresented: $showsOverview) {
            ShowOverviewSheet(item: item)
        }
    }

    private var isPoster: Bool {
        if case .poster = style { return true }
        return false
    }

    #if os(tvOS)
    /// How much of the screen an artwork hero leaves for the first row under it at rest: its heading and cards. The row sits
    /// below the artwork, not over its edge.
    private static var rowRoom: CGFloat { 420 }
    #endif

    /// The hero's usual height: no taller than its width allows at 1.4, which keeps it short in portrait, and no more than
    /// three quarters of the screen. On tvOS, the whole screen for a poster hero, as a season's is; for an artwork hero, the
    /// screen less room for the row beneath, so the row shows at rest below the artwork.
    private var minHeight: CGFloat {
        #if os(tvOS)
        if viewport.height > 0 { return isPoster ? viewport.height : max(viewport.height - Self.rowRoom, 0) }
        #endif
        return min(viewport.height * 0.75, viewport.width / 1.4)
    }

    /// How wide the hero has to be for the poster to show sharp beside the details, and how much of the hero's height it fills,
    /// and its distance from the top and side edges. The same as a season's page.
    private static var posterMinWidth: CGFloat { 700 }
    private static var posterHeightFraction: CGFloat { 0.6 }
    private static var posterInset: CGFloat { 48 }

    /// The poster in the hero's top corner, where the hero is wide enough to leave room beside the details.
    private func cornerPoster(_ url: URL?) -> some View {
        GeometryReader { proxy in
            if let url, proxy.size.width > Self.posterMinWidth {
                CachedAsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFit()
                    }
                }
                .frame(height: proxy.size.height * Self.posterHeightFraction)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.trailing, Self.posterInset)
                // Clear of the navigation bar where there is one, then the same inset as the side.
                .padding(.top, Self.minArtworkAboveDetails + Self.posterInset)
            }
        }
        .accessibilityHidden(true)
    }

    private static var logoSize: CGSize? {
        #if os(tvOS)
        CGSize(width: 440, height: 150)
        #else
        nil
        #endif
    }

    private static var minArtworkAboveDetails: CGFloat {
        #if os(tvOS)
        0
        #else
        120
        #endif
    }

    /// The artwork, darkening toward the bottom so the details read over any image. On iOS it scrolls with parallax, moving
    /// slower than the page; pulled down past the top, it stretches to fill the gap.
    private func backdrop(_ imageURL: URL?) -> some View {
        #if os(tvOS)
        let lag: CGFloat = 0
        #else
        let lag: CGFloat = 0.5
        #endif

        return Color.black
            .overlay {
                CachedAsyncImage(url: imageURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    }
                }
                .allowsHitTesting(false)
                .visualEffect { content, proxy in
                    let top = proxy.frame(in: .scrollView).minY
                    return content.offset(y: top < 0 ? -top * lag : 0)
                }
            }
            .clipped()
            .overlay {
                GeometryReader { proxy in
                    LinearGradient(stops: scrimStops(heroHeight: proxy.size.height), startPoint: .top, endPoint: .bottom)
                }
            }
            #if os(tvOS)
            // Darker on the side the text is on, fading out toward the other, as on Home.
            .overlay {
                LinearGradient(colors: [.black.opacity(0.6), .black.opacity(0.25), .clear], startPoint: .leading, endPoint: .trailing)
            }
            #endif
            .visualEffect { content, proxy in
                let top = proxy.frame(in: .scrollView).minY
                let height = proxy.size.height
                let scale = top > 0 && height > 0 ? (height + top) / height : 1
                return content.scaleEffect(scale, anchor: .bottom)
            }
            .accessibilityHidden(true)
    }

    /// The stops of the fade behind the details. It usually begins 30% of the way down, and higher if the details are tall, so
    /// their first line isn't over bare artwork.
    private func scrimStops(heroHeight: CGFloat) -> [Gradient.Stop] {
        var start: CGFloat = 0.3
        if heroHeight > 0, detailsHeight > 0 {
            let covered = detailsHeight + 20 + 60
            start = min(start, max(0, 1 - covered / heroHeight))
        }
        let base = Color.themedBlack(themeAccent)
        return listHeroScrimProfile.map { step in
            Gradient.Stop(color: base.opacity(step.opacity), location: start + (1 - start) * step.position)
        }
    }
}

/// A picture blurred and darkened to fill the whole page, hero and rows alike, as a season's page has. Put it in the scrolling
/// content's background so it moves with the page. When `url` changes, the new picture fades in over the old one.
///
/// Give it a picture that's already in ``ImageCache`` (see ``ImageCache/preload(_:timeout:)``), so the fade doesn't start from
/// nothing. The picture is blurred, so a small one is enough.
struct BlurredPageBackground: View {
    let url: URL?

    /// How far it reaches below the content, more than any bottom safe area, which the scroll view keeps outside its content,
    /// where a background can't ignore it.
    private static var overhang: CGFloat { 200 }

    var body: some View {
        Color.black
            .overlay {
                ZStack {
                    if let url {
                        BlurredLayer(url: url)
                            // A new picture is a new layer, so the old one fades out as it fades in.
                            .id(url)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.4), value: url)
            }
            .overlay {
                // Darker down the page, where the rows' headings and cards are.
                LinearGradient(colors: [.black.opacity(0.3), .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
            }
            .clipped()
            // Edge to edge, past the side safe areas.
            .ignoresSafeArea(edges: .horizontal)
            .padding(.bottom, -Self.overhang)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// One picture of a ``BlurredPageBackground``, scaled up so the blur's soft edges fall outside it.
private struct BlurredLayer: View {
    let url: URL

    var body: some View {
        CachedAsyncImage(url: url) { phase in
            if case .success(let image) = phase {
                image.resizable().scaledToFill()
            }
        }
        .scaleEffect(1.3)
        .blur(radius: 50)
    }
}

/// The fade's opacity at each fraction of its length, easing in from nothing to the strongest, like the show page's.
private let listHeroScrimProfile: [(position: CGFloat, opacity: Double)] = [
    (0, 0), (0.214, 0.2), (0.429, 0.5), (0.686, 0.7), (1, 0.85)
]

extension MediaItem {
    /// The artwork for a collection's or playlist's hero: its own backdrop, else the first backdrop among what it holds, else its
    /// poster.
    func heroArtworkURL(among members: [MediaItem]) -> URL? {
        backdropURL ?? members.lazy.compactMap(\.backdropURL).first ?? posterURL
    }
}
