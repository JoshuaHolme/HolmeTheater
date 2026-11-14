// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// The hero at the top of a collection's or playlist's page, built like a movie's or show's: a backdrop that runs edge to
/// edge and darkens toward the bottom, with the name (or logo), a line of details, the description and the buttons stacked
/// over its bottom-left corner.
///
/// Put it first in a scroll view that ignores the top safe area, so the artwork runs up under the navigation bar.
struct ListHero<Buttons: View>: View {
    /// The collection or playlist.
    let item: MediaItem

    /// The artwork behind the details, or nil for none.
    let imageURL: URL?

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
        // Leaves room for the first row, which rises over the artwork's bottom edge on tvOS.
        .padding(.bottom, 20 + HeroLayout.bottomReserve)
        // If the details make the hero taller than its usual height, some artwork still shows above them, clear of the
        // navigation bar.
        .padding(.top, Self.minArtworkAboveDetails)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: minHeight, alignment: .bottom)
        // The artwork runs edge to edge, past the side safe areas, while the details stay inside them.
        .background { backdrop.ignoresSafeArea(edges: .horizontal) }
        #if os(tvOS)
        // As on Home and the show page: scrolled up, the hero leaves faster than the page, so the first row comes away from it
        // and stands on its own. Read here, not in the effect, which runs outside the main actor.
        .visualEffect { [lead = Self.parallaxLead, travel = Self.parallaxTravel] content, proxy in
            let scrolled = max(0, -proxy.frame(in: .scrollView).minY)
            return content.offset(y: -min(scrolled, travel) * lead)
        }
        // A little further down, as Home's first shelf is, so its heading clears the artwork's edge.
        .padding(.bottom, 12 - HeroLayout.bottomReserve)
        #endif
        .sheet(isPresented: $showsOverview) {
            ShowOverviewSheet(item: item)
        }
    }

    #if os(tvOS)
    /// How far the page scrolls to bring the first row into view, and how much faster than the page the hero leaves over that
    /// stretch: Home's, whose first row is about as tall as this page's.
    private static var parallaxTravel: CGFloat { HeroLayout.parallaxTravel }
    private static var parallaxLead: CGFloat { HeroLayout.parallaxLead }
    #endif

    /// The hero's usual height: no taller than its width allows at 1.4, which keeps it short in portrait, and no more than
    /// three quarters of the screen. On tvOS, the whole screen, like Home's carousel.
    private var minHeight: CGFloat {
        #if os(tvOS)
        if viewport.height > 0 { return viewport.height }
        #endif
        return min(viewport.height * 0.75, viewport.width / 1.4)
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
    private var backdrop: some View {
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
