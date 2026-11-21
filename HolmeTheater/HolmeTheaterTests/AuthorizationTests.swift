// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import HolmeTheater

/// The access token must only ever go to the server it belongs to.
struct AuthorizedRequestTests {
    private static let identity = ClientIdentity(name: "Tests", version: "1.0", deviceName: "Test Device", deviceID: "test-device")

    private func signedInService() async throws -> JellyfinMediaService {
        let service = JellyfinMediaService(identity: Self.identity)
        let server = ServerInfo(id: "server", name: "Server", url: try #require(URL(string: "https://media.example.com:8920")))
        await service.restore(UserSession(server: server, userID: "user", username: "Name", accessToken: "secret"))
        return service
    }

    private func authorization(_ service: JellyfinMediaService, for address: String) async throws -> String? {
        await service.authorizedRequest(for: try #require(URL(string: address))).value(forHTTPHeaderField: "Authorization")
    }

    @Test func sendsTheTokenToItsOwnServer() async throws {
        let service = try await signedInService()
        #expect(try await authorization(service, for: "https://media.example.com:8920/Videos/1/stream") == "MediaBrowser Token=\"secret\"")
        // Host names aren't case sensitive.
        #expect(try await authorization(service, for: "https://MEDIA.example.com:8920/Items") != nil)
    }

    @Test(arguments: [
        "https://elsewhere.example.com:8920/Items",
        "http://media.example.com:8920/Items",
        "https://media.example.com/Items",
        "https://media.example.com:8921/Items",
        "https://media.example.com.evil.example/Items"
    ])
    func keepsTheTokenFromAnywhereElse(_ address: String) async throws {
        let service = try await signedInService()
        #expect(try await authorization(service, for: address) == nil)
    }

    @Test func keepsTheTokenFromFiles() async throws {
        let service = try await signedInService()
        let request = await service.authorizedRequest(for: URL(filePath: "/tmp/subtitles.vtt"))
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func hasNoTokenToSendBeforeSigningIn() async throws {
        let service = JellyfinMediaService(identity: Self.identity)
        #expect(try await authorization(service, for: "https://media.example.com:8920/Items") == nil)
    }

    @Test func hasNoTokenToSendAfterSigningOut() async throws {
        let service = try await signedInService()
        await service.signOut()
        #expect(try await authorization(service, for: "https://media.example.com:8920/Items") == nil)
    }
}

struct RedirectAuthorizationTests {
    private func request(to address: String) throws -> URLRequest {
        var request = URLRequest(url: try #require(URL(string: address)))
        request.setValue("MediaBrowser Token=\"secret\"", forHTTPHeaderField: "Authorization")
        return request
    }

    @Test func keepsTheTokenOnARedirectWithinTheServer() throws {
        let origin = try #require(URL(string: "https://media.example.com/Videos/1/Subtitles/0/0/Stream.vtt"))
        let redirected = SameOriginAuthorization.redirecting(try request(to: "https://media.example.com/other"), from: origin)
        #expect(redirected.value(forHTTPHeaderField: "Authorization") != nil)
    }

    @Test func dropsTheTokenOnARedirectElsewhere() throws {
        let origin = try #require(URL(string: "https://media.example.com/Videos/1/Subtitles/0/0/Stream.vtt"))
        for address in ["https://cdn.example.net/file", "http://media.example.com/file", "https://media.example.com:444/file"] {
            let redirected = SameOriginAuthorization.redirecting(try request(to: address), from: origin)
            #expect(redirected.value(forHTTPHeaderField: "Authorization") == nil, "\(address)")
        }
    }

    @Test func dropsTheTokenWhenWhereItStartedIsUnknown() throws {
        let redirected = SameOriginAuthorization.redirecting(try request(to: "https://media.example.com/file"), from: nil)
        #expect(redirected.value(forHTTPHeaderField: "Authorization") == nil)
    }
}

struct MapErrorTests {
    @Test func aNetworkFailureMeansTheServerIsUnreachable() {
        guard case .serverUnreachable = JellyfinMediaService.mapError(URLError(.timedOut)) else {
            Issue.record("expected serverUnreachable")
            return
        }
    }

    @Test func passesItsOwnErrorsThrough() {
        guard case .itemNotFound = JellyfinMediaService.mapError(MediaServiceError.itemNotFound) else {
            Issue.record("expected itemNotFound")
            return
        }
    }
}

struct ImageResponseTests {
    private func response(type: String?, length: Int) throws -> URLResponse {
        URLResponse(url: try #require(URL(string: "https://media.example.com/Items/1/Images/Primary")),
                    mimeType: type, expectedContentLength: length, textEncodingName: nil)
    }

    @Test func acceptsImagesAndUntypedBytes() throws {
        #expect(ImageCache.isAcceptable(try response(type: "image/jpeg", length: 200_000)))
        #expect(ImageCache.isAcceptable(try response(type: "image/webp", length: -1)))
        #expect(ImageCache.isAcceptable(try response(type: "application/octet-stream", length: 200_000)))
        #expect(ImageCache.isAcceptable(try response(type: nil, length: 200_000)))
    }

    @Test func refusesPagesAndHugeFiles() throws {
        // A captive portal or a proxy's error page, say.
        #expect(!ImageCache.isAcceptable(try response(type: "text/html", length: 2_000)))
        #expect(!ImageCache.isAcceptable(try response(type: "image/png", length: ImageCache.maxImageBytes + 1)))
        // One that didn't say how big it was, and turned out too big.
        #expect(!ImageCache.isAcceptable(try response(type: "image/png", length: -1), size: ImageCache.maxImageBytes + 1))
    }
}
