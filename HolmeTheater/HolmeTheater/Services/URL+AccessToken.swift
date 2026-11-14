// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// The access token in a stream URL's query. AVPlayer can't attach auth headers to every HLS segment request, so
// the token goes in the URL; everything that saves or prints a URL takes it back out.

extension URL {
    /// The query parameter the token travels in.
    private nonisolated static let accessTokenKey = "ApiKey"

    /// The names older servers and clients have used for it, matched in any case.
    private nonisolated static let accessTokenKeys = [accessTokenKey, "api_key"]

    /// The URL with `token` added as its `ApiKey` query parameter, unless it already has one.
    ///
    /// Works on the percent-encoded query so the server's own parameters are passed through byte for byte.
    nonisolated func addingAccessToken(_ token: String?) -> URL {
        guard let token,
              // `&`, `=` and `+` are legal in a query but would change its meaning inside a value.
              let encodedToken = token.addingPercentEncoding(
                  withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+"))
              ),
              var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        else { return self }

        var items = components.percentEncodedQueryItems ?? []
        let hasKey = items.contains { $0.name.caseInsensitiveCompare(Self.accessTokenKey) == .orderedSame }
        if !hasKey { items.append(URLQueryItem(name: Self.accessTokenKey, value: encodedToken)) }
        components.percentEncodedQueryItems = items
        return components.url ?? self
    }

    /// The URL without the access token: an `ApiKey` query parameter, or the `api_key` older servers put in the URLs
    /// they hand out, matched in any case. The rest of the query is kept byte for byte.
    nonisolated func removingAccessToken() -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              let items = components.percentEncodedQueryItems else { return self }
        let kept = items.filter { item in
            !Self.accessTokenKeys.contains { item.name.caseInsensitiveCompare($0) == .orderedSame }
        }
        guard kept.count != items.count else { return self }
        components.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        return components.url ?? self
    }
}
