// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// The two kinds of list the user can add items to.
enum ListKind {
    /// An ordered list of movies and episodes.
    case playlist
    /// A group of movies or shows.
    case collection

    var addTitle: String {
        switch self {
        case .playlist: String(localized: "Add to Playlist")
        case .collection: String(localized: "Add to Collection")
        }
    }

    var newTitle: String {
        switch self {
        case .playlist: String(localized: "New Playlist")
        case .collection: String(localized: "New Collection")
        }
    }

    var nameTitle: String {
        switch self {
        case .playlist: String(localized: "Playlist Name")
        case .collection: String(localized: "Collection Name")
        }
    }

    var sectionTitle: String {
        switch self {
        case .playlist: String(localized: "Playlists")
        case .collection: String(localized: "Collections")
        }
    }

    var systemImage: String {
        switch self {
        case .playlist: "list.bullet.rectangle"
        case .collection: "square.stack"
        }
    }
}

/// Choose a playlist or collection to add items to, or make a new one with them.
struct AddToListSheet: View {
    let items: [MediaItem]
    let kind: ListKind

    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var lists: [MediaItem]?
    @State private var errorMessage: String?
    /// The list being added to, so its row can show progress and a second tap does nothing.
    @State private var addingTo: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        NewListForm(items: items, kind: kind, onCreated: { dismiss() })
                    } label: {
                        Label(kind.newTitle, systemImage: "plus")
                    }
                }

                Section {
                    if let lists {
                        ForEach(lists) { list in
                            Button {
                                add(to: list)
                            } label: {
                                HStack {
                                    Label(list.title, systemImage: kind.systemImage)
                                    Spacer()
                                    if addingTo == list.id { ProgressView() }
                                }
                            }
                            .disabled(addingTo != nil)
                        }
                    } else {
                        SkeletonLines(count: 3)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Loading")
                    }
                } header: {
                    Text(kind.sectionTitle)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(kind.addTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                #endif
            }
            .task { await load() }
        }
    }

    private func load() async {
        do {
            switch kind {
            case .playlist: lists = try await appModel.service.playlists()
            case .collection: lists = try await appModel.service.collections()
            }
        } catch {
            lists = []
            errorMessage = error.localizedDescription
        }
    }

    private func add(to list: MediaItem) {
        addingTo = list.id
        errorMessage = nil
        let (service, kind, ids) = (appModel.service, kind, items.map(\.id))
        Task {
            do {
                switch kind {
                case .playlist: try await service.addItems(withIDs: ids, toPlaylist: list.id)
                case .collection: try await service.addItems(withIDs: ids, toCollection: list.id)
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                addingTo = nil
            }
        }
    }
}

/// A name for a new playlist or collection, which is made with the items on creation.
private struct NewListForm: View {
    let items: [MediaItem]
    let kind: ListKind

    /// Called once the list exists.
    let onCreated: () -> Void

    @Environment(AppModel.self) private var appModel

    @State private var name = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Form {
            TextField(kind.nameTitle, text: $name)
                .submitLabel(.done)
                .onSubmit(create)

            Button(action: create) {
                HStack {
                    Text("Create")
                    if isCreating {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(trimmedName.isEmpty || isCreating)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }
        }
        .navigationTitle(kind.newTitle)
    }

    private func create() {
        guard !trimmedName.isEmpty, !isCreating else { return }
        isCreating = true
        errorMessage = nil
        let (service, kind, name, ids) = (appModel.service, kind, trimmedName, items.map(\.id))
        Task {
            do {
                switch kind {
                case .playlist: _ = try await service.createPlaylist(named: name, itemIDs: ids)
                case .collection: _ = try await service.createCollection(named: name, itemIDs: ids)
                }
                onCreated()
            } catch {
                errorMessage = error.localizedDescription
                isCreating = false
            }
        }
    }
}
