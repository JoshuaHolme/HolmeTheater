// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// A user's profile picture as a circle, falling back to a generic person icon when there's no URL,
/// while loading, or if the image can't be loaded.
struct AvatarView: View {
    /// The profile picture to load. Nil shows the generic icon.
    let url: URL?

    /// Diameter of the circle.
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
            default:
                Image(systemName: "person.crop.circle")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.primary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

#Preview {
    // With no URL it shows the fallback; give it a real avatar URL to see a picture.
    HStack(spacing: 20) {
        AvatarView(url: nil, size: 44)
        AvatarView(url: nil, size: 96)
    }
    .padding()
}
