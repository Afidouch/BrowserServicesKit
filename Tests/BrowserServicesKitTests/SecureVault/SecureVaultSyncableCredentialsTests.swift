//
//  SecureVaultSyncableCredentialsTests.swift
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

import GRDB
import XCTest
@testable import BrowserServicesKit

extension DefaultDatabaseProvider {
    static let testKey = "test-key".data(using: .utf8)!

    static func makeTestProvider() throws -> DefaultDatabaseProvider {
        let databaseLocation = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".db")
        return try DefaultDatabaseProvider(file: databaseLocation, key: testKey)
    }
}

class SecureVaultSyncableCredentialsTests: XCTestCase {

    let simpleL1Key = "simple-key".data(using: .utf8)!
    var databaseLocation: URL!
    var provider: DefaultDatabaseProvider!

    override func setUpWithError() throws {
        try super.setUpWithError()
        databaseLocation = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".db")
        provider = try DefaultDatabaseProvider(file: databaseLocation, key: simpleL1Key)
    }

    override func tearDownWithError() throws {
        try deleteDbFile()
        try super.tearDownWithError()
    }

    func testWhenCredentialsAreInsertedThenMetadataIsPopulated() throws {
        let account = SecureVaultModels.WebsiteAccount(username: "brindy", domain: "example.com")
        let credentials = SecureVaultModels.WebsiteCredentials(account: account, password: "password".data(using: .utf8))
        let accountId = try provider.storeWebsiteCredentials(credentials)

        let metadataObjects = try provider.modifiedWebsiteCredentialsMetadata()
        XCTAssertEqual(metadataObjects.count, 1)
        XCTAssertEqual(metadataObjects[0].objectId, accountId)
        XCTAssertNotNil(metadataObjects[0].lastModified)
    }

    func testWhenMetadataAreInsertedThenNilLastModifiedIsHonored() throws {
        let account = SecureVaultModels.WebsiteAccount(username: "brindy", domain: "example.com")
        let credentials = SecureVaultModels.WebsiteCredentials(account: account, password: "password".data(using: .utf8))
        let metadata = SecureVaultModels.WebsiteAccountSyncMetadata(id: UUID().uuidString, credential: credentials, lastModified: nil)

        try provider.inTransaction { database in
            try self.provider.storeWebsiteCredentialsMetadata(metadata, in: database)
        }

        let metadataObjects = try provider.db.read { database in
            try SecureVaultModels.WebsiteAccountSyncMetadata.fetchAll(database)
        }

        XCTAssertEqual(metadataObjects.count, 1)
        XCTAssertNil(metadataObjects[0].lastModified)
    }

    func testWhenMetadataAreInsertedThenNonNilLastModifiedIsHonored() throws {
        let account = SecureVaultModels.WebsiteAccount(username: "brindy", domain: "example.com")
        let credentials = SecureVaultModels.WebsiteCredentials(account: account, password: "password".data(using: .utf8))
        let timestamp = Date().withMillisecondPrecision
        let metadata = SecureVaultModels.WebsiteAccountSyncMetadata(id: UUID().uuidString, credential: credentials, lastModified: timestamp)

        try provider.inTransaction { database in
            try self.provider.storeWebsiteCredentialsMetadata(metadata, in: database)
        }

        let metadataObjects = try provider.db.read { database in
            try SecureVaultModels.WebsiteAccountSyncMetadata.fetchAll(database)
        }

        XCTAssertEqual(metadataObjects.count, 1)
        XCTAssertEqual(metadataObjects[0].lastModified!.timeIntervalSince1970, timestamp.timeIntervalSince1970, accuracy: 0.001)
    }

    func testWhenMetadataAreUpdatedThenNonNilLastModifiedIsHonored() throws {
        let account = SecureVaultModels.WebsiteAccount(id: "2", username: "brindy", domain: "example.com", created: Date(), lastUpdated: Date())
        let credentials = SecureVaultModels.WebsiteCredentials(account: account, password: "password".data(using: .utf8))
        let timestamp = Date().withMillisecondPrecision
        var metadata = SecureVaultModels.WebsiteAccountSyncMetadata(id: UUID().uuidString, credential: credentials, lastModified: timestamp)

        try provider.inTransaction { database in
            try self.provider.storeWebsiteCredentialsMetadata(metadata, in: database)
        }

        metadata.credential = try provider.websiteCredentialsForAccountId(2)
        metadata.credential?.account.username = "brindy2"

        try provider.inTransaction { database in
            try self.provider.storeWebsiteCredentialsMetadata(metadata, in: database)
        }

        let metadataObjects = try provider.db.read { database in
            try SecureVaultModels.WebsiteAccountSyncMetadata.fetchAll(database)
        }

        XCTAssertEqual(metadataObjects.count, 1)
        XCTAssertEqual(metadataObjects[0].lastModified!.timeIntervalSince1970, timestamp.timeIntervalSince1970, accuracy: 0.001)
    }

    func testWhenMetadataAreDeletedThenAccountAndCredentialsAreDeleted() throws {
        let account = SecureVaultModels.WebsiteAccount(id: "2", username: "brindy", domain: "example.com", created: Date(), lastUpdated: Date())
        let credentials = SecureVaultModels.WebsiteCredentials(account: account, password: "password".data(using: .utf8))
        var metadata = SecureVaultModels.WebsiteAccountSyncMetadata(id: UUID().uuidString, credential: credentials, lastModified: nil)

        try provider.inTransaction { database in
            try self.provider.storeWebsiteCredentialsMetadata(metadata, in: database)
        }

        metadata.credential = try provider.websiteCredentialsForAccountId(2)

        try provider.inTransaction { database in
            try self.provider.deleteWebsiteCredentialsMetadata(metadata, in: database)
        }

        let metadataObjects = try provider.db.read { database in
            try SecureVaultModels.WebsiteAccountSyncMetadata.fetchAll(database)
        }

        let accounts = try provider.db.read { database in
            try SecureVaultModels.WebsiteAccount.fetchAll(database)
        }

        XCTAssertTrue(metadataObjects.isEmpty)
        XCTAssertTrue(accounts.isEmpty)
        XCTAssertNil(try provider.websiteCredentialsForAccountId(2))
    }

    func testWhenPasswordIsUpdatedThenMetadataTimestampIsUpdated() throws {
        let account = SecureVaultModels.WebsiteAccount(username: "brindy", domain: "example.com")
        var credentials = SecureVaultModels.WebsiteCredentials(account: account, password: "password".data(using: .utf8))
        credentials = try storeAndFetchCredentials(credentials)
        let createdTimestamp = try provider.modifiedWebsiteCredentialsMetadata().first!.lastModified!

        credentials.password = "password2".data(using: .utf8)
        credentials = try storeAndFetchCredentials(credentials)

        let metadataObjects = try provider.modifiedWebsiteCredentialsMetadata()
        XCTAssertGreaterThan(metadataObjects[0].lastModified!, createdTimestamp)
    }

    func testWhenUsernameIsUpdatedThenMetadataTimestampIsUpdated() throws {
        let account = SecureVaultModels.WebsiteAccount(username: "brindy", domain: "example.com")
        var credentials = SecureVaultModels.WebsiteCredentials(account: account, password: "password".data(using: .utf8))
        credentials = try storeAndFetchCredentials(credentials)
        let createdTimestamp = try provider.modifiedWebsiteCredentialsMetadata().first!.lastModified!

        credentials.account.username = "brindy2"
        credentials = try storeAndFetchCredentials(credentials)

        let metadataObjects = try provider.modifiedWebsiteCredentialsMetadata()
        XCTAssertEqual(metadataObjects.count, 1)
        XCTAssertEqual(metadataObjects[0].objectId, credentials.account.id.flatMap(Int64.init))
        XCTAssertGreaterThan(metadataObjects[0].lastModified!, createdTimestamp)
    }

    func testWhenDomainIsUpdatedThenMetadataTimestampIsUpdated() throws {
        let account = SecureVaultModels.WebsiteAccount(username: "brindy", domain: "example.com")
        var credentials = SecureVaultModels.WebsiteCredentials(account: account, password: "password".data(using: .utf8))
        credentials = try storeAndFetchCredentials(credentials)
        let createdTimestamp = try provider.modifiedWebsiteCredentialsMetadata().first!.lastModified!

        credentials.account.domain = "example2.com"
        credentials = try storeAndFetchCredentials(credentials)

        let metadataObjects = try provider.modifiedWebsiteCredentialsMetadata()
        XCTAssertEqual(metadataObjects.count, 1)
        XCTAssertEqual(metadataObjects[0].objectId, credentials.account.id.flatMap(Int64.init))
        XCTAssertGreaterThan(metadataObjects[0].lastModified!, createdTimestamp)
    }

    func testWhenTitleIsUpdatedThenMetadataTimestampIsUpdated() throws {
        let account = SecureVaultModels.WebsiteAccount(username: "brindy", domain: "example.com")
        var credentials = SecureVaultModels.WebsiteCredentials(account: account, password: "password".data(using: .utf8))
        credentials = try storeAndFetchCredentials(credentials)
        let createdTimestamp = try provider.modifiedWebsiteCredentialsMetadata().first!.lastModified!

        credentials.account.title = "brindy's account"
        credentials = try storeAndFetchCredentials(credentials)

        let metadataObjects = try provider.modifiedWebsiteCredentialsMetadata()
        XCTAssertEqual(metadataObjects.count, 1)
        XCTAssertEqual(metadataObjects[0].objectId, credentials.account.id.flatMap(Int64.init))
        XCTAssertGreaterThan(metadataObjects[0].lastModified!, createdTimestamp)
    }

    func testWhenNotesIsUpdatedThenMetadataTimestampIsUpdated() throws {
        let account = SecureVaultModels.WebsiteAccount(username: "brindy", domain: "example.com")
        var credentials = SecureVaultModels.WebsiteCredentials(account: account, password: "password".data(using: .utf8))
        credentials = try storeAndFetchCredentials(credentials)
        let createdTimestamp = try provider.modifiedWebsiteCredentialsMetadata().first!.lastModified!

        credentials.account.notes = "here's my example.com login information"
        credentials = try storeAndFetchCredentials(credentials)

        let metadataObjects = try provider.modifiedWebsiteCredentialsMetadata()
        XCTAssertEqual(metadataObjects.count, 1)
        XCTAssertEqual(metadataObjects[0].objectId, credentials.account.id.flatMap(Int64.init))
        XCTAssertGreaterThan(metadataObjects[0].lastModified!, createdTimestamp)
    }

    func testWhenCredentialsAreDeletedThenMetadataIsPersisted() throws {
        let account = SecureVaultModels.WebsiteAccount(username: "brindy", domain: "example.com")
        var credentials = SecureVaultModels.WebsiteCredentials(account: account, password: "password".data(using: .utf8))
        credentials = try storeAndFetchCredentials(credentials)
        let metadata = try provider.modifiedWebsiteCredentialsMetadata().first!
        let accountId = try XCTUnwrap(metadata.objectId)

        try provider.deleteWebsiteCredentialsForAccountId(accountId)

        let metadataObjects = try provider.modifiedWebsiteCredentialsMetadata()
        XCTAssertEqual(metadataObjects.count, 1)
        XCTAssertEqual(metadataObjects[0].objectId, nil)
        XCTAssertGreaterThan(metadataObjects[0].lastModified!, metadata.lastModified!)
    }

    // MARK: - Private

    private func storeAndFetchCredentials(_ credentials: SecureVaultModels.WebsiteCredentials) throws -> SecureVaultModels.WebsiteCredentials {
        let accountId = try provider.storeWebsiteCredentials(credentials)
        return try XCTUnwrap(try provider.websiteCredentialsForAccountId(accountId))
    }

    private func deleteDbFile() throws {
        do {
            let dbFileContainer = databaseLocation.deletingLastPathComponent()
            for file in try FileManager.default.contentsOfDirectory(atPath: dbFileContainer.path) {
                guard ["db", "bak"].contains((file as NSString).pathExtension) else { continue }
                try FileManager.default.removeItem(atPath: dbFileContainer.appendingPathComponent(file).path)
            }

        } catch let error as NSError {
            // File not found
            if error.domain != NSCocoaErrorDomain || error.code != 4 {
                throw error
            }
        }
    }
}

extension Date {
    var withMillisecondPrecision: Date {
        Date(timeIntervalSince1970: TimeInterval(Int(timeIntervalSince1970 * 1_000_000) / 1_000) / 1_000)
    }
}
