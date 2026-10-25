// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// A drop-in replacement for `AsyncImage` that loads through ``ImageCache``.
///
/// If the image is already in memory it's shown on the very first frame, with no placeholder flash, which is
/// what makes recycled cards in a scrolling row look right. Otherwise it behaves like `AsyncImage`:
/// `.empty` while loading, then `.success` or `.failure`.
struct CachedAsyncImage<Content: View>: View {
    /// The image to load, or `nil` to stay in the `.empty` phase.
    let url: URL?

    /// Builds the view for the current loading phase.
    @ViewBuilder let content: (AsyncImagePhase) -> Content

    /// The current loading phase.
    @State private var phase: AsyncImagePhase

    /// Creates a view that loads an image through the shared cache.
    ///
    /// - Parameters:
    ///   - url: The image to load, or `nil` to stay in the `.empty` phase.
    ///   - content: A closure that builds the view for each loading phase.
    init(url: URL?, @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        self.url = url
        self.content = content

        // Start from the cache so there's no empty first frame for images we already have.
        if let url, let cached = ImageCache.shared.cachedImage(for: url) {
            _phase = State(initialValue: .success(Image(platformImage: cached)))
        } else {
            _phase = State(initialValue: .empty)
        }
    }

    var body: some View {
        content(phase)
            // Reruns when the URL changes, e.g. when a list reuses this view for a different item.
            .task(id: url) { await load() }
    }

    /// Loads the image for the current URL and updates the phase.
    private func load() async {
        guard let url else {
            phase = .empty
            return
        }

        if let cached = ImageCache.shared.cachedImage(for: url) {
            phase = .success(Image(platformImage: cached))
            return
        }

        // Clear any image left over from a previous URL while this one loads.
        phase = .empty
        let image = await ImageCache.shared.image(for: url)

        // Scrolled away while loading: the download still finishes and is cached, but there's no view to update.
        guard !Task.isCancelled else { return }
        if let image {
            phase = .success(Image(platformImage: image))
        } else {
            phase = .failure(URLError(.cannotLoadFromNetwork))
        }
    }
}

extension Image {
    /// Creates an image from the platform's native image type.
    ///
    /// - Parameter platformImage: A `UIImage`, or an `NSImage` on macOS.
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}
