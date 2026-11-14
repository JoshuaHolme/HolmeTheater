// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Synchronization

/// Waits for the system to say a background session has told the app everything that happened while it was away.
nonisolated final class BackgroundEvents: Sendable {
    private struct State {
        /// Set when the system said so with nobody waiting, for the next wait to find.
        var finished = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())

    /// How long a wait lasts at most: as long as the system would allow.
    static let timeout: Duration = .seconds(30)

    func markFinished() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard let waiter = state.waiter else {
                state.finished = true
                return nil
            }
            state.waiter = nil
            return waiter
        }
        waiter?.resume()
    }

    /// Returns once events have been delivered, or after ``timeout``.
    func wait() async {
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.timeout)
            guard !Task.isCancelled else { return }
            self?.resumeWaiter()
        }
        await withCheckedContinuation { continuation in
            let outcome = state.withLock { state -> WaitOutcome in
                if state.finished {
                    state.finished = false
                    return .alreadyFinished
                }
                let older = state.waiter
                state.waiter = continuation
                return .waiting(replacing: older)
            }
            switch outcome {
            case .alreadyFinished:
                continuation.resume()
            case .waiting(let older):
                // A wait already going is let go, so there's only ever one, and none is left hanging.
                older?.resume()
            }
        }
        timeout.cancel()
    }

    private enum WaitOutcome {
        case alreadyFinished
        case waiting(replacing: CheckedContinuation<Void, Never>?)
    }

    /// Lets the wait go without events having arrived.
    private func resumeWaiter() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }
}
