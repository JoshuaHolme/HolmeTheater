// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import JellyfinAPI

// Collections (the server's "box sets") and playlists: listing them, making them, and changing what's in them.

extension JellyfinMediaService {
    // MARK: - Collections

    func collections() async throws -> [MediaItem] {
        let (client, session) = try signedIn()
        let request = Paths.getItems(parameters: .init(
            userID: session.userID,
            isRecursive: true,
            sortOrder: [.ascending],
            fields: Self.itemFields,
            includeItemTypes: [.boxSet],
            sortBy: [.sortName],
            enableUserData: true
        ))
        return try await mapItems(send(request, with: client), client: client)
    }

    func createCollection(named name: String, itemIDs: [String]) async throws -> MediaItem {
        let (client, _) = try signedIn()
        let created = try await send(Paths.createCollection(parameters: .init(name: name, ids: itemIDs)), with: client)
        guard let id = created.id else { throw MediaServiceError.underlying(String(localized: "The server didn't create the collection.")) }
        return try await item(id: id)
    }

    func addItems(withIDs itemIDs: [String], toCollection collectionID: String) async throws {
        let (client, _) = try signedIn()
        try await send(Paths.addToCollection(collectionID: collectionID, ids: itemIDs), with: client)
    }

    func removeItems(withIDs itemIDs: [String], fromCollection collectionID: String) async throws {
        let (client, _) = try signedIn()
        try await send(Paths.removeFromCollection(collectionID: collectionID, ids: itemIDs), with: client)
    }

    // MARK: - Playlists

    func playlists() async throws -> [MediaItem] {
        let (client, session) = try signedIn()
        let request = Paths.getItems(parameters: .init(
            userID: session.userID,
            isRecursive: true,
            sortOrder: [.ascending],
            fields: Self.itemFields,
            includeItemTypes: [.playlist],
            sortBy: [.sortName],
            enableUserData: true
        ))
        return try await mapItems(send(request, with: client), client: client)
    }

    func createPlaylist(named name: String, itemIDs: [String]) async throws -> MediaItem {
        let (client, session) = try signedIn()
        let body = CreatePlaylistDto(ids: itemIDs, name: name, userID: session.userID)
        let created = try await send(Paths.createPlaylist(body), with: client)
        guard let id = created.id else { throw MediaServiceError.underlying(String(localized: "The server didn't create the playlist.")) }
        return try await item(id: id)
    }

    func addItems(withIDs itemIDs: [String], toPlaylist playlistID: String) async throws {
        let (client, session) = try signedIn()
        let request = Paths.addItemToPlaylist(
            playlistID: playlistID,
            parameters: .init(ids: itemIDs, userID: session.userID)
        )
        try await send(request, with: client)
    }

    func removeEntries(withIDs entryIDs: [String], fromPlaylist playlistID: String) async throws {
        let (client, _) = try signedIn()
        try await send(Paths.removeItemFromPlaylist(playlistID: playlistID, entryIDs: entryIDs), with: client)
    }

    func moveEntry(withID entryID: String, inPlaylist playlistID: String, to index: Int) async throws {
        let (client, _) = try signedIn()
        try await send(Paths.moveItem(playlistID: playlistID, itemID: entryID, newIndex: index), with: client)
    }
}
