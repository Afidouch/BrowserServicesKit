//
//  Suggestion.swift
//
//  Copyright © 2021 DuckDuckGo. All rights reserved.
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

public enum Suggestion: Equatable {

    case phrase(phrase: String)
    case website(url: URL)
    case bookmark(title: String, url: URL, isFavorite: Bool, allowedInTopHits: Bool)
    case historyEntry(title: String?, url: URL, allowedInTopHits: Bool)
    case internalPage(title: String, url: URL)
    case unknown(value: String)
    case weatherIA(conditionCode: String, currentTemperature: Int, highTemperature: Int, lowTemperature: Int, location: String, url: URL)

    var url: URL? {
        switch self {
        case .website(url: let url),
             .historyEntry(title: _, url: let url, allowedInTopHits: _),
             .bookmark(title: _, url: let url, isFavorite: _, allowedInTopHits: _),
             .internalPage(title: _, url: let url),
             .weatherIA(conditionCode: _, currentTemperature: _, highTemperature: _, lowTemperature: _, location: _, url: let url):
            return url
        case .phrase, .unknown:
            return nil
        }
    }

    var title: String? {
        switch self {
        case .historyEntry(title: let title, url: _, allowedInTopHits: _):
            return title
        case .bookmark(title: let title, url: _, isFavorite: _, allowedInTopHits: _),
             .internalPage(title: let title, url: _):
            return title
        case .phrase, .website, .unknown, .weatherIA:
            return nil
        }
    }

    public var allowedInTopHits: Bool {
        switch self {
        case .website:
            return true
        case .historyEntry(title: _, url: _, allowedInTopHits: let allowedInTopHits):
            return allowedInTopHits
        case .bookmark(title: _, url: _, isFavorite: _, allowedInTopHits: let allowedInTopHits):
            return allowedInTopHits
        case .internalPage, .phrase, .unknown, .weatherIA:
            return false
        }
    }

    public var isWeatherInstantAnswer: Bool {
        if case .weatherIA = self { return true }
        return false
    }

}

extension Suggestion {

    init?(bookmark: Bookmark) {
        guard let urlObject = URL(string: bookmark.url) else { return nil }
        #if os(macOS)
        self = .bookmark(title: bookmark.title,
                         url: urlObject,
                         isFavorite: bookmark.isFavorite,
                         allowedInTopHits: bookmark.isFavorite)
        #else
        self = .bookmark(title: bookmark.title,
                         url: urlObject,
                         isFavorite: bookmark.isFavorite,
                         allowedInTopHits: true)
        #endif
    }

    init(historyEntry: HistorySuggestion) {
        let areVisitsLow = historyEntry.numberOfVisits < 4
        let allowedInTopHits = !(historyEntry.failedToLoad ||
                                 (areVisitsLow && !historyEntry.url.isRoot))
        self = .historyEntry(title: historyEntry.title,
                             url: historyEntry.url,
                             allowedInTopHits: allowedInTopHits)
    }

    init(internalPage: InternalPage) {
        self = .internalPage(title: internalPage.title, url: internalPage.url)
    }

    init(url: URL) {
        self = .website(url: url)
    }

    init(phrase: String, isNav: Bool) {
        if isNav, let url = URL(string: "http://\(phrase)") {
            self = .website(url: url)
        } else {
            self = .phrase(phrase: phrase)
        }
    }

    init?(instantAnswer: InstantAnswer) {
        guard let conditionCode = instantAnswer.answer?.currentWeather?.conditionCode,
              let currentTemperature = instantAnswer.answer?.currentWeather?.temperature,
              let highTemperature = instantAnswer.answer?.forecastDaily?.days?.first?.temperatureMax,
              let lowTemperature = instantAnswer.answer?.forecastDaily?.days?.first?.temperatureMin,
              let location = instantAnswer.answer?.location,
              let urlString = instantAnswer.seeMore,
              let url = URL(string: urlString) else {
            return nil
        }
        let currentTemperatureInt = Int(currentTemperature)
        let highTemperatureInt = Int(highTemperature)
        let lowTemperatureInt = Int(lowTemperature)

        self = .weatherIA(
            conditionCode: conditionCode,
            currentTemperature: currentTemperatureInt,
            highTemperature: highTemperatureInt,
            lowTemperature: lowTemperatureInt,
            location: location,
            url: url
        )
    }

}
