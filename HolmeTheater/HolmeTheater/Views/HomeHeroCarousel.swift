// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The buttons in the carousel's row (tvOS) that focus is moved to by name.
private enum HeroControl: Hashable {
    case play
    case info
}

/// Layout shared by the carousel and the page that holds it.
enum HeroLayout {
    /// How far above the carousel's bottom edge its page dots sit: just above the first shelf's heading, as in the Apple
    /// TV app, which is closer to the shelf than the buttons are.
    static var dotsLift: CGFloat { bottomReserve == 0 ? 0 : bottomReserve - 52 }

    /// How much room the text leaves under it for the button row, which on tvOS isn't part of a page: it's one row on the
    /// carousel, so it stays put (and keeps focus) as the pages slide.
    static var textLift: CGFloat {
        #if os(tvOS)
        return buttonRowHeight + 12
        #else
        return 0
        #endif
    }

    /// The height of the button row.
    static var buttonRowHeight: CGFloat { 70 }

    /// How much faster than the page the carousel leaves as the page scrolls up (tvOS), as a share of the scrolling: 0.76
    /// makes it go 1.76 times as fast. The shelves move with the page and the artwork pulls away above them, so the first
    /// shelf ends up standing apart from the carousel, with a gap between them, rather than hanging off its edge. At rest
    /// the shelf rises 200 points or so over the artwork; this has to take back that much and leave a gap, over the
    /// roughly 335 points the page scrolls to bring the shelf into view. The gap comes to about 56 points from the
    /// carousel's edge to the heading, as measured in the Apple TV app's home screen.
    static var parallaxLead: CGFloat { 0.76 }

    /// How far the page scrolls, in points, over which the carousel gets that extra speed. It's about what it takes to bring
    /// the first shelf into view, which is when the gap is made. Past that the carousel moves with the page, keeping the
    /// gap, so it stays on screen above the shelves rather than running off the top and leaving the space it filled empty.
    static var parallaxTravel: CGFloat { 335 }

    /// How much of the carousel's bottom edge the first shelf rises over, so the shelf's heading and the tops of its
    /// cards show over the artwork at rest, as in the Apple TV app. Only tvOS does this; the carousel keeps its
    /// details and page dots above this much of its bottom.
    static var bottomReserve: CGFloat {
        #if os(tvOS)
        return 260
        #else
        return 0
        #endif
    }
}

#if os(tvOS)
private extension View {
    /// Moves down by up to `distance` as the page scrolls, over the stretch in which the carousel pulls away from the first
    /// shelf (`HeroLayout.parallaxTravel`). Applied to something as big as the carousel.
    ///
    /// Inside the carousel, its position in the scroll view already includes the page's parallax, which moves it
    /// `parallaxLead` more than the scrolling, so that's allowed for: the move is done only when the carousel has stopped
    /// pulling away, at the artwork's bottom edge, and never gets ahead of the shelf rising to meet it.
    ///
    /// Linear in the scrolling, not eased: an ease would flatten out near the ends, so going back up the details would
    /// reach their place before the shelf does. This way they and the shelf arrive together, in either direction.
    func settles(by distance: CGFloat) -> some View {
        visualEffect { [span = HeroLayout.parallaxTravel * (1 + HeroLayout.parallaxLead)] content, proxy in
            let moved = max(0, -proxy.frame(in: .scrollView).minY)
            return content.offset(y: min(moved / span, 1) * distance)
        }
    }
}
#endif

/// A row of full-width hero images, one for each of the newest items on the server, that advances by itself.
///
/// It moves to the next item after ``advanceInterval`` and loops back to the first after the last. Touching it, by
/// swiping or tapping a dot, starts the wait over, and it holds still while a finger is dragging it.
///
/// It runs edge to edge, under the status bar and past the side safe areas, with the page's heading over its top.
struct HomeHeroCarousel<Header: View>: View {
    @Environment(AppModel.self) private var appModel

    let items: [MediaItem]

    /// What each item's Play button plays, by the item's ID: a movie itself, or the episode a show is up to. An item
    /// with nothing to play has no Play button.
    let playTargets: [MediaItem.ID: MediaItem]

    /// The screen's safe area, which the artwork runs past and the text stays inside.
    let safeArea: EdgeInsets

