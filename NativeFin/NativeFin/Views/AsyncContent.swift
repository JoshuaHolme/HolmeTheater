// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Loads a value when it appears and renders it, with built-in loading and error/retry states.
///
/// Reloads silently (no spinner) each time the view reappears, e.g. when popping back to it.
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
        .task { await run() }
    }

    private func run() async {
        do {
            phase = .loaded(try await load())
        } catch {
            // The task is cancelled when the view disappears; that isn't a failure.
            guard !Task.isCancelled else { return }
            phase = .failed(error.localizedDescription)
        }
    }
}
