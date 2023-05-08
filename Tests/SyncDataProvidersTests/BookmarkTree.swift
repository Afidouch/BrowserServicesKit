//
//  BookmarkTree.swift
//  DuckDuckGo
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

import Bookmarks
import CoreData
import Foundation
import XCTest

enum BookmarkTreeNode {
    case bookmark(id: String, name: String?, url: String?, isFavorite: Bool, isDeleted: Bool)
    case folder(id: String, name: String?, children: [BookmarkTreeNode], isDeleted: Bool)

    var id: String {
        switch self {
        case .bookmark(let id, _, _, _, _):
            return id
        case .folder(let id, _, _, _):
            return id
        }
    }

    var name: String? {
        switch self {
        case .bookmark(_, let name, _, _, _):
            return name
        case .folder(_, let name, _, _):
            return name
        }
    }

    var isDeleted: Bool {
        switch self {
        case .bookmark(_, _, _, _, let isDeleted):
            return isDeleted
        case .folder(_, _, _, let isDeleted):
            return isDeleted
        }
    }
}

protocol BookmarkTreeNodeConvertible {
    func asBookmarkTreeNode() -> BookmarkTreeNode
}

struct Bookmark: BookmarkTreeNodeConvertible {
    var id: String
    var name: String?
    var url: String?
    var isFavorite: Bool
    var isDeleted: Bool

    init(_ name: String? = nil, id: String? = nil, url: String? = nil, isFavorite: Bool = false, isDeleted: Bool = false) {
        self.id = id ?? UUID().uuidString
        self.name = name ?? id
        self.url = (url ?? name) ?? id
        self.isFavorite = isFavorite
        self.isDeleted = isDeleted
    }

    func asBookmarkTreeNode() -> BookmarkTreeNode {
        .bookmark(id: id, name: name, url: url, isFavorite: isFavorite, isDeleted: isDeleted)
    }
}

struct Folder: BookmarkTreeNodeConvertible {
    var id: String
    var name: String?
    var isDeleted: Bool
    var children: [BookmarkTreeNode]

    init(_ name: String? = nil, id: String? = nil, isDeleted: Bool = false, @BookmarkTreeBuilder builder: () -> [BookmarkTreeNode] = { [] }) {
        self.id = id ?? UUID().uuidString
        self.name = name ?? id
        self.isDeleted = isDeleted
        self.children = builder()
    }

    func asBookmarkTreeNode() -> BookmarkTreeNode {
        .folder(id: id, name: name, children: children, isDeleted: isDeleted)
    }
}

@resultBuilder
struct BookmarkTreeBuilder {

    static func buildBlock(_ components: BookmarkTreeNodeConvertible...) -> [BookmarkTreeNode] {
        components.compactMap { $0.asBookmarkTreeNode() }
    }
}


struct BookmarkTree {

    init(@BookmarkTreeBuilder builder: () -> [BookmarkTreeNode]) {
        self.bookmarkTreeNodes = builder()
    }

    @discardableResult
    func createEntities(in context: NSManagedObjectContext) -> BookmarkEntity {
        let rootFolder = BookmarkUtils.fetchRootFolder(context)!
        let favoritesFolder = BookmarkUtils.fetchFavoritesFolder(context)!
        for bookmarkTreeNode in bookmarkTreeNodes {
            BookmarkEntity.make(with: bookmarkTreeNode, rootFolder: rootFolder, favoritesFolder: favoritesFolder, in: context)
        }
        return rootFolder
    }

    var bookmarkTreeNodes: [BookmarkTreeNode]
}

extension BookmarkEntity {
    @discardableResult
    static func make(with treeNode: BookmarkTreeNode, rootFolder: BookmarkEntity, favoritesFolder: BookmarkEntity, in context: NSManagedObjectContext) -> BookmarkEntity {
        var entity: BookmarkEntity!

        var queues: [[BookmarkTreeNode]] = [[treeNode]]
        var parents: [BookmarkEntity] = [rootFolder]

        while !queues.isEmpty {
            var queue = queues.removeFirst()
            let parent = parents.removeFirst()

            while !queue.isEmpty {
                let node = queue.removeFirst()

                switch node {
                case .bookmark(let id, let name, let url, let isFavorite, let isDeleted):
                    let bookmarkEntity = BookmarkEntity(context: context)
                    if entity == nil {
                        entity = bookmarkEntity
                    }
                    bookmarkEntity.uuid = id
                    bookmarkEntity.parent = parent
                    bookmarkEntity.isFolder = false
                    bookmarkEntity.title = name
                    bookmarkEntity.url = url
                    if isFavorite {
                        bookmarkEntity.addToFavorites(favoritesRoot: favoritesFolder)
                    }
                    if isDeleted {
                        bookmarkEntity.markPendingDeletion()
                    }
                case .folder(let id, let name, let children, let isDeleted):
                    let bookmarkEntity = BookmarkEntity(context: context)
                    if entity == nil {
                        entity = bookmarkEntity
                    }
                    bookmarkEntity.uuid = id
                    bookmarkEntity.parent = parent
                    bookmarkEntity.isFolder = true
                    bookmarkEntity.title = name
                    if isDeleted {
                        bookmarkEntity.markPendingDeletion()
                    }
                    parents.append(bookmarkEntity)
                    queues.append(children)
                }
            }
        }

        return entity
    }
}


extension XCTestCase {
    func assertEquivalent(_ bookmarkEntity: BookmarkEntity, _ tree: BookmarkTree, file: StaticString = #file, line: UInt = #line) {
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = bookmarkEntity.managedObjectContext?.persistentStoreCoordinator

        context.performAndWait {
            context.deleteAll(matching: BookmarkEntity.fetchRequest())
            BookmarkUtils.prepareFoldersStructure(in: context)
            let rootFolder = tree.createEntities(in: context)
            let thisFolder = bookmarkEntity
            XCTAssertEqual(rootFolder.uuid, thisFolder.uuid, file: file, line: line)

            var tempTreeQueue: [BookmarkEntity] = [rootFolder]
            var thisTreeQueue: [BookmarkEntity] = [thisFolder]

            while !tempTreeQueue.isEmpty {
                let tempNode = tempTreeQueue.removeFirst()
                let thisNode = thisTreeQueue.removeFirst()

                XCTAssertEqual(tempNode.uuid, thisNode.uuid, file: file, line: line)
                XCTAssertEqual(tempNode.title, thisNode.title, file: file, line: line)
                XCTAssertEqual(tempNode.url, thisNode.url, file: file, line: line)
                XCTAssertEqual(tempNode.isFolder, thisNode.isFolder, file: file, line: line)
                XCTAssertEqual(tempNode.isPendingDeletion, thisNode.isPendingDeletion, file: file, line: line)
                XCTAssertEqual(tempNode.children?.count, thisNode.children?.count, file: file, line: line)
                XCTAssertEqual(tempNode.isFavorite, thisNode.isFavorite, file: file, line: line)

                if tempNode.isFolder {
                    tempTreeQueue.append(contentsOf: tempNode.childrenArray)
                    thisTreeQueue.append(contentsOf: thisNode.childrenArray)
                }
            }
        }
    }
}
