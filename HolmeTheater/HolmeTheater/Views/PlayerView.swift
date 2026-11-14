// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AVKit
import OSLog
import SwiftUI

/// Full-screen AVPlayer for one item: custom controls on iOS, the system player on tvOS.
struct PlayerView: View {
    let item: MediaItem

    /// What to play after `item`, in order, when it's one of a list such as a playlist: `item` first, then the items that
    /// follow it. Empty for an item that plays on its own, which is followed by the next episode of its show.
    var queue: [MediaItem] = []

    /// Called after the player closes, once the server has been told where playback stopped, so the presenter
    /// can refresh and show the latest progress.
    var onStop: () -> Void = {}

    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    /// Created once the server has said how to play the item; nil while loading or after an error.
    @State private var session: PlaybackSession?
    @State private var errorMessage: String?
    /// The episode playing after "Up Next" moved on from the one this view was opened with. Nil until then.
    @State private var followingItem: MediaItem?
    /// The load of the following episode, so closing the player can cancel it.
    @State private var followingLoad: Task<Void, Never>?
    /// Where `playing` is in ``queue``.
    @State private var queueIndex = 0

    /// What's playing: the item this view was opened with, or the episode that followed it.
    private var playing: MediaItem { followingItem ?? item }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let session {
                #if os(iOS)
                CustomPlayer(item: session.item, session: session, playNext: playNext, close: close)
                    // A new session is a new player: its own model, controls and clock.
                    .id(ObjectIdentifier(session))
                #else
                TVPlayerController(
                    session: session,
                    service: appModel.service,
                    playNext: playNext,
                    // Closes the player, then the tab that's showing opens the page, as "Go to Show" does on iOS.
                    openItem: { item in
                        appModel.pendingShow = item
                        close()
                    },
                    close: close
                )
                    // A new session is a new player controller, with its own menus and subtitles.
                    .id(ObjectIdentifier(session))
                    .ignoresSafeArea()
                #endif
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Can't Play", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Close") { dismiss() }
                }
                .foregroundStyle(.white)
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        // SwiftUI can rebuild this view, or run `task`, `onAppear` and `onDisappear` again, when the window
        // changes shape (rotation, a foldable opening or closing, split view). So the session lives in the app
        // model, a rebuilt player picks the same one up, and it only stops when the player closes for real.
        .task { await load() }
        .onAppear { session?.viewerAppeared() }
        .onDisappear {
            followingLoad?.cancel()
            session?.viewerDisappeared()
        }
        #if os(iOS)
        // An item that plays to its end with no episode to follow it, or whose autoplay was cancelled, closes the player and
        // leaves the page it was opened from. (tvOS does this in its own controller.) One with a next episode moves on
        // through the Up Next card.
        .task(id: session.map { ObjectIdentifier($0) }) {
            guard let session else { return }
            for await note in NotificationCenter.default.notifications(named: AVPlayerItem.didPlayToEndTimeNotification) {
                guard let finished = note.object as? AVPlayerItem, finished === session.player.currentItem else { continue }
                if session.nextEpisode == nil || session.autoPlayCancelled { close() }
                return
            }
        }
        #endif
    }

    /// Picks up the item's playback if it's already going, or asks the server how to play it and starts.
    private func load() async {
        guard session == nil else { return }

        if let current = appModel.playback, !current.isStopped {
            // The session this view started, even if "Up Next" has since moved it on to the following episode.
            if current.originID == item.id {
                current.onStop = onStop
                session = current
                current.viewerAppeared()
                return
            }
            current.stop(then: current.onStop)
        }

        do {
            let info = try await appModel.service.playbackInfo(for: playing, options: PlaybackOptions())
            // Dismissed while the server was thinking.
            guard !Task.isCancelled else { return }
            let session = PlaybackSession(
                item: playing,
                info: info,
                service: appModel.service,
                settings: appModel.playbackSettings,
                queue: queue.isEmpty ? nil : .init(next: queue.indices.contains(queueIndex + 1) ? queue[queueIndex + 1] : nil)
            )
            session.originID = item.id
            session.onStop = onStop
            appModel.playback = session
            self.session = session
            session.viewerAppeared()
            await session.start()
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Finishes this episode and starts the next one in the same player. Moving on means the episode was watched, so
    /// it's marked played, not left at the position where playback stopped.
    private func playNext(_ next: MediaItem) {
        guard let finished = session else { return }
        let (service, onStop) = (appModel.service, onStop)
        // After the server has the final position, so marking it played isn't undone by that report.
        finished.stop {
            Task {
                try? await service.markWatched(itemID: finished.item.id)
                onStop()
            }
        }
        session = nil
        errorMessage = nil
        if !queue.isEmpty { queueIndex += 1 }
        followingItem = next
        followingLoad = Task { await load() }
    }

    private func close() {
        followingLoad?.cancel()
        session?.stop(then: onStop)
        dismiss()
    }
}

#if os(iOS)
/// The video with the app's own controls on top.
private struct CustomPlayer: View {
    let item: MediaItem
    let session: PlaybackSession
    let playNext: (MediaItem) -> Void
    let close: () -> Void

    @State private var model: PlayerControlsModel
    /// What the picture is laid out against, and what the controls are. The same screen, except when iPhone Duo is
    /// partially folded and the two sit in separate halves.
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var videoScreen = PlayerScreen()
    @State private var controlsScreen = PlayerScreen()
    /// Whether the display is partially folded, as iPhone Duo is in laptop view: the picture and subtitles are
    /// above the fold and every control below it.
    @State private var isFolded = false
    /// While pinching: how far the picture is between fitted (0) and filling the screen (1), following the fingers.
    @State private var pinchProgress: CGFloat?

    init(item: MediaItem, session: PlaybackSession, playNext: @escaping (MediaItem) -> Void, close: @escaping () -> Void) {
        self.item = item
        self.session = session
        self.playNext = playNext
        self.close = close
        _model = State(initialValue: PlayerControlsModel(player: session.player, runtime: item.runtime))
    }

    var body: some View {
        layout
            // Pinch out to fill the screen, pinch in to fit the video back inside it. The picture follows the
            // fingers, then springs to whichever it's nearer, or the way the pinch was heading if it was quick.
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        let range = fillScale - 1
                        guard range > 0.01 else { return }
                        let startScale = model.fillsScreen ? fillScale : 1
                        pinchProgress = Self.rubberBand((startScale * value.magnification - 1) / range)
                    }
                    .onEnded { value in
                        guard let progress = pinchProgress else { return }
                        let projected = progress + value.velocity * 0.15 / (fillScale - 1)
                        withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                            pinchProgress = nil
                            model.setFillsScreen(projected > 0.5)
                        }
                    }
            )
            .onAppear { model.start() }
            .onDisappear { model.stop() }
    }

    @ViewBuilder
    private var layout: some View {
        if #available(iOS 27.1, *) {
            // Flat, the controls are layered over the video. Partially folded, the system puts the video in one half
            // and the controls in the other: above and below the fold in laptop view, side by side like a book.
            ArrangementView {
                controlsLayer
            } secondary: {
                videoLayer
            }
            .arrangementViewStyle(.overlay)
            .onGeometryChange(for: Bool.self) { !$0.reservedRegions(kind: .division).isEmpty } action: { isFolded = $0 }
        } else {
            ZStack {
                videoLayer
                controlsLayer
            }
        }
    }

    private var controlsLayer: some View {
        ZStack {
            // Measured the same way as the picture's screen, so the controls lay out against their own region.
            Color.clear
                .onGeometryChange(for: PlayerScreen.Shape.self) { proxy in
                    PlayerScreen.Shape(size: proxy.size, corners: proxy.containerCornerInsets)
                } action: { controlsScreen.update($0) }
                .ignoresSafeArea(edges: isFolded ? [] : .all)
            PlayerControlsView(item: item, session: session, model: model, screen: controlsScreen, isFolded: isFolded, playNext: playNext, close: close)
        }
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { controlsScreen.safeArea = $0 }
    }

    private var videoLayer: some View {
        ZStack {
            video
            SubtitleOverlay(session: session, model: model, frame: pictureFrame)
            timingPanel
            // Folded, the skip button and "Up Next" card go over the picture, bottom trailing, rather than in the
            // controls' half. They're never both showing.
            if isFolded {
                ZStack {
                    SkipSegmentButton(session: session, model: model)
                    NextEpisodeOverlay(session: session, model: model, play: playNext)
                }
                    // What the controls give them when they're in their half: white text, and dark materials.
                    .foregroundStyle(.white)
                    .environment(\.colorScheme, .dark)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(16)
                    .frame(width: pictureFrame.width, height: pictureFrame.height)
                    .position(x: pictureFrame.midX, y: pictureFrame.midY)
            }
        }
        // Folded, the picture is in its own half with the controls in the other, so tapping it toggles them.
        // Flat, the controls layer covers the picture and takes the tap itself.
        .contentShape(Rectangle())
        .onTapGesture { if isFolded { model.tapPicture() } }
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { videoScreen.safeArea = $0 }
    }

    /// The panel for adjusting the subtitles' timing, in the middle of the picture. The controls are cleared away
    /// while it's open, so this has the picture to itself.
    private var timingPanel: some View {
        Color.clear
            .overlay(alignment: .topLeading) {
                if model.showsTiming && !isFolded {
                    SubtitleTimingPanel(session: session, touch: {}) { model.showsTiming = false }
                        .frame(maxWidth: min(440, max(0, pictureFrame.width - 32)))
                        .position(x: pictureFrame.midX, y: pictureFrame.midY)
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.25), value: model.showsTiming)
            .ignoresSafeArea()
    }

    /// The picture, centred on the whole of its region. Fitted, it's as big as it can be while keeping clear of the
    /// camera; zoomed to fill, it runs edge to edge.
    private var video: some View {
        Color.clear
            .overlay(alignment: .topLeading) {
                surface(bindsPictureInPicture: true, in: .zero)
            }
            // With a panel open, the lower part of the picture blurs: a second copy of the video, blurred and
            // masked to start just below the panel buttons.
            .overlay(alignment: .topLeading) {
                if let top = model.blurTop {
                    let frame = pictureFrame
                    Color.clear
                        .frame(width: frame.width, height: frame.height)
                        .overlay(alignment: .topLeading) { surface(bindsPictureInPicture: false, in: frame) }
                        .clipped()
                        .blur(radius: 14, opaque: true)
                        // With Increase Contrast or Reduce Transparency on, darken it so the white text over it reads.
                        .overlay(Color.black.opacity(contrast == .increased || reduceTransparency ? 0.5 : 0))
                        .mask {
                            // A long, soft fade into the blur rather than a hard edge.
                            VStack(spacing: 0) {
                                Color.clear.frame(height: max(0, top - frame.minY - 40))
                                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                                    .frame(height: 80)
                                Color.black
                            }
                        }
                        .offset(x: frame.minX, y: frame.minY)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .animation(.smooth(duration: 0.3), value: model.blurTop == nil)
            // Zoomed, the picture runs past its region; folded, it would otherwise spill into the controls' half.
            .clipped()
            // Measured and laid out inside `ignoresSafeArea`, so against the whole region. (Outside it, the
            // view still reports the safe area's frame.)
            .onGeometryChange(for: PlayerScreen.Shape.self) { proxy in
                PlayerScreen.Shape(size: proxy.size, corners: proxy.containerCornerInsets)
            } action: { videoScreen.update($0, statusBarShown: model.statusBarShown) }
            .ignoresSafeArea()
    }

    /// The video, laid out at its fitted size and scaled up to the zoom. Scaling, rather than resizing the layer or
    /// switching its gravity, is what lets the zoom follow a pinch and animate smoothly.
    /// - Parameter container: The frame, on the screen, of the view this is placed in, from its top leading corner.
    private func surface(bindsPictureInPicture: Bool, in container: CGRect) -> some View {
        let fitted = fittedFrame
        let shown = displayedFrame
        return PlayerSurface(model: model, bindsPictureInPicture: bindsPictureInPicture)
            .frame(width: fitted.width, height: fitted.height)
            .scaleEffect(fitted.width > 0 ? shown.width / fitted.width : 1)
            .offset(x: shown.midX - fitted.width / 2 - container.minX, y: shown.midY - fitted.height / 2 - container.minY)
    }

    /// How far the picture is between fitted (0) and filling the screen (1); a little past either end while a
    /// pinch overshoots.
    private var zoomProgress: CGFloat { pinchProgress ?? (model.fillsScreen ? 1 : 0) }

    /// Where the picture is when it fits: as big as it can be while keeping clear of the camera.
    private var fittedFrame: CGRect {
        // Folded, the picture has a half to itself with nothing in it to keep clear of: no safe area applies.
        isFolded
            ? videoScreen.unobstructedPictureFrame(aspectRatio: aspectRatio)
            : videoScreen.pictureFrame(aspectRatio: aspectRatio)
    }

    /// How much the fitted picture is scaled up to fill the screen, centred on it.
    private var fillScale: CGFloat {
        let fitted = fittedFrame
        guard fitted.width > 0, fitted.height > 0 else { return 1 }
        return max(1, videoScreen.size.width / fitted.width, videoScreen.size.height / fitted.height)
    }

    /// The whole picture as drawn at the current zoom, including any part cropped off the screen.
    private var displayedFrame: CGRect {
        let fitted = fittedFrame
        let progress = zoomProgress
        let scale = 1 + (fillScale - 1) * progress
        let size = CGSize(width: fitted.width * scale, height: fitted.height * scale)
        let center = CGPoint(
            x: fitted.midX + (videoScreen.size.width / 2 - fitted.midX) * progress,
            y: fitted.midY + (videoScreen.size.height / 2 - fitted.midY) * progress
        )
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    /// Where the picture can be seen on the screen, for laying out what goes over it: all of the screen when
    /// zoomed to fill, otherwise as big as it fits.
    private var pictureFrame: CGRect {
        let visible = displayedFrame.intersection(CGRect(origin: .zero, size: videoScreen.size))
        return visible.isNull ? fittedFrame : visible
    }

    /// Lets a pinch carry on a little past fitted or filled, with growing resistance, rather than stopping dead.
    private static func rubberBand(_ progress: CGFloat) -> CGFloat {
        let limit: CGFloat = 0.12
        func band(_ over: CGFloat) -> CGFloat { limit * (1 - 1 / (1 + over / limit / 3)) }
        if progress > 1 { return 1 + band(progress - 1) }
        if progress < 0 { return -band(-progress) }
        return progress
    }

    /// The picture's width over its height; widescreen until the stream reports its size.
    private var aspectRatio: CGFloat {
        let size = model.videoSize
        return size.width > 0 && size.height > 0 ? size.width / size.height : 16 / 9
    }
}
#endif

#Preview {
    PlayerView(item: .previewPartlyWatched)
        .environment(AppModel.preview())
}
