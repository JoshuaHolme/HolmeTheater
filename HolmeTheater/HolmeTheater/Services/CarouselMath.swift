// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// The index arithmetic the Home hero carousel runs on: an endless strip of virtual pages wrapped onto a ring of items.
/// Pure, so the view stays about layout and this can be tested.
nonisolated enum CarouselMath {
    /// The position in `0..<count` that a virtual page (which counts every step taken, past the ends) shows. Zero for an
    /// empty or single-item carousel.
    static func index(forVirtual virtualIndex: Int, count: Int) -> Int {
        guard count > 1 else { return 0 }
        return ((virtualIndex % count) + count) % count
    }

    /// How many steps along the strip, the short way round, from the item at `index` to the one at `position`.
    static func steps(from index: Int, to position: Int, count: Int) -> Int {
        guard count > 1 else { return 0 }
        var delta = (position - index) % count
        if delta > count / 2 { delta -= count }
        if delta < -(count / 2) { delta += count }
        return delta
    }

    /// The positions that get a dot: all of them, or, with more items than `maxVisible`, a window that follows the one
    /// showing so the row never grows wider than its pill. The one showing stays a few dots in from the start until the
    /// window runs out at either end.
    static func visiblePositions(index: Int, count: Int, maxVisible: Int) -> [Int] {
        guard count > maxVisible else { return Array(0..<max(count, 0)) }
        let start = min(max(index - (maxVisible - 3), 0), count - maxVisible)
        return Array(start..<(start + maxVisible))
    }
}
