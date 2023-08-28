//
//  SettingsSyncHandling.swift
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

import Combine
import Foundation

public struct SettingsSyncMetadataSaveError: Error {
    public let underlyingError: Error

    public init(underlyingError: Error) {
        self.underlyingError = underlyingError
    }
}

public protocol SettingsSyncHandling {
    func getValue() throws -> String?
    func setValue(_ value: String?) throws

    var setting: SettingsProvider.Setting { get }
    var shouldApplyRemoteDeleteOnInitialSync: Bool { get }
    var errorPublisher: AnyPublisher<Error, Never> { get }
}
