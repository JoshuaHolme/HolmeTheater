// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

// The detail hero: its artwork, the fades over it, the season page's blurred background, and the lines of text stacked
// over the bottom-left corner.

extension ShowDetailView {
    /// The backdrop, with the show's details stacked over its bottom-left corner.
    var hero: some View {
        VStack(alignment: .leading, spacing: Self.detailsSpacing) {
            // A season has the show's logo (or its name, if there is none), then its own name beneath.
            ShowLogo(item: current, fallbackTitle: isSeason || isEpisode ? (item.seriesTitle ?? item.title) : nil, maxSizeOverride: Self.logoSize)

            if isSeason {
                Text(item.seasonTitle)
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
            } else if isEpisode {
                // The episode's own name, with where it falls in the show beneath.
                Text(item.title)
                    .font(.title2.bold())
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
                    .accessibilityAddTraits(.isHeader)
                if let position = item.seasonEpisodeText {
                    Text(position)
                        .font(.callout)
                }
            }

            // As in the TV app, the short genre line is the bright one and the description recedes beneath it,
            // so the two read as different things without the genres fading into the artwork.
            #if os(tvOS)
            // As on Home: what it is and its first genres, with the content rating boxed beside them.
            if detailsLine != nil || current.officialRating != nil {
                HStack(spacing: 10) {
                    if let line = detailsLine {
                        Text(line)
                            .font(.system(size: 30, weight: .medium))
                            .lineLimit(shortTextLineLimit)
                    }
                    if let rating = current.officialRating {
                        Text(rating)
                            .font(.system(size: 22, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.white, lineWidth: 1.5) }
                    }
                }
                .accessibilityElement(children: .combine)
            }
            #else
            if let details = detailsLine {
                Text(details)
                    .font(.callout)
                    .lineLimit(shortTextLineLimit)
            }
            #endif

            if let tagline = current.tagline {
                Text(tagline)
                    .font(.callout.italic())
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(shortTextLineLimit)
            }

            if let overview = current.overview {
                #if os(tvOS)
                // Big enough to read from the couch: three lines across most of the screen. Cut off with an ellipsis if it
                // runs out of room; the Details button has all of it.
                Text(overview)
                    .font(.system(size: 29))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(3)
                    .frame(maxWidth: 1300, alignment: .leading)
                #else
                TruncatingOverview(text: overview, lineLimit: 3, isFocusable: overviewIsFocusable) { showsOverview = true }
                #endif
            }

            // The run (and whether it's over) on one line, the ratings on the next.
            VStack(alignment: .leading, spacing: 2) {
                if let status = statusLine {
                    Text(status)
                }
                if let ratings = ratingsLine {
                    Text(ratings)
                }
                if let technical = current.technicalLine {
                    Text(technical)
                }
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.white.opacity(0.75))

            // The trailer's label gives way to just its icon if the row doesn't fit.
            #if os(tvOS)
            // The row is never too wide for a TV (there's no trailer button), so there's nothing to choose between.
            // Choosing could rebuild the Play button as the hero's size settles, and lose the focus given to it.
            actionButtons(showsTrailerTitle: false, compactPlay: false)
                .padding(.top, 4)
            #else
            ViewThatFits(in: .horizontal) {
                actionButtons(showsTrailerTitle: true, compactPlay: false)
                actionButtons(showsTrailerTitle: false, compactPlay: false)
                actionButtons(showsTrailerTitle: false, compactPlay: true)
            }
            .padding(.top, 4)
            #endif
        }
        .foregroundStyle(.white)
        // The details sit on a dark fade whatever the appearance, so their secondary colors are the light ones.
        .environment(\.colorScheme, .dark)
        #if os(tvOS)
        // A soft shadow keeps the text readable over bright artwork, as on Home.
        .shadow(color: .black.opacity(0.55), radius: 8)
        #endif
        // How tall the details are, so the fade behind them can reach up past their top.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { detailsHeight = $0 }
        // The same margin as Home's text and shelves, so they line up.
        .padding(.horizontal, Layout.contentInset)
        // Leaves room for the first row, which rises over the artwork's bottom edge on tvOS.
        .padding(.bottom, 20 + HeroLayout.bottomReserve)
        // If the details make the hero taller than its usual height, some artwork still shows above them, clear
        // of the navigation bar.
        .padding(.top, Self.minArtworkAboveDetails)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: heroMinHeight, alignment: .bottom)
        // The artwork runs edge to edge, past the side safe areas (e.g. under a sidebar tab bar in landscape),
        // while the details stay inside them.
        .background { backdrop.ignoresSafeArea(edges: .horizontal) }
    }

    /// The hero's usual height, like the TV app's: no taller than its width allows at `heroAspectRatio`, which keeps it
    /// short in portrait, and no more than `heroFraction` of the screen, which keeps it from filling a landscape
    /// screen. Taller only if the details need it.
    var heroMinHeight: CGFloat {
        #if os(tvOS)
        // The whole screen, like Home's carousel.
        if fullScreenHeight > 0 { return fullScreenHeight }
        #endif
        return min(screenSize.height * Self.heroFraction, screenSize.width / Self.heroAspectRatio)
    }

    /// The hero's narrowest shape, width divided by height.
    static let heroAspectRatio: CGFloat = 1.4

    /// The most of the screen's height the hero fills.
    static var heroFraction: CGFloat {
        #if os(tvOS)
        return 1
        #else
        return 0.75
        #endif
    }

    /// The logo's size cap. On tvOS it's the Home carousel's, smaller than the usual.
    static var logoSize: CGSize? {
        #if os(tvOS)
        CGSize(width: 440, height: 150)
        #else
        nil
        #endif
    }

    /// Space between the lines of the hero's details.
    static var detailsSpacing: CGFloat { 12 }

    #if os(tvOS)
    /// How far the page scrolls to bring the first row into view. Home's first row is widescreen cards; here it's season
    /// posters, which are taller by the difference in their heights, so the page scrolls that much further.
    static var parallaxTravel: CGFloat {
        HeroLayout.parallaxTravel + (Layout.posterWidth * 1.5 - Layout.wideCardWidth * 9 / 16)
    }

    /// How much faster than the page the hero leaves, scaled down over that longer scroll so the hero takes back the same
    /// total distance as Home's (what the row rises over the artwork, plus the gap) and doesn't rush away.
    static var parallaxLead: CGFloat {
        HeroLayout.parallaxLead * HeroLayout.parallaxTravel / parallaxTravel
    }
    #endif

    /// Space between the hero and the rows beneath it, and between one row and the next.
    static var rowSpacing: CGFloat {
        #if os(tvOS)
        Layout.shelfSpacing
        #else
        24
        #endif
    }

    /// The least artwork left showing above the details.
    static var minArtworkAboveDetails: CGFloat {
        #if os(tvOS)
        return 0
        #else
        return 120
        #endif
    }

    /// How fast the artwork moves as the screen scrolls up, relative to the scrolling: 0.5 is half as fast.
    static let parallaxSpeed: CGFloat = 0.5

    /// The show's backdrop (or poster, if it has none), filling the hero and darkening toward the bottom so the
    /// details read over any image.
    ///
    /// Like the TV app's, it scrolls with parallax: scrolling up, the artwork moves slower than the page, so it
    /// slides away behind the details; pulling down past the top, it stretches to fill the gap above it.
    var backdrop: some View {
        // Read here rather than inside the effects, which run outside the main actor.
        // On tvOS the whole hero moves faster than the page instead (see the body), as Home's does, so the artwork stays put in it.
        #if os(tvOS)
        let lag: CGFloat = 0
        #else
        let lag = 1 - Self.parallaxSpeed
        #endif

        // A season's hero has no artwork or fades of its own: its blurred poster is the whole page's background (see
        // `seasonPageBackground`), so there's no edge where the hero ends.
        let isClear = usesPosterArtwork

        return Color.black.opacity(isClear ? 0 : 1)
            .overlay {
                CachedAsyncImage(url: heroImageURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    }
                }
                // Purely visual; the overflow from filling the frame shouldn't take taps.
                .allowsHitTesting(false)
                // Scrolled up, the artwork is pushed back down by part of the distance, so it moves slower than
                // the page. What's pushed past the hero's bottom is clipped below.
                .visualEffect { content, proxy in
                    let top = proxy.frame(in: .scrollView).minY
                    return content.offset(y: top < 0 ? -top * lag : 0)
                }
            }
            .clipped()
            // Where the hero is wide enough to leave room beside the details, the season's poster shows large and sharp
            // in the top corner, the same distance from the top and the side edge.
            .overlay(alignment: .topTrailing) {
                if usesPosterArtwork, let artworkURL = cornerArtworkURL {
                    GeometryReader { proxy in
                        if proxy.size.width > Self.sharpPosterMinWidth {
                            CachedAsyncImage(url: artworkURL) { phase in
                                if case .success(let image) = phase {
                                    image.resizable().scaledToFit()
                                }
                            }
                            // A season's tall poster is sized by its height, an episode's widescreen still by its width.
                            .frame(
                                width: isEpisode ? proxy.size.width * Self.sharpStillFraction : nil,
                                height: isEpisode ? nil : proxy.size.height * Self.sharpPosterFraction
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(.trailing, Self.sharpPosterInset)
                            // Clear of the navigation bar where there is one, then the same inset as the side.
                            .padding(.top, Self.minArtworkAboveDetails + Self.sharpPosterInset)
                        }
                    }
                }
            }
            .overlay {
                // Eased rather than linear: it starts gently, so the artwork's top half is untouched, then deepens
                // behind the details. Easing also avoids the visible edge a straight ramp leaves where it begins.
                GeometryReader { proxy in
                    LinearGradient(
                        stops: scrimStops(heroHeight: proxy.size.height),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .opacity(isClear ? 0 : 1)
            }
            #if os(tvOS)
            // Darker on the side the text is on, fading out toward the other, as on Home.
            .overlay {
                LinearGradient(
                    colors: [.black.opacity(0.6), .black.opacity(0.25), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .opacity(isClear ? 0 : 1)
            }
            #endif
            // Pulled down past the top, the backdrop grows from its bottom edge to cover the gap the overscroll
            // opens above it. After the clip, so the growth isn't clipped away.
            .visualEffect { content, proxy in
                let top = proxy.frame(in: .scrollView).minY
                let height = proxy.size.height
                let scale = top > 0 && height > 0 ? (height + top) / height : 1
                return content.scaleEffect(scale, anchor: .bottom)
            }
            .accessibilityHidden(true)
    }

    /// The stops of the fade that darkens the backdrop behind the details (see ``HeroScrim``).
    func scrimStops(heroHeight: CGFloat) -> [Gradient.Stop] {
        let start = HeroScrim.start(heroHeight: heroHeight, detailsHeight: detailsHeight, bottomReserve: HeroLayout.bottomReserve)
        return HeroScrim.stops(start: start, base: Color.themedBlack(themeAccent))
    }

    /// e.g. "Comedy · Drama · HBO": the genres, then the network the show aired on. Nil if neither is known.
    var detailsLine: String? { current.detailLine }

    /// The poster the page's blurred background is made from: a season's own, or for an episode the poster of its
    /// season (the show's, if the season's isn't known). Nil for a show or movie, which use their backdrop.
    var pageBackgroundURL: URL? {
        if isSeason { return current.posterURL }
        if isEpisode { return current.seasonPosterURL ?? current.posterURL }
        return nil
    }

    /// Whether the page is built from a blurred poster, as a season's and an episode's are, rather than a backdrop.
    var usesPosterArtwork: Bool { pageBackgroundURL != nil }

    /// The picture shown sharp in the hero's top corner: a season's poster, or an episode's own still.
    var cornerArtworkURL: URL? { isEpisode ? current.thumbnailURL : current.posterURL }

    /// How far a season's page background reaches below its content, more than any bottom safe area.
    static let pageBackgroundOverhang: CGFloat = 200

    /// A season's poster, blurred and darkened to fill the whole page, hero and rows alike. It's part of the scrolling
    /// content, so it moves with the page as the sections go by. Scaled up so the blur's soft edges fall outside it.
    var seasonPageBackground: some View {
        Color.black
            .overlay {
                CachedAsyncImage(url: pageBackgroundURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        // The season has no poster of its own on the server: the show's stands in.
                        if let fallback = current.posterURL, fallback != pageBackgroundURL {
                            CachedAsyncImage(url: fallback) { phase in
                                if case .success(let image) = phase {
                                    image.resizable().scaledToFill()
                                }
                            }
                        }
                    default:
                        EmptyView()
                    }
                }
                .scaleEffect(1.3)
                .blur(radius: 50)
            }
            .overlay {
                // Darker down the page, where the rows' headings and cards are.
                LinearGradient(colors: [.black.opacity(0.3), .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
            }
            .clipped()
            // Edge to edge, past the side safe areas, as the hero's artwork is.
            .ignoresSafeArea(edges: .horizontal)
            // Taller than the content, so it reaches the bottom of the screen when the last row is scrolled into view.
            // The scroll view keeps the bottom safe area outside its content, where a background can't ignore it, so it
            // overhangs by more than that.
            .padding(.bottom, -Self.pageBackgroundOverhang)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// How wide the hero has to be for a season's poster to show sharp beside its details.
    static let sharpPosterMinWidth: CGFloat = 700

    /// How much of the hero's height a season's sharp poster fills.
    static let sharpPosterFraction: CGFloat = 0.6

    /// How much of the hero's width an episode's sharp still fills.
    static let sharpStillFraction: CGFloat = 0.33

    /// The space between a season's sharp poster and the hero's top and side edges.
    static let sharpPosterInset: CGFloat = 48

    /// The hero's image: a season's own poster, an episode's own still, otherwise the backdrop (or poster, if there
    /// is none).
    var heroImageURL: URL? {
        // A season's poster is the page's background, not the hero's image.
        if usesPosterArtwork { return nil }
        return isEpisode ? current.thumbnailURL ?? current.backdropURL ?? current.posterURL : current.backdropURL ?? current.posterURL
    }

    /// The hero's status line: whatever its kind shows (see ``MediaItem/heroStatusLine``).
    var statusLine: String? { current.heroStatusLine }

    /// The hero's ratings line. On tvOS the content rating is boxed beside the genres instead, so it's left out here.
    var ratingsLine: String? {
        #if os(tvOS)
        current.ratingsLine(includingOfficialRating: false)
        #else
        current.ratingsLine(includingOfficialRating: true)
        #endif
    }
}
