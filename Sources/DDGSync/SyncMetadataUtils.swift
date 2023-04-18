//
//  SyncMetadataUtils.swift
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

import Foundation
import CoreData

public struct SyncFeatureUtils {

    public static func fetchFeature(with name: String, in context: NSManagedObjectContext) -> SyncFeatureEntity? {
        let request = SyncFeatureEntity.fetchRequest()
        request.predicate = NSPredicate(format: "%K == %@", #keyPath(SyncFeatureEntity.name), name)
        request.returnsObjectsAsFaults = true
        request.fetchLimit = 1

        return try? context.fetch(request).first
    }

    public static func updateTimestamp(_ timestamp: String?, forFeatureNamed name: String, in context: NSManagedObjectContext) {
        let feature = Self.fetchFeature(with: name, in: context)

        feature?.lastModified = timestamp
    }

}
