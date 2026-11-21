// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// A bucket narrower at the bottom.
nonisolated private struct BucketShape: Shape {
    func path(in r: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: r.minX, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX - r.width * 0.12, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX + r.width * 0.12, y: r.maxY))
        path.closeSubpath()
        return path
    }
}

/// A red-and-white striped popcorn bucket, heaped with popcorn.
struct PopcornBucket: View {
    var body: some View {
        GeometryReader { proxy in
            let (w, h) = (proxy.size.width, proxy.size.height)
            ZStack {
                // The heap.
                ForEach(Array([(0.25, 0.3), (0.5, 0.2), (0.75, 0.3), (0.38, 0.38), (0.62, 0.38)].enumerated()), id: \.offset) { _, puff in
                    Circle()
                        .fill(Color(red: 1.0, green: 0.96, blue: 0.84))
                        .overlay { Circle().strokeBorder(.black.opacity(0.15), lineWidth: max(w * 0.015, 0.5)) }
                        .frame(width: w * 0.36, height: w * 0.36)
                        .position(x: w * puff.0, y: h * puff.1)
                }
                // The bucket.
                BucketShape()
                    .fill(.white)
                    .overlay {
                        HStack(spacing: 0) {
                            ForEach(0..<6, id: \.self) { stripe in
                                Rectangle().fill(stripe.isMultiple(of: 2) ? Color(red: 0.85, green: 0.15, blue: 0.18) : .white)
                            }
                        }
                        .clipShape(BucketShape())
                    }
                    .overlay { BucketShape().stroke(.black.opacity(0.2), lineWidth: max(w * 0.02, 0.5)) }
                    .frame(width: w * 0.8, height: h * 0.55)
                    .position(x: w / 2, y: h * 0.7)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

private struct SupporterBadgeModifier: ViewModifier {
    /// The size of the picture it's on, which the badge is a third of.
    let size: CGFloat
    @Environment(AppModel.self) private var appModel

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottomTrailing) {
            if appModel.support.displaysBadge {
                PopcornBucket()
                    .padding(size * 0.04)
                    .frame(width: size * 0.38, height: size * 0.38)
                    .background(.background, in: .circle)
                    .overlay { Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 1) }
                    // Out past the edge a little, like a badge.
                    .offset(x: size * 0.04, y: size * 0.04)
            }
        }
    }
}

extension View {
    /// Puts the supporter's popcorn-bucket badge on the corner of a profile picture `size` points across, if the user
    /// has tipped and hasn't hidden it.
    func supporterBadge(size: CGFloat) -> some View {
        modifier(SupporterBadgeModifier(size: size))
    }
}

#Preview {
    AvatarView(url: nil, size: 120)
        .supporterBadge(size: 120)
        .environment(AppModel.preview())
        .padding()
}
