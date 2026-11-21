// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// A session delegate that keeps the access token on the server it was meant for.
///
/// Requests made with ``MediaService/authorizedRequest(for:)`` carry the token in their `Authorization` header, and
/// URLSession keeps a request's headers when it follows a redirect. A redirect to anywhere other than the server the
/// request started at (a CDN, a misconfigured proxy) goes on without the header.
///
/// Background sessions follow redirects without asking their delegate, so this only works for the others.
nonisolated final class SameOriginAuthorization: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = SameOriginAuthorization()

    // The completion handler form: Swift 6.4 crashes compiling the `async` one.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(Self.redirecting(request, from: task.originalRequest?.url ?? response.url))
    }

    /// `request`, a redirect from a request that was sent to `origin`, without its `Authorization` header unless it goes
    /// back to the same scheme, host and port.
    static func redirecting(_ request: URLRequest, from origin: URL?) -> URLRequest {
        guard request.value(forHTTPHeaderField: "Authorization") != nil else { return request }
        if let origin, let destination = request.url, ServerAddress.isSameOrigin(origin, destination) { return request }
        var stripped = request
        stripped.setValue(nil, forHTTPHeaderField: "Authorization")
        return stripped
    }
}
