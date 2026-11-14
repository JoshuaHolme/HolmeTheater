# Holme Theater

A native [Jellyfin](https://jellyfin.org) client for iOS and tvOS, written in SwiftUI.

> **Status: early development.** The core flow works (sign in, browse, search, play), but the UI is deliberately
> bare-bones and many features are missing. See [Roadmap](#roadmap).

Holme Theater is an independent project and is not affiliated with or endorsed by the Jellyfin project.

## Features

- Connect to a server by address (tries HTTPS, then HTTP, if you don't type a scheme)
- Sign in with a username and password, or with [Quick Connect](https://jellyfin.org/docs/general/server/quick-connect/)
- Home screen with Continue Watching and recently added items
- Browse movie and TV libraries, including seasons and episodes
- Search
- Playback with AVPlayer: direct play when the file is compatible, otherwise the server remuxes or transcodes to HLS
- Watch progress is reported back to the server, so Continue Watching and watched state stay in sync
- Saved sessions are stored in the Keychain

## Roadmap

Not implemented yet:

- Subtitle and audio track selection
- Server discovery on the local network
- Pagination for very large libraries
- Music, photos, and Live TV
- Playback of formats AVPlayer can't handle natively (e.g. via VLC or MPV)
- Downloads and offline playback
- A designed UI. The current screens exist to exercise the backend and are meant to be restyled.

## Requirements

- A Mac with a version of Xcode that includes the iOS 27 and tvOS 27 SDKs (the current deployment targets)
- A Jellyfin server you can reach from your device or simulator

## Building

1. Open `HolmeTheater/HolmeTheater.xcodeproj` in Xcode. Swift Package Manager fetches the dependencies automatically.
2. In the target's **Signing & Capabilities** tab, choose your own development team and set a bundle identifier you own.
3. Pick an iPhone, iPad, or Apple TV destination and run.

To explore the UI without a server, add `-UseMockService` as a launch argument in the scheme's **Run → Arguments**.
The mock returns sample movies and shows, and its Quick Connect shows the code `123456` and "approves" it after a few seconds.

## Architecture

The UI never talks to the Jellyfin SDK directly. Everything goes through one protocol:

| File | Role |
|---|---|
| `Services/MediaService.swift` | The protocol the UI depends on: connect, sign in, browse, search, play, report progress |
| `Services/JellyfinMediaService.swift` (+`Browsing`/`Collections`/`Playback`/`Mapping`) | The real implementation, built on [jellyfin-sdk-swift](https://github.com/jellyfin/jellyfin-sdk-swift), split by area |
| `Services/MockMediaService.swift` | Canned data for previews, demos, and UI work without a server |
| `Services/MediaModels.swift` | Plain value types shared by the UI and services (no SDK types) |
| `Services/SessionStore.swift` | Where the signed-in session is kept: the Keychain in the app, in memory in tests |
| `AppModel.swift` | App-wide state: which service is in use and who is signed in |
| `Views/` | SwiftUI screens. These only use `MediaService` and the types in `MediaModels.swift` |

Because of this split you can rework the UI without touching networking code, and swap in a different backend
(or a test double) without touching the UI.

Larger files are broken up by area rather than kept in one place. The Jellyfin service, the download system
(`Services/Downloads/`), the subtitle parsers (`Services/Subtitles/`), and the biggest screens (the detail hero,
the Home carousel, the players) are each split across focused files. Logic that can be reasoned about on its own,
such as URL handling, paging, subtitle parsing, the carousel's index maths, and the player's timing, lives in small
value types and pure functions so it can be unit tested without a server or a running view.

## Tests

Unit tests live in the `HolmeTheaterTests` target and use the [Swift Testing](https://developer.apple.com/documentation/testing/)
framework. They cover the extracted helpers and value types: server-address parsing, access-token URL handling,
merged paging, the WebVTT and SubStation Alpha subtitle parsers, the download summary and library grouping, the
detail-hero text lines, the carousel and up-next timing maths, and `AppModel`'s sign-in, sign-out and session
restore (against an in-memory session store and the mock service, so they never touch a real server or the
Keychain).

Run them from Xcode with **Product → Test** (⌘U), or on the command line:

```sh
xcodebuild test -scheme HolmeTheater -destination 'platform=iOS Simulator,name=iPhone 17'
```

## Security notes

- The app allows plain HTTP connections (`NSAllowsArbitraryLoads`). Jellyfin servers are self-hosted, usually on a LAN
  at an address that isn't known at build time, and commonly don't use TLS. Prefer HTTPS for anything reachable
  over the internet.
- The access token is kept in the Keychain. For playback it is also appended to stream URLs as an `ApiKey` query
  parameter, because AVPlayer can't attach headers to every HLS segment request. Treat stream URLs as secrets.

## Contributing

Issues and pull requests are welcome. Please keep SDK types inside `JellyfinMediaService` and document new public
types and methods with `///` comments.

## License

Holme Theater is licensed under the [Mozilla Public License 2.0](LICENSE). It depends on
[jellyfin-sdk-swift](https://github.com/jellyfin/jellyfin-sdk-swift), which is also MPL-2.0.
