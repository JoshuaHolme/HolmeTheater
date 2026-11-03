// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// A row of full-width hero images, one for each of the newest items on the server, that advances by itself.
///
/// It moves to the next item after ``advanceInterval`` and loops back to the first after the last. Touching it, by
/// swiping or tapping a dot, starts the wait over, and it holds still while a finger is dragging it.
///
/// It runs edge to edge, under the status bar and past the side safe areas, with the page's heading over its top.
struct HomeHeroCarousel<Header: View>: View {
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

    /// The page's heading, over the top of the artwork.
    @ViewBuilder let header: () -> Header

    /// How wide the page dot of the item showing is.
    private static var selectedDotWidth: CGFloat { 32 }

    /// How long each item stays up before the next one slides in.
    static var advanceInterval: Duration { .seconds(15) }

    /// The position of the item showing.
    @State private var index = 0

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

    /// Whether one of the carousel's buttons has focus.
    @FocusState private var hasFocus: Bool

    /// Whether the focus holds the carousel still. Only tvOS has focus to hold it.
    private var holdsFocus: Bool {
        #if os(tvOS)
        hasFocus
        #else
        false
        #endif
    }

    private var width: CGFloat { screenSize.width }

    /// The carousel's height: tall and nearly poster-shaped on a narrow screen, and no more than most of the screen's
    /// height on a wide one. Like the artwork, it runs up under the status bar.
    private var height: CGFloat {
        min(width * 1.25, screenSize.height * 0.82)
    }

    /// How many pages the item at `position` is to the right of the one showing, going the short way around so
    /// the last item sits just left of the first. Zero is the one showing.
    private func offset(of position: Int) -> Int {
        var distance = (position - index) % items.count
        if distance < 0 { distance += items.count }
        return distance > items.count / 2 ? distance - items.count : distance
    }

    var body: some View {
        // Only the page showing and its neighbors exist, each placed by how far it is from the one showing. Moving to
        // another item animates their positions, so the one leaving slides off as the one arriving slides on, and
        // the first slides in after the last the same way as any other.
        ZStack {
            ForEach(Array(items.enumerated()), id: \.element.id) { position, item in
                let distance = offset(of: position)
                if abs(distance) <= 1 {
                    HeroPage(
                        item: item,
                        playTarget: playTargets[item.id],
                        safeArea: safeArea,
                        open: { if !isSwiping { open($0) } },
                        play: { if !isSwiping { play($0) } },
                        step: { delta in
                            guard items.count > 1 else { return }
                            withAnimation(Self.swipeSlide) { index = (index + delta + items.count) % items.count }
                        }
                    )
                    // The closures are new each time this runs, which would redraw every page for every frame of a
                    // drag. See `HeroPage.==` for why comparing without them is safe.
                    .equatable()
                    .frame(width: width, height: height)
                    .offset(x: CGFloat(distance) * width)
                    // The neighbors are only there to slide in; VoiceOver reads the one showing.
                    .accessibilityHidden(distance != 0)
                }
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
        .overlay(alignment: .topLeading) {
            header()
                .padding(.top, safeArea.top + 8)
                .padding(.leading, safeArea.leading)
                .padding(.trailing, safeArea.trailing)
        }
        .overlay(alignment: .bottom) {
            pageDots
        }
        // Full width, so only one page is ever in view and the page dots are centered on the screen. Without this
        // the carousel stops at the side safe areas.
        .ignoresSafeArea(edges: .horizontal)
        // Restarts whenever the item changes, whether it moved by itself or was swiped, and while a finger is down,
        // so the wait is always the full interval from the last touch. Cancelled when the screen goes away.
        // On tvOS, also holds still while a button on it has focus, so the focused button isn't pulled away.
        .focused($hasFocus)
        .task(id: Advance(index: index, isDragging: isDragging, isPaused: reduceMotion || voiceOverEnabled || holdsFocus)) {
            await advanceAfterWait()
        }
        // A reload can bring fewer items; start again from the first rather than point past the end.
        .onChange(of: items.count) { _, count in
            if index >= count { index = 0 }
        }
    }

    /// What the wait depends on: a new value starts it over.
    private struct Advance: Hashable {
        let index: Int
        let isDragging: Bool
        let isPaused: Bool
    }

    /// The slide when it moves by itself: a slow, even glide.
    private static var slide: Animation { .easeInOut(duration: 0.6) }

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
                index = (index + 1) % items.count
            } else if travel > width * Self.flickThreshold || translation > width * Self.dragThreshold {
                index = (index + items.count - 1) % items.count
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

        guard items.count > 1, !isDragging, !reduceMotion, !voiceOverEnabled, !holdsFocus else { return }
        withAnimation(.linear(duration: Double(Self.advanceInterval.components.seconds))) { progress = 1 }
        try? await Task.sleep(for: Self.advanceInterval)
        guard !Task.isCancelled else { return }

        // After the last one, back to the first.
        withAnimation(Self.slide) {
            index = (index + 1) % items.count
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
            withAnimation(Self.swipeSlide) { index = position }
        } label: {
            label()
        }
        .buttonStyle(.plain)
        #endif
    }

    private var pageDots: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { position, _ in
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
                                    .fill(Color.white)
                                    .frame(width: Self.selectedDotWidth)
                                    .scaleEffect(x: progress, anchor: .leading)
                            }
                        }
                        .clipShape(Capsule())
                        // A bigger target than the dot itself.
                        .padding(.horizontal, 3.5)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: index)
        .padding(.bottom, 4)
        .environment(\.colorScheme, .dark)
        // One element for VoiceOver, which swipes up and down to move between the items.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Featured")
        .accessibilityValue(items.indices.contains(index) ? "\(items[index].title), \(index + 1) of \(items.count)" : "")
        .accessibilityAdjustableAction { direction in
            guard !items.isEmpty else { return }
            switch direction {
            case .increment: index = (index + 1) % items.count
            case .decrement: index = (index + items.count - 1) % items.count
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
        lhs.item == rhs.item && lhs.playTarget == rhs.playTarget && lhs.safeArea == rhs.safeArea
    }

    let item: MediaItem

    /// What Play plays, or nil if there's nothing to play.
    let playTarget: MediaItem?

    let safeArea: EdgeInsets
    let open: (MediaItem) -> Void
    let play: (MediaItem) -> Void

    /// Moves the carousel to the next item (1) or the previous (-1), for the Siri Remote.
    let step: (Int) -> Void

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
                        .init(color: .black.opacity(0.55), location: 0.75),
                        .init(color: .black.opacity(0.85), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            #if !os(tvOS)
            // Tapping the artwork opens the item. The buttons over it take their own taps. (On tvOS a screen-sized
            // button would be a focus stop of its own, so the More Info button does this instead.)
            .overlay {
                Button { open(item) } label: { Color.clear.contentShape(Rectangle()) }
                    .cardLinkStyle()
                    .accessibilityLabel(item.accessibilityDescription)
                    .accessibilityHint("Opens the details")
            }
            #endif
            .overlay(alignment: .bottomLeading) { details }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            ShowLogo(item: item)

            // Left out when there's nothing to say, so it doesn't leave a gap between the title and the buttons.
            if !kindLine.isEmpty || item.officialRating != nil {
                HStack(spacing: 10) {
                    if !kindLine.isEmpty {
                        Text(kindLine)
                            .font(.title3)
                    }
                    if let rating = item.officialRating {
                        Text(rating)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.white, lineWidth: 1.5) }
                    }
                }
            }

            #if os(tvOS)
            HStack(spacing: 24) {
                if let playTarget {
                    Button { play(playTarget) } label: {
                        Label(playTarget.playButtonTitle(forShow: item.kind == .series), systemImage: "play.fill")
                            .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                    // At the left edge, moving left goes to the previous item rather than nowhere.
                    .onMoveCommand { if $0 == .left { step(-1) } }
                }

                Button { open(item) } label: {
                    Label("More Info", systemImage: "info.circle")
                        .font(.headline)
                }
                .buttonStyle(.bordered)
                .onMoveCommand { if $0 == .right { step(1) } }
            }
            .padding(.top, 4)
            .tvFocusSection()
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.leading, safeArea.leading)
        .padding(.trailing, safeArea.trailing)
        // Leaves room for the page dots.
        .padding(.bottom, 44)
    }
}

