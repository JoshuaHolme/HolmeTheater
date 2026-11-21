// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import HolmeTheater

/// A store in a new folder of its own, in the temporary directory, showing `scope`'s downloads.
private func makeStore(scope: String = "scope") -> DownloadStore {
    let store = DownloadStore(root: FileManager.default.temporaryDirectory.appending(path: "DownloadStoreTests-\(UUID().uuidString)"))
    store.scope = scope
    return store
}

struct DownloadStoreKeyTests {
    @Test func aKeyRoundTrips() {
        let key = DownloadStore.key(scope: "https://server|user", id: "item-1")
        let (scope, id) = DownloadStore.parse(key: key, fallbackScope: "other")
        #expect(scope == "https://server|user")
        #expect(id == "item-1")
    }

    @Test func aBareIDBelongsToTheSignedInAccount() {
        let (scope, id) = DownloadStore.parse(key: "item-1", fallbackScope: "current")
        #expect(scope == "current")
        #expect(id == "item-1")
    }

    @Test func onlyPlainNamesAreUsedAsFolders() {
        #expect(DownloadStore.isPlainName("abc-123"))
        #expect(!DownloadStore.isPlainName(""))
        #expect(!DownloadStore.isPlainName(".."))
        #expect(!DownloadStore.isPlainName("a/b"))
        #expect(!DownloadStore.isPlainName("é"))
    }

    @Test func aDownloadOfAnIDThatIsntAPlainNameStaysInsideItsFolder() {
        let store = makeStore()
        let directory = store.itemDirectory(for: "../../escape")
        // Resolved, as the temporary directory is reached through a symbolic link.
        #expect(directory.resolvingSymlinksInPath().path().hasPrefix(store.root.resolvingSymlinksInPath().path()))
        #expect(!directory.path().contains(".."))
    }
}

