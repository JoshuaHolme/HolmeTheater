// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#if os(iOS)
import ActivityKit
import Foundation
import OSLog
import Synchronization

/// Sends changes to the downloads Live Activity one at a time, in order, and only ever the latest.
///
/// Each change used to go in a task of its own, and those finish in any order. An old percentage could arrive after a
/// newer one, so the display stepped back and forward, and two first updates could each start an activity, leaving two
/// on screen. Here a change replaces any that hasn't been sent yet, and one is sent only after the one before it is done.
nonisolated final class LiveActivityUpdater: Sendable {
    typealias Content = ActivityContent<DownloadActivityAttributes.ContentState>

    /// A change to send to the activity.
    enum Update: Sendable {
        /// Update the activity, or start it if there isn't one.
        case show(Content)
        /// End it, leaving `content` (if any) on screen as the policy says.
        case end(Content?, ActivityUIDismissalPolicy)
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "HolmeTheater", category: "LiveActivity")

    /// The change waiting to be sent, and whether a task is sending them.
    private let queue = Mutex<(pending: Update?, isSending: Bool)>((nil, false))

    /// Queues `update`, replacing one still waiting. Returns at once; the order calls are made in is the order they count in.
    func submit(_ update: Update) {
        let shouldStart = queue.withLock { queue -> Bool in
            queue.pending = update
            if queue.isSending { return false }
            queue.isSending = true
            return true
        }
        if shouldStart { Task.detached { await self.sendPending() } }
    }

    private func sendPending() async {
        while true {
            let next = queue.withLock { queue -> Update? in
                let next = queue.pending
                queue.pending = nil
                if next == nil { queue.isSending = false }
                return next
            }
            guard let next else { return }
            await send(next)
        }
    }

    // The activity is only ever handled in here, never passed between tasks, because it can't be sent safely.
    private func send(_ update: Update) async {
        switch update {
        case .show(let content):
            // There's at most one live one, which may be left from an earlier launch. One that has ended is only
            // waiting to be dismissed, and updating it would show nothing, so a new batch starts a new one.
            if let existing = Self.liveActivities.first {
                await existing.update(content)
                return
            }
            do {
                _ = try Activity.request(attributes: DownloadActivityAttributes(), content: content)
            } catch {
                Self.logger.error("Couldn't start the Live Activity: \(error.localizedDescription, privacy: .public)")
            }
        case .end(let content, let policy):
            // One that has already ended is left to finish as it was told, e.g. saying "Done" for a few seconds.
            for activity in Self.liveActivities {
                await activity.end(content, dismissalPolicy: policy)
            }
        }
    }

    /// The activities that haven't ended.
    private static var liveActivities: [Activity<DownloadActivityAttributes>] {
        Activity<DownloadActivityAttributes>.activities.filter { $0.activityState == .active || $0.activityState == .stale }
    }
}
#endif
