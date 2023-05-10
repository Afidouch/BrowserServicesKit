//
//  SyncBookmarksProvider.swift
//
//  Copyright © 2023 DuckDuckGo. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import Foundation
import Bookmarks
import CoreData
import Persistence
import DDGSync

public final class SyncBookmarksProvider: DataProviding {

    public init(database: CoreDataDatabase, metadataStore: SyncMetadataStore, reloadBookmarksAfterSync: @escaping () -> Void) {
        self.database = database
        self.metadataStore = metadataStore
        self.metadataStore.registerFeature(named: feature.name)
        self.reloadBookmarksAfterSync = reloadBookmarksAfterSync
    }

    // MARK: - DataProviding

    public let feature: Feature = .init(name: "bookmarks")

    public var lastSyncTimestamp: String? {
        get {
            metadataStore.timestamp(forFeatureNamed: feature.name)
        }
        set {
            metadataStore.updateTimestamp(newValue, forFeatureNamed: feature.name)
        }
    }

    public func prepareForFirstSync() async throws {
        lastSyncTimestamp = nil

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var saveError: Error?

            let context = database.makeContext(concurrencyType: .privateQueueConcurrencyType)

            context.performAndWait {
                let fetchRequest = BookmarkEntity.fetchRequest()
                let bookmarks = (try? context.fetch(fetchRequest)) ?? []
                for bookmark in bookmarks {
                    bookmark.modifiedAt = Date()
                }

                do {
                    try context.save()
                } catch {
                    saveError = error
                }
            }

            if let saveError {
                continuation.resume(with: .failure(saveError))
            } else {
                continuation.resume()
            }
        }
    }

    public func fetchChangedObjects(encryptedUsing crypter: Crypting) async throws -> [Syncable] {
        return await withCheckedContinuation { continuation in

            let context = database.makeContext(concurrencyType: .privateQueueConcurrencyType)

            var syncableBookmarks: [Syncable] = []
            context.performAndWait {
                let bookmarks = BookmarkUtils.fetchModifiedBookmarks(context)
                syncableBookmarks = bookmarks.compactMap { try? Syncable(bookmark: $0, encryptedWith: crypter) }
            }
            continuation.resume(with: .success(syncableBookmarks))
        }
    }

    public func handleInitialSyncResponse(received: [Syncable], timestamp: String?, crypter: Crypting) async throws {
        await withCheckedContinuation { continuation in
            var saveError: Error?

            let context = database.makeContext(concurrencyType: .privateQueueConcurrencyType)

            context.performAndWait {
                processReceivedBookmarks(received, deduplicate: true, in: context, using: crypter)

                let insertedObjects = Array(context.insertedObjects).compactMap { $0 as? BookmarkEntity }
                let updatedObjects = Array(context.updatedObjects.subtracting(context.deletedObjects)).compactMap { $0 as? BookmarkEntity }

                do {
                    try context.save()
                    (insertedObjects + updatedObjects).forEach { $0.modifiedAt = nil }
                    try context.save()
                } catch {
                    saveError = error
                }
            }
            if let saveError {
                print("SAVE ERROR", saveError)
            } else if let timestamp {
                lastSyncTimestamp = timestamp
                reloadBookmarksAfterSync()
            }

            continuation.resume()
        }
    }

    public func handleSyncResponse(sent: [Syncable], received: [Syncable], timestamp: String?, crypter: Crypting) async {
        await withCheckedContinuation { continuation in
            var saveError: Error?

            let context = database.makeContext(concurrencyType: .privateQueueConcurrencyType)

            context.performAndWait {
                cleanUpSentItems(sent, in: context)
                processReceivedBookmarks(received, deduplicate: false, in: context, using: crypter)

                let insertedObjects = Array(context.insertedObjects).compactMap { $0 as? BookmarkEntity }
                let updatedObjects = Array(context.updatedObjects.subtracting(context.deletedObjects)).compactMap { $0 as? BookmarkEntity }

                do {
                    try context.save()
                    (insertedObjects + updatedObjects).forEach { $0.modifiedAt = nil }
                    try context.save()
                } catch {
                    saveError = error
                }
            }
            if let saveError {
                print("SAVE ERROR", saveError)
            } else if let timestamp {
                lastSyncTimestamp = timestamp
                reloadBookmarksAfterSync()
            }

            continuation.resume()
        }
    }

    // MARK: - Internal

    func cleanUpSentItems(_ sent: [Syncable], in context: NSManagedObjectContext) {
        if sent.isEmpty {
            return
        }
        let identifiers = sent.compactMap(\.uuid)
        let bookmarks = BookmarkEntity.fetchBookmarks(with: identifiers, in: context)
        for bookmark in bookmarks {
            if bookmark.isPendingDeletion {
                context.delete(bookmark)
            } else {
                bookmark.modifiedAt = nil
            }
        }
    }

    func processReceivedBookmarks(_ received: [Syncable], deduplicate: Bool, in context: NSManagedObjectContext, using crypter: Crypting) {
        if received.isEmpty {
            return
        }

        var bookmarksIndex = ReceivedBookmarksIndex(received: received, in: context)

        for topLevelFolderSyncable in bookmarksIndex.topLevelFoldersSyncables {
            processTopLevelFolder(topLevelFolderSyncable, deduplicate: deduplicate, bookmarksIndex: &bookmarksIndex, in: context, using: crypter)
        }
        processOrphanedBookmarks(withBookmarksIndex: &bookmarksIndex, deduplicate: deduplicate, in: context, using: crypter)

        // populate favorites
        if !bookmarksIndex.favoritesUUIDs.isEmpty {
            guard let favoritesFolder = BookmarkUtils.fetchFavoritesFolder(context) else {
                // Error - unable to process favorites
                return
            }

            // For non-first sync we rely fully on the server response
            if !deduplicate {
                favoritesFolder.favoritesArray.forEach { $0.removeFromFavorites() }
            }

            bookmarksIndex.favoritesUUIDs.forEach { uuid in
                if let bookmark = bookmarksIndex.entitiesByUUID[uuid] {
                    bookmark.removeFromFavorites()
                    bookmark.addToFavorites(favoritesRoot: favoritesFolder)
                }
            }
        }
    }

    // MARK: - Private

    private func processTopLevelFolder(_ topLevelFolderSyncable: Syncable, deduplicate: Bool, bookmarksIndex: inout ReceivedBookmarksIndex, in context: NSManagedObjectContext, using crypter: Crypting) {
        guard let topLevelFolderUUID = topLevelFolderSyncable.uuid else {
            return
        }
        var queues: [[String]] = [topLevelFolderSyncable.children]
        var parentUUIDs: [String] = [topLevelFolderUUID]

        if topLevelFolderUUID != BookmarkEntity.Constants.rootFolderID {
            processEntity(with: topLevelFolderSyncable, bookmarksIndex: &bookmarksIndex, deduplicate: deduplicate, in: context, using: crypter)
        }

        while !queues.isEmpty {
            var queue = queues.removeFirst()
            let parentUUID = parentUUIDs.removeFirst()
            let parent = BookmarkEntity.fetchFolder(withUUID: parentUUID, in: context)
            assert(parent != nil)

            // For non-first sync we rely fully on the server response
            if !deduplicate {
                parent?.childrenArray.forEach { parent?.removeFromChildren($0) }
            }

            while !queue.isEmpty {
                let syncableUUID = queue.removeFirst()

                if let syncable = bookmarksIndex.receivedByUUID[syncableUUID] {
                    processEntity(with: syncable, parent: parent, bookmarksIndex: &bookmarksIndex, deduplicate: deduplicate, in: context, using: crypter)
                    if syncable.isFolder, !syncable.children.isEmpty {
                        queues.append(syncable.children)
                        parentUUIDs.append(syncableUUID)
                    }
                } else if let existingEntity = bookmarksIndex.entitiesByUUID[syncableUUID] {
                    existingEntity.parent = nil
                    existingEntity.parent = parent
                }
            }
        }
    }

    private func processOrphanedBookmarks(withBookmarksIndex bookmarksIndex: inout ReceivedBookmarksIndex, deduplicate: Bool, in context: NSManagedObjectContext, using crypter: Crypting) {

        for syncable in bookmarksIndex.bookmarkSyncablesWithoutParent {
            guard !syncable.isFolder else {
                assertionFailure("Bookmark folder passed to \(#function)")
                continue
            }

            processEntity(with: syncable, bookmarksIndex: &bookmarksIndex, deduplicate: deduplicate, in: context, using: crypter)
        }
    }

    private func processEntity(
        with syncable: Syncable,
        parent: BookmarkEntity? = nil,
        bookmarksIndex: inout ReceivedBookmarksIndex,
        deduplicate: Bool,
        in context: NSManagedObjectContext,
        using crypter: Crypting
    ) {
        guard let syncableUUID = syncable.uuid else {
            return
        }

        if deduplicate, let deduplicatedEntity = BookmarkEntity.deduplicatedEntity(with: syncable, parentUUID: parent?.uuid, in: context, using: crypter) {

            if let oldUUID = deduplicatedEntity.uuid {
                bookmarksIndex.entitiesByUUID.removeValue(forKey: oldUUID)
            }
            bookmarksIndex.entitiesByUUID[syncableUUID] = deduplicatedEntity
            deduplicatedEntity.uuid = syncableUUID
            if parent != nil {
                deduplicatedEntity.parent = nil
                deduplicatedEntity.parent = parent
            }

        } else if let existingEntity = bookmarksIndex.entitiesByUUID[syncableUUID] {

            try? existingEntity.update(with: syncable, in: context, using: crypter)
            if parent != nil {
                existingEntity.parent = nil
                existingEntity.parent = parent
            }

        } else if !syncable.isDeleted {

            let newEntity = BookmarkEntity.make(withUUID: syncableUUID, isFolder: syncable.isFolder, in: context)
            newEntity.parent = parent
            try? newEntity.update(with: syncable, in: context, using: crypter)
            bookmarksIndex.entitiesByUUID[syncableUUID] = newEntity
        }
    }

    private let database: CoreDataDatabase
    private let metadataStore: SyncMetadataStore
    private let reloadBookmarksAfterSync: () -> Void
}
