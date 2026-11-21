// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(iOS)
import AVKit
import SwiftUI

// The pieces of the iOS player's controls that stand on their own: the transport button style, the progress and
// scrub bars, the end-time label, the scrolling title, and the preview host.

/// A button that shrinks and dims while pressed.
struct TransportButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.85 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

/// The elapsed and remaining times either side of the progress bar.
struct PlayerProgressRow: View {
    let model: PlayerControlsModel
    @Binding var scrubFraction: Double?
    let onBegin: () -> Void
    let onChange: (Double) -> Void
    let onEnd: (Double) -> Void

    var body: some View {
        let shown = scrubFraction.map { $0 * model.duration } ?? model.currentTime
        let remaining = max(0, model.duration - shown)

        HStack(spacing: 10) {
            Text(PlayerControlsView.clock(shown))
            ScrubBar(
                fraction: model.duration > 0 ? model.currentTime / model.duration : 0,
                buffered: model.duration > 0 ? model.bufferedTime / model.duration : 0,
                scrubFraction: $scrubFraction,
                onBegin: onBegin,
                onChange: onChange,
                onEnd: onEnd
            )
            Text("−\(PlayerControlsView.clock(remaining))")
        }
        .font(.footnote.monospacedDigit().weight(.medium))
        // The bar needs room between the times, and they're one line, so they stop growing before they'd be cut.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .foregroundStyle(.white.opacity(0.9))
        .lineLimit(1)
    }
}

/// When the video finishes if it plays on from here.
struct PlayerEndTime: View {
    let model: PlayerControlsModel
    let scrubFraction: Double?

    var body: some View {
        let end = Date.now + max(0, model.duration - (scrubFraction.map { $0 * model.duration } ?? model.currentTime))
        Text("Ends \(end.formatted(date: .omitted, time: .shortened))")
            .font(.footnote.monospacedDigit().weight(.medium))
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .secondaryPlayerText()
            .lineLimit(1)
            .fixedSize()
    }
}

/// One line of text that, when it's too long for its space, scrolls sideways to show the rest, as a song's title does in
/// Music: it waits at its start, scrolls until its start comes round again, and repeats. It takes no more room than the
/// line cut off would, so the views beside it stay put. With Reduce Motion on, it's cut off instead.
struct MarqueeText: View {
    let text: String

    /// Whether it scrolls. Off while it can't be seen; turned back on, it carries on from where it stopped, so text
    /// that's only briefly on screen at a time (the player's controls hide after a few seconds) still gets through.
    var isAnimating = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The width of the line as laid out (cut off, if it's too long), and of all of it.
    @State private var shownWidth: CGFloat = 0
    @State private var fullWidth: CGFloat = 0

    /// How long it had been animating when it last stopped, and when it started again since.
    @State private var elapsedBeforePause: TimeInterval = 0
    @State private var resumedAt = Date.now

    /// The space between the end of the text and its start coming round again.
    private static let gap: CGFloat = 40
    /// Points a second.
    private static let speed: CGFloat = 30
    /// How long it rests at its start before each scroll.
    private static let pause: TimeInterval = 1.5
    /// How far the edges fade out, so the text doesn't stop at a hard line.
    private static let fadeWidth: CGFloat = 12

    /// Half a point of slack absorbs rounding.
    private var scrolls: Bool { !reduceMotion && shownWidth > 0 && fullWidth > shownWidth + 0.5 }

    var body: some View {
        Text(text)
            .lineLimit(1)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { shownWidth = $0 }
            .background(alignment: .leading) {
                // All of it on one line, only to measure it.
                Text(text)
                    .fixedSize()
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { fullWidth = $0 }
            }
            // The cut-off line still sets the size; when it scrolls, the moving copy shows in its place.
            .opacity(scrolls ? 0 : 1)
            .overlay(alignment: .leading) {
                if scrolls {
                    TimelineView(.animation(paused: !isAnimating)) { context in
                        let offset = offset(at: context.date)
                        HStack(spacing: Self.gap) {
                            Text(text)
                            Text(text)
                        }
                        .fixedSize()
                        .offset(x: offset)
                        .frame(width: shownWidth, alignment: .leading)
                        .mask { fadeMask(isMoving: offset < 0) }
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(text))
            // A new title starts from the beginning.
            .onChange(of: text) {
                elapsedBeforePause = 0
                resumedAt = .now
            }
            .onChange(of: isAnimating) {
                if isAnimating {
                    resumedAt = .now
                } else {
                    elapsedBeforePause += Date.now.timeIntervalSince(resumedAt)
                }
            }
    }

    /// How far left the text is at `date`: still for the pause, then moving until the second copy is where the first
    /// began, which looks the same as the start, so it starts again from there.
    private func offset(at date: Date) -> CGFloat {
        let distance = fullWidth + Self.gap
        let period = Self.pause + distance / Self.speed
        let animated = elapsedBeforePause + max(0, date.timeIntervalSince(resumedAt))
        let elapsed = animated.truncatingRemainder(dividingBy: period)
        return elapsed < Self.pause ? 0 : -CGFloat(elapsed - Self.pause) * Self.speed
    }

    /// The trailing edge always fades, where the text runs on; the leading edge only while it moves, so the first
    /// letters are whole while it rests.
    private func fadeMask(isMoving: Bool) -> some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [isMoving ? .clear : .black, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: Self.fadeWidth)
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: Self.fadeWidth)
        }
    }
}