struct DownloadStoreResumeDataTests {
    private func request(authorization token: String) throws -> URLRequest {
        var request = URLRequest(url: try #require(URL(string: "https://jellyfin.example.com/Videos/m/stream")))
        request.setValue("MediaBrowser Token=\"\(token)\"", forHTTPHeaderField: "Authorization")
        return request
    }

    @Test func findsTheTokenInTheHeaderOrTheQuery() throws {
        #expect(DownloadStore.tokenFingerprint(in: try request(authorization: "abc")) == DownloadStore.tokenFingerprint("abc"))
        let old = URLRequest(url: try #require(URL(string: "https://jellyfin.example.com/stream?apikey=abc")))
        #expect(DownloadStore.tokenFingerprint(in: old) == DownloadStore.tokenFingerprint("abc"))
        #expect(DownloadStore.tokenFingerprint(in: URLRequest(url: try #require(URL(string: "https://jellyfin.example.com")))) == nil)
        #expect(DownloadStore.tokenFingerprint(in: nil) == nil)
    }

    @Test func givesResumeDataBackOnceForTheSameToken() throws {
        let store = makeStore()
        store.save(Sample.record(Sample.movie(id: "m"), state: .paused))
        let key = DownloadStore.key(scope: "scope", id: "m")
        store.saveResumeData(Data([1, 2, 3]), key: key, request: try request(authorization: "abc"))

        #expect(store.takeResumeData(key: key, tokenFingerprint: DownloadStore.tokenFingerprint("abc")) == Data([1, 2, 3]))
        // Taken, so it's gone.
        #expect(store.takeResumeData(key: key, tokenFingerprint: DownloadStore.tokenFingerprint("abc")) == nil)
    }

    @Test func throwsAwayResumeDataMadeWithAnotherToken() throws {
        let store = makeStore()
        store.save(Sample.record(Sample.movie(id: "m"), state: .paused))
        let key = DownloadStore.key(scope: "scope", id: "m")
        store.saveResumeData(Data([1, 2, 3]), key: key, request: try request(authorization: "old"))

        #expect(store.takeResumeData(key: key, tokenFingerprint: DownloadStore.tokenFingerprint("new")) == nil)
        // It held a token the server no longer takes, so it isn't kept for later either.
        #expect(store.takeResumeData(key: key, tokenFingerprint: DownloadStore.tokenFingerprint("old")) == nil)
    }

    @Test func keepsNoResumeDataForARemovedDownload() throws {
        let store = makeStore()
        let key = DownloadStore.key(scope: "scope", id: "m")
        store.saveResumeData(Data([1]), key: key, request: try request(authorization: "abc"))
        #expect(store.takeResumeData(key: key, tokenFingerprint: DownloadStore.tokenFingerprint("abc")) == nil)
    }

    @Test func removingResumeDataAtSignOutLeavesNoneBehind() throws {
        let store = makeStore()
        store.save(Sample.record(Sample.movie(id: "m"), state: .paused))
        let key = DownloadStore.key(scope: "scope", id: "m")
        store.saveResumeData(Data([1]), key: key, request: try request(authorization: "abc"))
        store.removeResumeData()
        #expect(store.takeResumeData(key: key, tokenFingerprint: DownloadStore.tokenFingerprint("abc")) == nil)
    }
}

struct DownloadStoreRecordTests {
    @Test func eachAccountSeesOnlyItsOwnDownloads() {
        let store = makeStore(scope: "alice")
        store.save(Sample.record(Sample.movie(id: "a"), scope: "alice"))
        store.save(Sample.record(Sample.movie(id: "b"), scope: "bob"))
        #expect(store.records.map(\.id) == ["a"])
        store.scope = "bob"
        #expect(store.records.map(\.id) == ["b"])
        #expect(store.record(id: "a") == nil)
    }

    @Test func removingADownloadForgetsArtworkNothingElseUses() throws {
        let store = makeStore()
        let shared = try #require(URL(string: "https://jellyfin.example.com/Items/shared/Images/Backdrop"))
        let own = try #require(URL(string: "https://jellyfin.example.com/Items/m/Images/Primary"))
        var first = Sample.movie(id: "m")
        first.posterURL = own
        first.backdropURL = shared
        var second = Sample.movie(id: "n")
        second.backdropURL = shared
        store.save(Sample.record(first))
        store.save(Sample.record(second))
        store.saveArtwork(Data([1]), for: own)
        store.saveArtwork(Data([2]), for: shared)

        store.remove(ids: ["m"])
        #expect(store.record(id: "m") == nil)
        #expect(!store.hasArtwork(for: own))
        #expect(store.hasArtwork(for: shared))
    }

    @Test func savedArtworkStandsInForTheServers() throws {
        let store = makeStore()
        let poster = try #require(URL(string: "https://jellyfin.example.com/Items/m/Images/Primary"))
        var movie = Sample.movie(id: "m")
        movie.posterURL = poster
        store.saveArtwork(Data([1]), for: poster)
        #expect(store.localized(movie).posterURL?.isFileURL == true)
    }

    @Test func movesOldRecordsUnderTheirAccountAndDropsSavedTokens() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "DownloadStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // As an earlier version saved it: keyed by the bare item ID, with a subtitle URL that carried the token.
        var record = Sample.record(Sample.movie(id: "m"), scope: "alice")
        let subtitle = try #require(URL(string: "https://jellyfin.example.com/Subtitles/0/Stream.vtt?ApiKey=secret"))
        record.info = PlaybackInfo(
            url: URL(filePath: "/"), resumePosition: 0, playSessionID: nil, mediaSourceID: "source", method: .directPlay,
            subtitleTracks: [MediaTrack(index: 0, title: "English", isExternal: true, url: subtitle, format: .webVTT)]
        )
        var index = DownloadIndex()
        index.records["m"] = record
        DownloadIndexWriter.write(index, to: root.appending(path: "index.json"))

        let store = DownloadStore(root: root)
        let migrated = try #require(store.record(key: DownloadStore.key(scope: "alice", id: "m")))
        #expect(store.record(key: "m") == nil)
        #expect(migrated.info?.subtitleTracks.first?.url == nil)
    }
}
