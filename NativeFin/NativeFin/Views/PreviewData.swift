// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// Sample data for SwiftUI previews. Images are left nil so previews never touch the network and show
// the artwork placeholder.
//
// Deliberately not wrapped in `#if DEBUG`: `#Preview` bodies are compiled in Release builds too, so
// hiding this data from Release breaks the Release build (and therefore App Store archives).

extension MediaItem {
    /// A movie that hasn't been started.
    static let previewMovie = MediaItem(
        id: "preview-movie",
        title: "A Movie With a Fairly Long Title",
        kind: .movie,
        overview: "A placeholder synopsis that runs long enough to wrap onto a few lines, so layouts "
            + "can be checked against realistic text rather than a single short sentence.",
        year: 2019,
        runtime: 6720,
        posterURL: nil,
        backdropURL: nil,
        playedFraction: nil,
        isPlayed: false,
        seriesTitle: nil,
        seasonNumber: nil,
        episodeNumber: nil
    )

    /// A movie that's 40% watched.
    static let previewPartlyWatched = MediaItem(
        id: "preview-partly-watched",
        title: "Partly Watched",
        kind: .movie,
        overview: "Shows a progress bar and a Resume button.",
        year: 2021,
        runtime: 5400,
        posterURL: nil,
        backdropURL: nil,
        playedFraction: 0.4,
        isPlayed: false,
        seriesTitle: nil,
        seasonNumber: nil,
        episodeNumber: nil
    )

    /// A movie that's been finished.
    static let previewWatched = MediaItem(
        id: "preview-watched",
        title: "Already Watched",
        kind: .movie,
        overview: "Shows the watched checkmark.",
        year: 2017,
        runtime: 7200,
        posterURL: nil,
        backdropURL: nil,
        playedFraction: nil,
        isPlayed: true,
        seriesTitle: nil,
        seasonNumber: nil,
        episodeNumber: nil
    )

    static let previewSeries = MediaItem(
        id: "preview-series",
        title: "Sample Show",
        kind: .series,
        overview: "A placeholder synopsis for a show. Its detail screen lists children.",
        year: 2022,
        runtime: nil,
        posterURL: nil,
        backdropURL: nil,
        playedFraction: nil,
        isPlayed: false,
        seriesTitle: nil,
        seasonNumber: nil,
        episodeNumber: nil
    )

    /// An episode that's 60% watched.
    static let previewEpisode = MediaItem(
        id: "preview-episode",
        title: "The One With the Preview",
        kind: .episode,
        overview: "A placeholder synopsis for an episode.",
        year: 2022,
        runtime: 2640,
        posterURL: nil,
        backdropURL: nil,
        playedFraction: 0.6,
        isPlayed: false,
        seriesTitle: "Sample Show",
        seasonNumber: 1,
        episodeNumber: 3
    )

    /// A mix of unwatched, partly watched, and watched movies.
    static let previewMovies: [MediaItem] = [previewMovie, previewPartlyWatched, previewWatched] + (1...4).map { index in
        MediaItem(
            id: "preview-extra-\(index)",
            title: "Sample Movie \(index)",
            kind: .movie,
            overview: nil,
            year: 2000 + index,
            runtime: 5400,
            posterURL: nil,
            backdropURL: nil,
            playedFraction: nil,
            isPlayed: false,
            seriesTitle: nil,
            seasonNumber: nil,
            episodeNumber: nil
        )
    }
}

extension Library {
    /// A movie library.
    static let previewMovies = Library(id: "lib-movies", name: "Movies", kind: .movies)
}

extension UserSession {
    /// A signed-in user on a placeholder server, without a profile picture.
    static let preview = UserSession(
        server: ServerInfo(id: "preview-server", name: "Preview Server", url: .exampleServer),
        userID: "preview-user",
        username: "demo",
        accessToken: "preview-token"
    )
}

extension AppModel {
    /// Creates a model backed by ``MockMediaService`` for use in previews.
    ///
    /// Safe to use interactively: signing in or out inside a preview never touches the real app's saved session.
    ///
    /// - Parameter signedIn: Whether the model starts signed in as ``UserSession/preview``, or signed out.
    /// - Returns: A new model, so each preview gets its own state.
    static func preview(signedIn: Bool = true) -> AppModel {
        AppModel(
            service: MockMediaService(latency: .milliseconds(150)),
            state: signedIn ? .signedIn(.preview) : .signedOut
        )
    }
}
