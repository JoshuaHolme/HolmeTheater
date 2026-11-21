# Contributing to Holme Theater

Thanks for helping out. Bug reports, feature ideas, and pull requests are all welcome.

## Reporting bugs and requesting features

Open an [issue](https://github.com/JoshuaHolme/HolmeTheater/issues). For bugs, please include:

- Your device and its iOS, iPadOS, or tvOS version
- Your Jellyfin server version
- The steps that lead to the problem, and what you expected instead

Don't paste server addresses, access tokens, or stream URLs (they contain your token) into an issue. For security
problems, follow [SECURITY.md](SECURITY.md) instead of opening a public issue.

## Getting set up

See [Building](README.md#building) in the README. `-UseMockService` runs the app against canned data, so most UI work
doesn't need a server.

## Pull requests

- Keep each pull request to one change, and describe what it does and why.
- Make sure the app builds for both iOS and tvOS, and that the unit tests pass (⌘U).
- Add or update tests for logic you change. Unit tests use [Swift Testing](https://developer.apple.com/documentation/testing/);
  UI tests use XCUIAutomation.
- Don't commit your development team or bundle identifier changes.

## Code guidelines

- **Keep the SDK behind the protocol.** Only the `JellyfinMediaService` files import `JellyfinAPI`. Views use
  `MediaService` and the value types in `MediaModels.swift`. If a view needs something new, add it to the protocol and
  implement it in `JellyfinMediaService`, `MockMediaService`, and `OfflineFallbackMediaService`.
- **Document what you add.** Give new types, and members whose purpose isn't obvious from their name, a `///` comment.
  Explain *why* in comments for anything subtle.
- **Use Swift concurrency.** Prefer `async`/`await` and `@Observable` over Combine.
- **Pull out logic you can test.** Parsing, maths, and URL handling belong in small value types or pure functions, not
  inside views.
- **Never log secrets.** Don't log tokens, passwords, or full URLs, and mark anything user-specific in `Logger` calls
  `privacy: .private`.
- **Follow the surrounding style:** 4-space indentation, PascalCase types, and camelCase members. Avoid force unwraps
  and force casts in app code; where one truly can't fail, say why in a comment.
- **License headers.** Every source file starts with the MPL-2.0 header:

  ```swift
  // This Source Code Form is subject to the terms of the Mozilla Public
  // License, v. 2.0. If a copy of the MPL was not distributed with this
  // file, You can obtain one at https://mozilla.org/MPL/2.0/.
  ```

## License

By contributing, you agree that your contributions are licensed under the [Mozilla Public License 2.0](LICENSE).
