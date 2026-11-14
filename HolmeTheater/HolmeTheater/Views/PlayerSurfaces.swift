// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(iOS)
import AVKit
import SwiftUI

// MARK: - Surfaces

/// The video itself, with no controls.
struct PlayerSurface: UIViewRepresentable {
    let model: PlayerControlsModel
    /// Whether Picture in Picture follows this layer. Only the main picture's, not the blurred copy under a panel.
    let bindsPictureInPicture: Bool

    func makeUIView(context: Context) -> SurfaceView {
        let view = SurfaceView()
        view.playerLayer.player = model.player
        view.playerLayer.videoGravity = .resizeAspect
        if bindsPictureInPicture { model.attach(view.playerLayer) }
        return view
    }

    /// Zooming to fill scales this view (see `CustomPlayer`), so the layer always just fits the video to its bounds.
    func updateUIView(_ view: SurfaceView, context: Context) {}

    final class SurfaceView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer } // swiftlint:disable:this force_cast
    }
}

/// The system AirPlay button.
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = .white
        view.prioritizesVideoDevices = true
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

/// The subtitles, drawn over the picture from the player's clock. The player's own HLS subtitles drift out of step
/// with the speech; these follow the position, as in the web client.
///
/// Laid out in the picture's own frame, on the whole screen, so they sit where the video does and don't move
/// when the status bar and controls come and go.
struct SubtitleOverlay: View {
    let session: PlaybackSession
    let model: PlayerControlsModel
    /// Where the picture is on the screen.
    let frame: CGRect

    /// The text size setting, as a factor on the usual size: the subtitles follow it, up to a point.
    @ScaledMetric(relativeTo: .body) private var textScale: CGFloat = 1

    /// The size of the whole screen, which pictures are kept on.
    @State private var screenSize: CGSize = .zero

    private var fontSize: CGFloat { max(14, frame.height * 0.055) * min(textScale, 1.6) }

    var body: some View {
        Color.clear
            .onGeometryChange(for: CGSize.self) { $0.size } action: { screenSize = $0 }
            .overlay(alignment: .topLeading) {
                // A track of pictures is drawn where the picture says, scaled with the video.
                if let picture = session.subtitlePicture(at: model.currentTime) {
                    let rect = picture.rect(onVideo: frame, within: CGRect(origin: .zero, size: screenSize))
                    Image(decorative: picture.image, scale: 1)
                        .resizable()
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
            // Each kind in an overlay of its own: sharing one, the placed lines stopped the others being drawn.
            .overlay(alignment: .topLeading) {
                PlacedSubtitlesView(cues: session.placedSubtitles(at: model.currentTime), frame: frame, fontSize: fontSize, shadowRadius: 4)
            }
            .overlay(alignment: .topLeading) {
                if let text = session.subtitleText(at: model.currentTime) {
                    Text(text)
                        .font(.system(size: fontSize, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .shadow(color: .black, radius: 2)
                        .shadow(color: .black, radius: 4)
                        .padding(.horizontal, frame.width * 0.08)
                        .padding(.bottom, frame.height * 0.06)
                        .frame(width: frame.width, height: frame.height, alignment: .bottom)
                        .offset(x: frame.minX, y: frame.minY)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Dimmed white for secondary text over the picture, and fully white with Increase Contrast on.
struct SecondaryPlayerText: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.foregroundStyle(.white.opacity(contrast == .increased ? 1 : 0.8))
    }
}

extension View {
    func secondaryPlayerText() -> some View { modifier(SecondaryPlayerText()) }
}
#endif
