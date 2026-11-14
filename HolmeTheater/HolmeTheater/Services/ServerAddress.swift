// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// How a server address the user typed becomes the URLs to try, and how URLs are compared to the server's.
nonisolated enum ServerAddress {
    /// "jellyfin.local:8096" → https://… then http://…; an explicit scheme is used as-is.
    ///
    /// Falling back to HTTP is what makes LAN servers work without typing a scheme, but it means the
    /// connection may be unencrypted. The sign-in screen warns when it is.
    ///
    /// Only web addresses come back: a `file:`, `ftp:` or custom scheme would never reach a Jellyfin server, and the
    /// password must never go anywhere else.
    static func candidateURLs(from address: String) -> [URL] {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // What the user typed with a scheme is used as it is; without one, secure first, then plain.
        let strings = trimmed.contains("://") ? [trimmed] : ["https://\(trimmed)", "http://\(trimmed)"]
        return strings.compactMap { string in
            guard let url = URL(string: string), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
                  url.host() != nil else { return nil }
            return url
        }
    }

    /// Whether two URLs have the same scheme, host and port, so a token meant for one can be sent to the other.
    static func isSameOrigin(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased()
            && a.host()?.lowercased() == b.host()?.lowercased()
            && (a.port ?? defaultPort(a)) == (b.port ?? defaultPort(b))
    }

    private static func defaultPort(_ url: URL) -> Int? {
        switch url.scheme?.lowercased() {
        case "https": 443
        case "http": 80
        default: nil
        }
    }
}