#Preview {
    HomeHeroCarousel(items: [.previewMovie, .previewSeries, .previewWatched], playTargets: [MediaItem.previewMovie.id: .previewMovie], safeArea: EdgeInsets(top: 59, leading: 0, bottom: 0, trailing: 0), screenSize: CGSize(width: 400, height: 800), open: { _ in }, play: { _ in }) {
        Text("Home").font(.largeTitle.bold()).foregroundStyle(.white)
    }
}

#if !os(tvOS)
/// A sideways pan that only begins if the finger moves more across than up or down, and then runs alongside the page's
/// own scrolling. SwiftUI's drag gesture claims every drag that starts on it, vertical ones too, which would stop the
/// page from scrolling when a finger starts on the carousel.
private struct HorizontalPan: UIGestureRecognizerRepresentable {
    /// Called with how far the finger has moved sideways, as it moves.
    let onChanged: (CGFloat) -> Void

    /// Called when the finger lifts, with how far it moved sideways and how fast it was moving, in points per second.
    let onEnded: (_ translation: CGFloat, _ velocity: CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> HorizontalPanGestureRecognizer {
        let recognizer = HorizontalPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: HorizontalPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .began, .changed:
            onChanged(translation)
        case .ended:
            onEnded(translation, recognizer.velocity(in: recognizer.view).x)
        case .cancelled, .failed:
            onEnded(0, 0)
        default:
            break
        }
    }

    /// Lets the pan run at the same time as the page's scrolling.
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

/// A pan that gives up if the finger starts moving more up or down than across.
private final class HorizontalPanGestureRecognizer: UIPanGestureRecognizer {
    private var start: CGPoint?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        start = touches.first?.location(in: view)
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .possible, let start, let point = touches.first?.location(in: view) {
            let across = abs(point.x - start.x)
            let down = abs(point.y - start.y)
            // Decided once the finger has moved a little: a mostly vertical start is a scroll, not a swipe.
            if across + down > 8 {
                if down > across {
                    state = .failed
                    return
                }
            }
        }
        super.touchesMoved(touches, with: event)
    }
}
#endif
