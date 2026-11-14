// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// The start of one library's list, as far as it has been fetched for a page merged from several libraries.
nonisolated struct MergedPrefix: Sendable, Equatable {
    var items: [MediaItem] = []

    /// Whether the library sent fewer than it was asked for, so there's no more to ask it for.
    var isComplete = false
}

/// Merges lists the server can only give one library at a time into one page, as the server would have ordered them.
nonisolated enum MergedPaging {
    /// One page of several libraries' lists merged into one.
    ///
    /// Items are taken from each list in turn, so one library's items can't crowd the others off the page, and each
    /// item appears once however many lists it's in. With `byLastPlayed`, the merged list is then sorted by when each
    /// item was last played, newest first, which is the order the server would have given them in. The sort is stable,
    /// so items played at the same moment (or never) keep their turn-by-turn order.
    ///
    /// - Parameters:
    ///   - lists: Each library's items, in the library's own order.
    ///   - offset: How many items of the merged list to skip.
    ///   - limit: How many to return.
    static func page(of lists: [[MediaItem]], offset: Int, limit: Int, byLastPlayed: Bool) -> [MediaItem] {
        var merged = interleave(lists)
        if byLastPlayed { merged = sortedByLastPlayed(merged) }
        return Array(merged.dropFirst(offset).prefix(limit))
    }

    /// The lists taken from in turn, first items first, each item once.
    static func interleave(_ lists: [[MediaItem]]) -> [MediaItem] {
        var seen = Set<MediaItem.ID>()
        var merged: [MediaItem] = []
        for position in 0..<(lists.map(\.count).max() ?? 0) {
            for list in lists where position < list.count && seen.insert(list[position].id).inserted {
                merged.append(list[position])
            }
        }
        return merged
    }

    /// Newest played first, then never played, keeping the given order among equals.
    static func sortedByLastPlayed(_ items: [MediaItem]) -> [MediaItem] {
        items.enumerated()
            .sorted { a, b in
                switch (a.element.lastPlayedDate, b.element.lastPlayedDate) {
                case let (x?, y?) where x != y: x > y
                case (_?, nil): true
                case (nil, _?): false
                default: a.offset < b.offset
                }
            }
            .map(\.element)
    }
}
