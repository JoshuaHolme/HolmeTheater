// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Concurrency with a ceiling, for work that shouldn't all hit a server at once.
nonisolated enum BoundedTaskGroup {
    /// Runs `work` on each element, at most `width` at a time, so a big cast doesn't open dozens of requests to the
    /// server at once. Returns once every element has been handled.
    static func forEach<Element: Sendable>(
        _ elements: [Element],
        atMost width: Int = 6,
        _ work: @escaping @Sendable (Element) async -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            for (index, element) in elements.enumerated() {
                // Once `width` are running, each new one waits for one to finish.
                if index >= width { await group.next() }
                group.addTask { await work(element) }
            }
        }
    }
}