    /// The whole screen's size, safe areas included. The carousel fills its width and most of its height, like the
    /// Apple TV app's.
    let screenSize: CGSize

    /// Called when an item's hero is tapped.
    let open: (MediaItem) -> Void

    /// Called when an item's Play button is tapped. (On tvOS, also when More Info is selected.)
    let play: (MediaItem) -> Void

    /// Called with the item showing, when the carousel first shows and each time it moves to another.
    var onSelectionChange: ((MediaItem) -> Void)?

    /// The page's heading, over the top of the artwork.
    @ViewBuilder let header: () -> Header

    /// How wide the page dot of the item showing is.
    private static var selectedDotWidth: CGFloat { 32 }

    /// How long each item stays up before the next one slides in.
    static var advanceInterval: Duration { .seconds(15) }

    /// Where the carousel is along an endless strip of pages: the page showing, counting every step taken, so going past the
    /// last item continues to a further page that shows the first again, not back to it. The pages are placed by this, so a
    /// page that's still sliding off is never taken away while it's in view, and the next is always right beside it.
    @State private var virtualIndex = 0

    /// The position in `items` of the item showing.
    private var index: Int { CarouselMath.index(forVirtual: virtualIndex, count: items.count) }

    /// With either of these on, it doesn't move by itself: content sliding away unasked is hard to follow, and with
    /// VoiceOver it would move what's being read.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    /// How long after a swipe a tap on the page is ignored. The finger lifting reaches the page's button a moment after
    /// the swipe ends, and would otherwise open the item.
    private static var tapSuppressionAfterSwipe: Duration { .milliseconds(300) }

    /// How much further, in seconds of the finger's speed, a swipe is taken to coast when deciding where it lands.
    private static var swipeCoastTime: CGFloat { 0.25 }

    /// How far a swipe has to coast, or be dragged, as a share of the width, to move to the next item.
    private static var flickThreshold: CGFloat { 0.4 }
    private static var dragThreshold: CGFloat { 0.25 }

    /// How far a finger has dragged the pages sideways.
    @State private var dragOffset: CGFloat = 0

    /// Whether a finger is dragging the carousel, which holds off the next advance.
    @State private var isDragging = false

    /// Set during a swipe and just after it, so lifting a finger that started on a page doesn't count as a tap on it.
    @State private var isSwiping = false

    /// How far through its wait the item showing is, from 0 to 1, which fills its page dot.
    @State private var progress: CGFloat = 0

    /// Which of the buttons has focus, if one does. Setting it moves focus there.
    @FocusState private var heroFocus: HeroControl?

    /// The item whose text and buttons are showing (tvOS). It follows `index` a moment late: when the hero changes, the text
    /// and buttons fade out, then this catches up while they're invisible, and they fade back in as the new item's.
    @State private var shownIndex = 0

    /// How visible the text and buttons are (tvOS), for that fade.
    @State private var contentOpacity: Double = 1

    /// The fade in progress, so a quick run of changes restarts it rather than piling up.
    @State private var fadeTask: Task<Void, Never>?

    /// How far above the artwork's bottom edge the details and dots rest when settled, beyond their usual margins.
    private static var settledBottomGap: CGFloat { 20 }

    private var width: CGFloat { screenSize.width }

    /// The theme's color, while a theme is showing.
    private var accent: Color? { appModel.themeSettings.activeTheme?.accent }

    /// The color of the page dot that's filling: white, or the theme's color lightened so it still shows on the dark pill.
    private var dotColor: Color { accent.map { $0.mix(with: .white, by: 0.25) } ?? .white }

    /// The carousel's height: tall and nearly poster-shaped on a narrow screen, and no more than most of the screen's
    /// height on a wide one. Like the artwork, it runs up under the status bar.
    private var height: CGFloat {
        #if os(tvOS)
        // The whole screen, like the Apple TV app's. The first shelf rises over its bottom edge (see `HeroLayout`).
        return screenSize.height
        #else
        return min(width * 1.25, screenSize.height * 0.82)
        #endif
    }

    /// How many pages each side of the one showing exist. Enough that, however fast the remote turns pages, the page that's
    /// leaving is still there, in view, while the ones after it slide in.
    private static var pagesEachSide: Int { 3 }

