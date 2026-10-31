// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ActivityKit
import SwiftUI
import WidgetKit

/// The Live Activity that follows downloads on the Lock Screen and in the Dynamic Island.
struct DownloadActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            DownloadLockScreenView(state: context.state)
                .padding()
                .activityBackgroundTint(.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.symbol)
                        .font(.title2)
                        .foregroundStyle(.blue)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    PercentText(state: context.state, width: 60)
                        .font(.title3.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: context.state.fraction)
                            .tint(.blue)
                        Text(context.state.statusLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.symbol)
                    .foregroundStyle(.blue)
            } compactTrailing: {
                Text(context.state.percent)
                    .font(.caption.monospacedDigit())
                    .frame(maxWidth: 44)
            } minimal: {
                Gauge(value: context.state.fraction) {
                    Image(systemName: context.state.symbol)
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(.blue)
            }
        }
    }
}

/// The percentage, in a space as wide as "100%", with every digit the same width. Without that, the text is wider at
/// "100%" than "9%", and the Dynamic Island resizes around it each time the number gains a digit, which looks like
/// jumping.
private struct PercentText: View {
    let state: DownloadActivityAttributes.ContentState
    let width: CGFloat

    var body: some View {
        Text(state.percent)
            .monospacedDigit()
            .lineLimit(1)
            // Swapped in place; the digit animation slides sideways while it runs.
            .contentTransition(.identity)
            .frame(width: width, alignment: .trailing)
    }
}


/// The Lock Screen and banner layout.
private struct DownloadLockScreenView: View {
    let state: DownloadActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: state.symbol)
                    .foregroundStyle(.blue)
                Text(state.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                PercentText(state: state, width: 56)
                    .font(.headline)
            }
            ProgressView(value: state.fraction)
                .tint(.blue)
            Text(state.statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
    }
}

private extension DownloadActivityAttributes.ContentState {
    var symbol: String {
        if isFinished { "checkmark.circle.fill" } else if isPaused { "pause.circle.fill" } else { "arrow.down.circle.fill" }
    }

    var percent: String { fraction.formatted(.percent.precision(.fractionLength(0))) }

    /// What's happening, in a line.
    var statusLine: String {
        if isFinished { return String(localized: "Downloaded") }
        if isPaused { return String(localized: "Paused") }
        return subtitle ?? String(localized: "Downloading…")
    }
}
