// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Loads a value when it appears and renders it, with built-in loading and error/retry states.
///
/// Reloads silently (no spinner) each time the view reappears, e.g. when popping back to it, and whenever
/// `reloadID` changes. If a silent reload fails, the last loaded value stays on screen.
///
/// ```swift
/// AsyncContent(load: { try await service.libraries() }) { libraries in
///     List(libraries) { Text($0.name) }
/// }
/// ```
struct AsyncContent<Value, Content: View, Placeholder: View>: View {
    private enum Phase {
        case loading
        case loaded(Value)
        case failed(String)
    }

    /// Fetches the value. Errors are shown to the user with a Retry button.
    let load: () async throws -> Value

    /// Changing this reloads silently, keeping what's on screen until the new value arrives.
    var reloadID = 0

    /// Lets a view outside this one reload it and wait for the result, e.g. a pull to refresh on a scroll view that
    /// holds this view, which this view's own pull to refresh can't reach.
    var refresher: ContentRefresher?

    /// Whether a pull down on a scroll view inside reloads this content. Turn off when a scroll view around this view
    /// owns the pull to refresh, so it isn't also attached to the scroll views inside.
    var pullsToRefresh = true

    /// The height of the spinner's frame while loading, for a view that knows better than its container where the
    /// middle is, e.g. one that runs under the safe area. Nil fills the container.
    var loadingHeight: CGFloat?

    /// Whether the error page, when the device is offline, links to the Downloads tab.
    var offersDownloads = false

    /// Shown in place of the spinner while the first load runs, laid out like the content so it can take its place. Nil
    /// shows the spinner.
    var placeholder: Placeholder?

    /// Builds the loaded UI from the fetched value.
    @ViewBuilder let content: (Value) -> Content

    init(
        load: @escaping () async throws -> Value,
        reloadID: Int = 0,
        refresher: ContentRefresher? = nil,
        pullsToRefresh: Bool = true,
        loadingHeight: CGFloat? = nil,
        offersDownloads: Bool = false,
        placeholder: Placeholder,
        @ViewBuilder content: @escaping (Value) -> Content
    ) {
        self.load = load
        self.reloadID = reloadID
        self.refresher = refresher
        self.pullsToRefresh = pullsToRefresh
        self.loadingHeight = loadingHeight
        self.offersDownloads = offersDownloads
        self.placeholder = placeholder
        self.content = content
    }

    @Environment(\.openDownloads) private var openDownloads

    @State private var phase: Phase = .loading

    /// Counts loads as they start, so a load that finishes after a newer one has started is thrown away. The
    /// `.task` cancels its own runs, but a pull to refresh or Retry runs outside it.
    @State private var latestRun = 0

    var body: some View {
        Group {
            switch phase {
            case .loading:
                if let placeholder {
                    // One "Loading" for the lot, not each placeholder block.
                    placeholder
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Loading")
                } else if let loadingHeight {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .frame(height: loadingHeight)
                } else {
                    // Filling the container, which is the visible area even inside a scroll view, where a
                    // maxHeight of infinity would only shrink to the spinner and leave it at the top.
                    ProgressView()
                        .containerRelativeFrame([.horizontal, .vertical])
                }
            case .loaded(let value):
                content(value)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't Load", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") {
                        phase = .loading
                        Task { await run() }
                    }

                    if offersDownloads, !NetworkStatus.shared.isOnline, let openDownloads {
                        Button("Go to Downloads") { openDownloads() }
                    }
                }
                // Centered in the same space the spinner is, not left at the top of a scroll view.
                .frame(maxWidth: .infinity, maxHeight: loadingHeight == nil ? .infinity : nil)
                .frame(height: loadingHeight)
            }
        }
        // Keyed on `reloadID`, so changing it runs the load again (and cancels one still in flight).
        .task(id: reloadID) {
            refresher?.action = { await run() }
            await run()
        }
        // Pulling down a scroll view inside reloads, silently like the other reloads, with the system's spinner.
        .pullToRefresh(enabled: pullsToRefresh) { await run() }
    }

    private func run() async {
        latestRun += 1
        let thisRun = latestRun
        do {
            let value = try await load()
            // Superseded by a newer load (or the view went away): that load's result is the one to show.
            guard !Task.isCancelled, thisRun == latestRun else { return }
            phase = .loaded(value)
        } catch {
            // The task is cancelled when the view disappears; that isn't a failure.
            guard !Task.isCancelled, thisRun == latestRun else { return }
            // A failed reload keeps what's on screen, which is only out of date. Only a first load shows the error.
            if case .loaded = phase { return }
            phase = .failed(error.localizedDescription)
        }
    }
}

extension AsyncContent where Placeholder == EmptyView {
    /// With a spinner, rather than a placeholder, while the first load runs.
    init(
        load: @escaping () async throws -> Value,
        reloadID: Int = 0,
        refresher: ContentRefresher? = nil,
        pullsToRefresh: Bool = true,
        loadingHeight: CGFloat? = nil,
        offersDownloads: Bool = false,
        @ViewBuilder content: @escaping (Value) -> Content
    ) {
        self.load = load
        self.reloadID = reloadID
        self.refresher = refresher
        self.pullsToRefresh = pullsToRefresh
        self.loadingHeight = loadingHeight
        self.offersDownloads = offersDownloads
        self.placeholder = nil
        self.content = content
    }
}

/// Switches to the Downloads tab. Call it like a function.
struct OpenDownloadsAction: Equatable {
    let action: () -> Void

    func callAsFunction() { action() }

    /// Any two are equal: there's only ever one tab bar, and every action switches it to the same tab. Without this, the
    /// environment couldn't tell a new action from the old one, and would update every view reading it each time.
    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

extension EnvironmentValues {
    /// Switches to the Downloads tab, or nil where there's no tab bar to switch.
    @Entry var openDownloads: OpenDownloadsAction?
}

/// A handle for reloading an ``AsyncContent`` from outside it, and waiting until the new value is showing.
@MainActor
final class ContentRefresher {
    /// Set by the ``AsyncContent`` it's given to.
    fileprivate var action: (@MainActor () async -> Void)?

    /// Reloads the content and returns once the load has finished. Does nothing if the content isn't showing.
    func refresh() async {
        await action?()
    }
}

extension View {
    /// Lets the user pull down a scroll view in this view to run `action`, with the system's spinner showing until it
    /// finishes. Does nothing on tvOS, where there's no pulling.
    ///
    /// - Parameter enabled: Fixed for the life of the view. The two cases are different views, so changing it would
    ///   reset the state of everything inside.
    @ViewBuilder
    func pullToRefresh(enabled: Bool = true, _ action: @escaping @MainActor @Sendable () async -> Void) -> some View {
        #if os(tvOS)
        self
        #else
        if enabled {
            refreshable(action: action)
        } else {
            self
        }
        #endif
    }
}

#Preview("Loaded") {
    AsyncContent(load: { ["One", "Two", "Three"] }) { items in
        List(items, id: \.self) { Text($0) }
    }
}

#Preview("Loading") {
    AsyncContent(load: {
        try await Task.sleep(for: .seconds(3600))
        return [String]()
    }) { _ in
        Text("Never shown")
    }
}

#Preview("Failed") {
    AsyncContent(load: { () async throws -> [String] in
        throw MediaServiceError.serverUnreachable
    }) { _ in
        Text("Never shown")
    }
}
