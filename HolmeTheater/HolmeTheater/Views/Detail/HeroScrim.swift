// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// The fade that darkens a detail hero's artwork behind its text, worked out on its own so it can be tested.
nonisolated enum HeroScrim {
    /// Where the fade begins when the details are short, as a fraction of the hero's height.
    static let usualStart: CGFloat = 0.3

    /// How far above the details the fade begins, so their first line isn't over bare artwork.
    static let lead: CGFloat = 60

    /// The fade's opacity at each fraction of its length, easing in from nothing to the strongest.
    static let profile: [(position: CGFloat, opacity: Double)] = [
        (0, 0), (0.214, 0.2), (0.429, 0.5), (0.686, 0.7), (1, 0.85)
    ]

    /// Where the fade starts, as a fraction of the hero's height.
    ///
    /// It usually begins 30% of the way down. With larger text or more lines the details are taller and would reach up
    /// past that, onto bare artwork where white text can be unreadable, so the fade begins above their top instead.
    ///
    /// - Parameters:
    ///   - heroHeight: The hero's full height.
    ///   - detailsHeight: How tall the stacked details are.
    ///   - bottomReserve: The room left under the details for the first row to rise into (tvOS), 0 elsewhere.
    static func start(heroHeight: CGFloat, detailsHeight: CGFloat, bottomReserve: CGFloat) -> CGFloat {
        guard heroHeight > 0, detailsHeight > 0 else { return usualStart }
        // The details, their bottom padding, and a little lead-in above them.
        let covered = detailsHeight + 20 + bottomReserve + lead
        return min(usualStart, max(0, 1 - covered / heroHeight))
    }

    /// The gradient stops that darken the backdrop behind the details. The same shape is stretched over whatever length
    /// the start leaves, leaning toward `base` (the theme's near-black) rather than pure black.
    static func stops(start: CGFloat, base: Color) -> [Gradient.Stop] {
        profile.map { step in
            Gradient.Stop(color: base.opacity(step.opacity), location: start + (1 - start) * step.position)
        }
    }
}