    /// The pages that exist: those within `pagesEachSide` of the one showing.
    private var pages: [Int] {
        guard items.count > 1 else { return [virtualIndex] }
        return Array((virtualIndex - Self.pagesEachSide)...(virtualIndex + Self.pagesEachSide))
    }

    /// The item a page along the strip shows.
    private func item(onPage page: Int) -> MediaItem {
        guard items.count > 1 else { return items[0] }
        return items[CarouselMath.index(forVirtual: page, count: items.count)]
    }

    /// How many steps along the strip, the short way round, to the page showing the item at `position`.
    private func steps(to position: Int) -> Int {
        CarouselMath.steps(from: index, to: position, count: items.count)
    }

    var body: some View {
        // Only the page showing and its neighbors exist, each placed by how far it is from the one showing. Moving to
        // another item animates their positions, so the one leaving slides off as the one arriving slides on, and
        // the first slides in after the last the same way as any other.
        ZStack {
            ForEach(pages, id: \.self) { page in
                let item = item(onPage: page)
                HeroPage(
                    item: item,
                    playTarget: playTargets[item.id],
                    safeArea: safeArea,
                    accent: accent,
                    open: { if !isSwiping { open($0) } },
                    play: { if !isSwiping { play($0) } }
                )
                // The closures are new each time this runs, which would redraw every page for every frame of a
                // drag. See `HeroPage.==` for why comparing without them is safe.
                .equatable()
                .frame(width: width, height: height)
                .offset(x: CGFloat(page - virtualIndex) * width)
                // The others are only there to slide in or out; VoiceOver reads the one showing.
                .accessibilityHidden(page != virtualIndex)
            }
        }
        // The drag moves every page together, so it's one transform on the stack, not a new position for each page.
        .offset(x: dragOffset)
        .frame(height: height)
        .clipped()
        .contentShape(Rectangle())
        #if !os(tvOS)
        .gesture(HorizontalPan(onChanged: swipeChanged, onEnded: swipeEnded))
        #endif
        #if os(tvOS)
        // The soft pieces of the theme's effects pass over the artwork here, behind the hero's text and buttons, as they pass
        // behind the shelves below (the artwork would otherwise hide them).
        .overlay {
            if let theme = appModel.themeSettings.activeTheme, appModel.themeSettings.showsEffects {
                ThemeParticles(effect: theme.effect, topInset: safeArea.top, layer: .back)
            }
        }
        #endif
        .overlay(alignment: .topLeading) {
            header()
                .padding(.top, safeArea.top + 8)
                .padding(.leading, safeArea.leading)
                .padding(.trailing, safeArea.trailing)
        }
        #if os(tvOS)
        // As the page scrolls and the first shelf comes away from the carousel, the text, buttons and dots settle down toward
        // the artwork's bottom edge, which the shelf's rise over it had kept them clear of. They move with the scrolling,
        // and reach the bottom as the artwork's extra movement ends.
        // The text and buttons aren't on the pages: they fade out and in as the hero changes, while the artwork slides.
        .overlay {
            let item = items[min(shownIndex, items.count - 1)]
            HeroDetails(item: item, playTarget: playTargets[item.id], safeArea: safeArea, play: play)
                .opacity(contentOpacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .settles(by: HeroLayout.bottomReserve - Self.settledBottomGap)
        }
        .overlay {
            tvControls
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .settles(by: HeroLayout.bottomReserve - Self.settledBottomGap)
        }
        #endif
        .overlay(alignment: .bottom) {
            #if os(tvOS)
            pageDots
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .settles(by: HeroLayout.dotsLift - Self.settledBottomGap)
            #else
            pageDots
            #endif
        }
        // Full width, so only one page is ever in view and the page dots are centered on the screen. Without this
        // the carousel stops at the side safe areas.
        .ignoresSafeArea(edges: .horizontal)
        // Restarts whenever the item changes, whether it moved by itself or was swiped, and while a finger is down,
        // so the wait is always the full interval from the last touch. Cancelled when the screen goes away.
        .task(id: Advance(index: index, isDragging: isDragging, isPaused: reduceMotion || voiceOverEnabled)) {
            await advanceAfterWait()
        }
        .onChange(of: index, initial: true) { _, position in
            if items.indices.contains(position) { onSelectionChange?(items[position]) }
        }
        #if os(tvOS)
        .onChange(of: index) { _, position in fadeContent(to: position) }
        #endif
        // A reload can bring fewer items; start again from the first rather than point past the end.
        .onChange(of: items.count) { _, count in
            if shownIndex >= count { shownIndex = 0 }
        }
    }

    #if os(tvOS)
    /// Play and More Info, as one row on the carousel rather than on each page, so the buttons are the same two views
    /// whichever hero is showing, and focus stays on them as the pages change.
    ///
    /// Left of the row is a strip of invisible targets (`BackStandIn`) that turns the page back when the remote moves left from
    /// Play. On the first hero they're off, so left opens the sidebar as usual.
    private var tvControls: some View {
        let item = items[min(shownIndex, items.count - 1)]
        let leading = safeArea.leading + (Layout.contentInset ?? 0)

        return ZStack(alignment: .bottomLeading) {
            HStack(spacing: 24) {
                if let target = playTargets[item.id] {
                    Button { play(target) } label: {
                        Label(target.playButtonTitle(forShow: item.kind == .series), systemImage: "play.fill")
                            .font(.callout.weight(.semibold))
                    }
                    // The same bordered style as More Info and the item pages' buttons, so it takes the theme's color when
                    // focused (the prominent style draws white).
                    .buttonStyle(.bordered)
                    // A pill: fully round ends, not just rounded corners.
                    .buttonBorderShape(.capsule)
                    .focused($heroFocus, equals: .play)
                }

                // Just an icon, as in the Apple TV app; the label is for VoiceOver.
                FocusExpandingIconButton("More Info", systemImage: "info.circle", font: .system(size: 30, weight: .semibold)) { open(item) }
                .focused($heroFocus, equals: .info)
                // At the right edge, moving right goes to the next item rather than nowhere.
                .onMoveCommand { direction in
                    if direction == .right { stepPage(1) }
                }
            }
            // As wide as the screen, not just the buttons, so up from a card anywhere along the shelf below reaches them.
            // The section is what the focus engine looks for above a card, and one only as wide as the buttons was above
            // just the first card (and barely the second).
            .frame(maxWidth: .infinity, alignment: .leading)
            .tvFocusSection()
            .opacity(contentOpacity)
            .padding(.leading, leading)

            // From the screen's edge to the buttons, at their height.
            BackStandIn(
                canGoBack: { index > 0 },
                onBack: { if index > 0 { stepPage(-1) } },
                // Straight back to Play, whenever focus lands on the strip.
                onReturnFocus: {
                    if heroFocus == .play {
                        // SwiftUI may not have noticed yet that focus has left Play, and setting the same value again
                        // would do nothing. Clear it first, so the next setting is a change.
                        heroFocus = nil
                        Task { heroFocus = .play }
                    } else {
                        heroFocus = .play
                    }
                }
            )
            .frame(width: max(0, leading - 4), height: HeroLayout.buttonRowHeight)
            .accessibilityHidden(true)
        }
        .padding(.bottom, 44 + HeroLayout.bottomReserve)
    }
    #endif

    #if os(tvOS)
    /// Fades the text and buttons out, switches them to the item at `position` while they can't be seen, and fades them in.
    /// The artwork slides meanwhile, so the new text arrives as it settles, as in the Apple TV app. A new change before this
    /// is done starts it over from wherever the fade has got to.
    private func fadeContent(to position: Int) {
        fadeTask?.cancel()
        fadeTask = Task { @MainActor in
            withAnimation(.easeOut(duration: 0.18)) { contentOpacity = 0 }
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled else { return }
            // Out of sight, so no animation: it just becomes the new item's.
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { shownIndex = position }
            withAnimation(.easeIn(duration: 0.4)) { contentOpacity = 1 }
        }
    }
    #endif

    /// Moves to the next hero (1) or the previous (-1).
    private func stepPage(_ delta: Int) {
        guard items.count > 1 else { return }
        withAnimation(Self.manualSlide) { virtualIndex += delta }
    }

    /// What the wait depends on: a new value starts it over.
    private struct Advance: Hashable {
        let index: Int
        let isDragging: Bool
        let isPaused: Bool
    }

    /// The slide when it moves by itself: a slow, even glide.
    private static var slide: Animation { .easeInOut(duration: 0.6) }

    /// The slide when the remote turns the page (tvOS): the same slow glide as the timer's, so turning a page by hand looks
    /// like the carousel moving by itself. A swipe on iOS keeps its quick spring.
    private static var manualSlide: Animation {
        #if os(tvOS)
        slide
        #else
        swipeSlide
        #endif
    }

    /// The slide after a swipe or tap on a dot. A spring, which starts moving at full speed the instant a finger lifts,
    /// where an ease-in curve would start slowly and feel as if the swipe stalled.
    private static var swipeSlide: Animation { .spring(response: 0.35, dampingFraction: 0.9) }

    #if !os(tvOS)
    private func swipeChanged(_ translation: CGFloat) {
        isDragging = true
        isSwiping = true
        dragOffset = translation
    }

    /// Moves to the next or previous item if the swipe went far enough, or was flicked.
    private func swipeEnded(translation: CGFloat, velocity: CGFloat) {
        guard isDragging else { return }
        isDragging = false
        Task {
            try? await Task.sleep(for: Self.tapSuppressionAfterSwipe)
            isSwiping = false
        }
        let travel = translation + velocity * Self.swipeCoastTime
        withAnimation(Self.swipeSlide) {
            if travel < -width * Self.flickThreshold || translation < -width * Self.dragThreshold {
                virtualIndex += 1
            } else if travel > width * Self.flickThreshold || translation > width * Self.dragThreshold {
                virtualIndex -= 1
            }
            dragOffset = 0
        }
    }
    #endif

    private func advanceAfterWait() async {
        // Back to empty at once, cutting off the fill still running from the last item.
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { progress = 0 }

        guard items.count > 1, !isDragging, !reduceMotion, !voiceOverEnabled else { return }
        withAnimation(.linear(duration: Double(Self.advanceInterval.components.seconds))) { progress = 1 }
        try? await Task.sleep(for: Self.advanceInterval)
        guard !Task.isCancelled else { return }

        // After the last one, back to the first.
        withAnimation(Self.slide) {
            virtualIndex += 1
        }
    }

    /// A page dot that moves to its item when tapped. On tvOS it's only an indicator: a 15-point button would be a
    /// fiddly focus stop, and the Siri Remote changes pages from the hero's buttons instead.
    @ViewBuilder
    private func dotButton<Label: View>(_ position: Int, @ViewBuilder label: () -> Label) -> some View {
        #if os(tvOS)
        label()
        #else
        Button {
            withAnimation(Self.swipeSlide) { virtualIndex += steps(to: position) }
        } label: {
            label()
        }
        .buttonStyle(.plain)
        #endif
    }

    /// The most dots shown at once on tvOS. With more items than this, the dots are a window that follows the one showing.
    private static var maxVisibleDots: Int { 8 }

    /// The positions that get a dot: all of them, except on tvOS with more items than `maxVisibleDots`, where it's a
    /// window around the one showing, so the row never grows wider than the pill that holds it.
    private var visiblePositions: [Int] {
        #if os(tvOS)
        CarouselMath.visiblePositions(index: index, count: items.count, maxVisible: Self.maxVisibleDots)
        #else
        Array(items.indices)
        #endif
    }

    /// How much a dot is shrunk. The last dot or two in a window that has more items past it get smaller toward the edge,
    /// which says there's more beyond.
    private func dotScale(_ position: Int) -> CGFloat {
        #if os(tvOS)
        guard let first = visiblePositions.first, let last = visiblePositions.last else { return 1 }
        if first > 0 {
            if position == first { return 0.5 }
            if position == first + 1 { return 0.78 }
        }
        if last < items.count - 1 {
            if position == last { return 0.5 }
            if position == last - 1 { return 0.78 }
        }
        return 1
        #else
        return 1
        #endif
    }

    private var pageDots: some View {
        HStack(spacing: 0) {
            ForEach(visiblePositions, id: \.self) { position in
                let isSelected = position == index
                dotButton(position) {
                    // The one showing stretches into a pill that fills as its time runs out, like the Apple TV app's.
                    Capsule()
                        .fill(Color.white.opacity(0.3))
                        .frame(width: isSelected ? Self.selectedDotWidth : 8, height: 8)
                        .overlay(alignment: .leading) {
                            if isSelected {
                                // Square-ended and clipped to the pill, so it never pokes out at the start.
                                // Scaled rather than resized, so the countdown's 15 seconds of animation never causes a layout
                                // pass; it's only a transform.
                                Rectangle()
                                    .fill(dotColor)
                                    .frame(width: Self.selectedDotWidth)
                                    .scaleEffect(x: progress, anchor: .leading)
                            }
                        }
                        .clipShape(Capsule())
                        // On tvOS, the dots at the ends shrink when there are more past them.
                        .scaleEffect(dotScale(position))
                        // A bigger target than the dot itself.
                        .padding(.horizontal, 3.5)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
            }
        }
        #if os(tvOS)
        // On a blurred, darkened pill, as in the Apple TV app, so the dots read over any artwork.
        .padding(.horizontal, 14)
        .padding(.vertical, 2)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().fill(.black.opacity(0.3)))
        }
        #endif
        .animation(.easeInOut(duration: 0.25), value: index)
        .padding(.bottom, 4 + HeroLayout.dotsLift)
        .environment(\.colorScheme, .dark)
        // One element for VoiceOver, which swipes up and down to move between the items.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Featured")
        .accessibilityValue(items.indices.contains(index) ? "\(items[index].title), \(index + 1) of \(items.count)" : "")
        .accessibilityAdjustableAction { direction in
            guard !items.isEmpty else { return }
            switch direction {
            case .increment: virtualIndex += 1
            case .decrement: virtualIndex -= 1
            @unknown default: break
            }
        }
    }
}

