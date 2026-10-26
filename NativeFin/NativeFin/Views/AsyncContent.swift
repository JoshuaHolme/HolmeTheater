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
struct AsyncContent<Value, Content: View>: View {
    private enum Phase {
        case loading
        case loaded(Value)
        case failed(String)
    }

    /// Fetches the value. Errors are shown to the user with a Retry button.
    let load: () async throws -> Value

    /// Changing this reloads silently, keeping what's on screen until the new value arrives.
    var reloadID = 0

    /// Builds the loaded UI from the fetched value.
    @ViewBuilder let content: (Value) -> Content

    @State private var phase: Phase = .loading

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                }
            }
        }
        // Keyed on `reloadID`, so changing it runs the load again (and cancels one still in flight).
        .task(id: reloadID) { await run() }
    }

    private func run() async {
        do {
            let value = try await load()
            // Superseded by a newer load (or the view went away): that load's result is the one to show.
            guard !Task.isCancelled else { return }
            phase = .loaded(value)
        } catch {
            // The task is cancelled when the view disappears; that isn't a failure.
            guard !Task.isCancelled else { return }
            // A failed reload keeps what's on screen, which is only out of date. Only a first load shows the error.
            if case .loaded = phase { return }
            phase = .failed(error.localizedDescription)
        }
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