/// A draggable progress bar. Like the system one, dragging moves the position by how far the finger travels
/// rather than jumping to where it lands, and the further the finger strays above or below the bar, the finer
/// the control.
struct ScrubBar: View {
    let fraction: Double
    /// How much has loaded, from 0 to 1. Shaded between the empty track and the played part.
    let buffered: Double
    @Binding var scrubFraction: Double?
    let onBegin: () -> Void
    let onChange: (Double) -> Void
    let onEnd: (Double) -> Void

    @Environment(\.colorSchemeContrast) private var contrast

    /// The finger's last horizontal position, while dragging.
    @State private var lastX: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            let value = min(max(scrubFraction ?? fraction, 0), 1)

            let barHeight: CGFloat = scrubFraction == nil ? 6 : 12

            ZStack(alignment: .leading) {
                Color.white.opacity(contrast == .increased ? 0.5 : 0.3)
                Color.white.opacity(contrast == .increased ? 0.7 : 0.35).frame(width: proxy.size.width * min(max(buffered, 0), 1))
                // Square-ended and clipped to the track, like the home carousel's page pill, so it sweeps across the
                // rounded ends instead of squashing into a shape of its own.
                Color.white.frame(width: proxy.size.width * value)
            }
            .clipShape(.capsule)
            .frame(height: barHeight)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let current = scrubFraction ?? fraction
                        if scrubFraction == nil {
                            lastX = drag.startLocation.x
                            onBegin()
                        }
                        let distance = drag.location.x - (lastX ?? drag.location.x)
                        lastX = drag.location.x

                        let drift = abs(drag.location.y - proxy.size.height / 2)
                        let rate: Double = switch drift {
                        case ..<60: 1
                        case ..<120: 0.5
                        case ..<180: 0.25
                        default: 0.1
                        }
                        let next = min(max(current + distance / max(proxy.size.width, 1) * rate, 0), 1)
                        scrubFraction = next
                        onChange(next)
                    }
                    .onEnded { _ in
                        onEnd(scrubFraction ?? fraction)
                        scrubFraction = nil
                        lastX = nil
                    }
            )
            .animation(.easeOut(duration: 0.15), value: scrubFraction == nil)
        }
        .frame(height: 28)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
        .accessibilityAdjustableAction { direction in
            onEnd(min(max(fraction + (direction == .increment ? 0.02 : -0.02), 0), 1))
        }
    }
}

/// Lays the controls out against the device the preview runs on, measured the way the player does, over a bright
/// backdrop, so the white text is judged against the worst case. Used by the previews below.
private struct ControlsPreviewHost: View {
    let item: MediaItem
    let session: PlaybackSession
    let model: PlayerControlsModel
    var initialPanel: PlayerControlsView.Panel?

    @State private var screen = PlayerScreen()

    var body: some View {
        ZStack {
            LinearGradient(colors: [.white, .gray.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            Color.clear
                .onGeometryChange(for: PlayerScreen.Shape.self) { proxy in
                    PlayerScreen.Shape(size: proxy.size, corners: proxy.containerCornerInsets)
                } action: { screen.update($0) }
                .ignoresSafeArea()
            PlayerControlsView(item: item, session: session, model: model, screen: screen, initialPanel: initialPanel) {}
        }
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { screen.safeArea = $0 }
        .environment(AppModel.preview())
    }

    static func make(
        item: MediaItem = .previewEpisode,
        position: TimeInterval = 600,
        nextEpisode: MediaItem? = nil,
        segments: [MediaSegment] = [],
        panel: PlayerControlsView.Panel? = nil
    ) -> some View {
        let session = PlaybackSession(
            item: item,
            info: PlaybackInfo(
                url: URL(filePath: "/dev/null"),
                resumePosition: 0,
                playSessionID: nil,
                mediaSourceID: nil,
                method: .transcode,
                audioTracks: [
                    MediaTrack(index: 1, title: "English - AAC - Stereo", isExternal: false),
                    MediaTrack(index: 2, title: "English - Commentary", isExternal: false)
                ],
                subtitleTracks: [MediaTrack(index: 3, title: "English - SRT", isExternal: true)],
                audioIndex: 1,
                sourceBitrate: 20_000_000,
                sourceHeight: 1080
            ),
            service: MockMediaService(),
            settings: .preview()
        )
        session.setPreview(nextEpisode: nextEpisode, segments: segments)
        let model = PlayerControlsModel(player: AVPlayer(), runtime: 1500)
        model.setPreviewPosition(position)
        return ControlsPreviewHost(item: item, session: session, model: model, initialPanel: panel)
    }
}

#Preview("Controls") {
    ControlsPreviewHost.make()
}

#Preview("Info panel") {
    ControlsPreviewHost.make(panel: .info)
}

#Preview("Cast panel") {
    ControlsPreviewHost.make(panel: .cast)
}

#Preview("Up Next") {
    ControlsPreviewHost.make(position: 1470, nextEpisode: .previewEpisode)
}

#Preview("Skip Intro") {
    ControlsPreviewHost.make(position: 30, segments: [MediaSegment(kind: .intro, start: 10, end: 80)])
}
#endif