/// One item's hero: its artwork under a fade, with its logo, what it is, and a Play button over the bottom-left corner.
private struct HeroPage: View, Equatable {
    /// Compares what the page shows, not its closures, which can't be compared and are new on every redraw. That's safe
    /// because they only reach state through the carousel's `@State`, which is the same storage however often they're
    /// remade. A closure that captured a changing value would need to be part of this comparison.
    static func == (lhs: HeroPage, rhs: HeroPage) -> Bool {
        lhs.item == rhs.item && lhs.playTarget == rhs.playTarget && lhs.safeArea == rhs.safeArea && lhs.accent == rhs.accent
    }

    let item: MediaItem

    /// What Play plays, or nil if there's nothing to play.
    let playTarget: MediaItem?

    let safeArea: EdgeInsets

    /// The theme's color while one is showing, which the fade over the artwork leans toward.
    let accent: Color?

    let open: (MediaItem) -> Void
    let play: (MediaItem) -> Void

    var body: some View {
        Color.black
            .overlay {
                CachedAsyncImage(url: item.backdropURL ?? item.posterURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    }
                }
                .allowsHitTesting(false)
            }
            .clipped()
            .overlay {
                LinearGradient(
                    stops: [
                        // Darkest at the top, behind the page's heading, then clear over the artwork.
                        .init(color: .black.opacity(0.4), location: 0),
                        .init(color: .black.opacity(0), location: 0.2),
                        .init(color: .black.opacity(0), location: 0.5),
                        .init(color: Color.themedBlack(accent).opacity(0.55), location: 0.75),
                        .init(color: Color.themedBlack(accent).opacity(0.85), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            #if os(tvOS)
            // Darker on the side the text is on, fading out toward the other, so the text reads over any artwork.
            .overlay {
                LinearGradient(
                    colors: [.black.opacity(0.6), .black.opacity(0.25), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
            #else
            // Tapping the artwork opens the item. The buttons over it take their own taps. (On tvOS a screen-sized
            // button would be a focus stop of its own, so the More Info button does this instead.)
            .overlay {
                Button { open(item) } label: { Color.clear.contentShape(Rectangle()) }
                    .cardLinkStyle()
                    .accessibilityLabel(item.accessibilityDescription)
                    .accessibilityHint("Opens the details")
            }
            #endif
            #if !os(tvOS)
            // On tvOS the text isn't part of the page: it belongs to the carousel, which fades it between items.
            .overlay(alignment: .bottomLeading) {
                HeroDetails(item: item, playTarget: playTarget, safeArea: safeArea, play: play)
            }
            #endif
    }
}

/// What's written over a hero's artwork: its logo, what it is, a short description and, on iOS, a Play button. On tvOS the
/// carousel shows one of these over the artwork, rather than each page carrying its own, so it can fade between items
/// while the artwork slides.
private struct HeroDetails: View {
    let item: MediaItem
    let playTarget: MediaItem?
    let safeArea: EdgeInsets
    let play: (MediaItem) -> Void

    /// e.g. "TV Show · Crime · Thriller": what kind of thing it is, then its first genres.
    private var kindLine: String {
        var parts: [String] = []
        switch item.kind {
        case .movie: parts.append(String(localized: "Movie"))
        case .series: parts.append(String(localized: "TV Show"))
        default: break
        }
        parts.append(contentsOf: item.genres.prefix(2))
        return parts.joined(separator: " · ")
    }

    /// The logo's size cap. On tvOS it's smaller than the item pages' logos, to match the Apple TV app's carousel.
    private static var logoSize: CGSize? {
        #if os(tvOS)
        CGSize(width: 440, height: 150)
        #else
        nil
        #endif
    }

    /// The genre line and the content rating beside it: about 30 points on tvOS, as in the Apple TV app.
    private static var kindFont: Font {
        #if os(tvOS)
        // About 22 points, measured from the Apple TV app. The tvOS text styles don't go this small.
        .system(size: 22, weight: .medium)
        #else
        .title3
        #endif
    }

    private static var ratingFont: Font {
        #if os(tvOS)
        .system(size: 16, weight: .semibold)
        #else
        .subheadline.weight(.semibold)
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ShowLogo(item: item, maxSizeOverride: Self.logoSize)

            // Left out when there's nothing to say, so it doesn't leave a gap between the title and the buttons.
            if !kindLine.isEmpty || item.officialRating != nil {
                HStack(spacing: 10) {
                    if !kindLine.isEmpty {
                        Text(kindLine)
                            .font(Self.kindFont)
                    }
                    if let rating = item.officialRating {
                        Text(rating)
                            .font(Self.ratingFont)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.white, lineWidth: 1.5) }
                    }
                }
            }

            #if os(tvOS)
            // A short description under the genres, as in the Apple TV app.
            if let overview = item.overview {
                Text(overview)
                    // Lighter and smaller than the genre line above it, and dimmer, so the two read as different things.
                    .font(.system(size: 21))
                    .foregroundStyle(.white.opacity(0.7))
                    // A TV has the room: four lines of it, across more of the screen.
                    .lineLimit(4)
                    .frame(maxWidth: 1100, alignment: .leading)
            }

            #else
            HStack(spacing: 12) {
                if let playTarget {
                    Button { play(playTarget) } label: {
                        Label(playTarget.playButtonTitle(forShow: item.kind == .series), systemImage: "play.fill")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.black)
                            // As wide as its text ("Play First Episode" is longer than "Play"), and no narrower than a
                            // short one.
                            .padding(.vertical, 14)
                            .padding(.horizontal, 28)
                            .frame(minWidth: 180)
                            .background(.white, in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
            #endif
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        #if os(tvOS)
        // A soft shadow keeps the text readable over bright artwork.
        .shadow(color: .black.opacity(0.55), radius: 8)
        #endif
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Layout.contentInset)
        .padding(.leading, safeArea.leading)
        .padding(.trailing, safeArea.trailing)
        // Leaves room for the page dots.
        .padding(.bottom, 44 + HeroLayout.bottomReserve + HeroLayout.textLift)
    }
}

#Preview {
    HomeHeroCarousel(items: [.previewMovie, .previewSeries, .previewWatched], playTargets: [MediaItem.previewMovie.id: .previewMovie], safeArea: EdgeInsets(top: 59, leading: 0, bottom: 0, trailing: 0), screenSize: CGSize(width: 400, height: 800), open: { _ in }, play: { _ in }) {
        Text("Home").font(.largeTitle.bold()).foregroundStyle(.white)
    }
}
