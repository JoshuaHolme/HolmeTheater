// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// The subtitle lines the track puts somewhere other than along the bottom, each where it says, in the same style as
/// the rest. Fills its container, whose top-left corner `frame` is measured from.
struct PlacedSubtitlesView: View {
    let cues: [SubtitleCue]
    /// Where the picture is, which positions are measured on.
    let frame: CGRect
    let fontSize: CGFloat
    /// The wider of the two shadows that keep white text readable on a light picture.
    let shadowRadius: CGFloat

    var body: some View {
        Color.clear
            .overlay(alignment: .topLeading) {
                ForEach(cues, id: \.self) { cue in
                    if let placement = cue.placement { line(cue.text, at: placement) }
                }
            }
    }

    /// The text, with the part of it the placement names on the placement's point. It wraps at most of the picture's
    /// width, as the lines along the bottom do.
    private func line(_ text: String, at placement: SubtitlePlacement) -> some View {
        let box = CGSize(width: frame.width * 0.84, height: frame.height)
        let point = CGPoint(x: frame.minX + placement.x * frame.width, y: frame.minY + placement.y * frame.height)
        return Text(text)
            .font(.system(size: fontSize, weight: .semibold))
            .multilineTextAlignment(textAlignment(placement.horizontal))
            .foregroundStyle(.white)
            .shadow(color: .black, radius: 2)
            .shadow(color: .black, radius: shadowRadius)
            // In a box as big as the text may get, aligned the way the placement says, so that whatever size the text
            // comes out, its named part is at the box's: and the box's is put on the point.
            .frame(width: box.width, height: box.height, alignment: alignment(placement))
            .offset(x: point.x - placement.horizontal.fraction * box.width, y: point.y - placement.vertical.fraction * box.height)
    }

    private func textAlignment(_ anchor: SubtitlePlacement.Anchor) -> TextAlignment {
        switch anchor {
        case .start: .leading
        case .center: .center
        case .end: .trailing
        }
    }

    private func alignment(_ placement: SubtitlePlacement) -> Alignment {
        let horizontal: HorizontalAlignment = switch placement.horizontal {
        case .start: .leading
        case .center: .center
        case .end: .trailing
        }
        let vertical: VerticalAlignment = switch placement.vertical {
        case .start: .top
        case .center: .center
        case .end: .bottom
        }
        return Alignment(horizontal: horizontal, vertical: vertical)
    }
}
