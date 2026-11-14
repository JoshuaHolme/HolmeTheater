// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

extension String {
    /// The text with HTML character references (`&amp;`, `&nbsp;`, `&#39;`, `&#x2014;`) turned into the characters they
    /// stand for. Ones it doesn't know are left as they are.
    nonisolated func decodingHTMLEntities() -> String {
        guard contains("&") else { return self }
        var result = ""
        var rest = self[...]
        while let ampersand = rest.firstIndex(of: "&") {
            result += rest[..<ampersand]
            let afterAmpersand = rest.index(after: ampersand)
            // A reference is short; a lone "&" in ordinary text has no ";" soon after it.
            guard let semicolon = rest[afterAmpersand...].prefix(10).firstIndex(of: ";") else {
                result += "&"
                rest = rest[afterAmpersand...]
                continue
            }
            let name = rest[afterAmpersand..<semicolon]
            if let decoded = Self.decodeEntity(named: name) {
                result += decoded
                rest = rest[rest.index(after: semicolon)...]
            } else {
                result += "&"
                rest = rest[afterAmpersand...]
            }
        }
        return result + rest
    }

    /// The named references this decoder knows, besides numeric ones.
    private nonisolated static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "ndash": "\u{2013}", "mdash": "\u{2014}", "hellip": "\u{2026}", "copy": "\u{00A9}", "reg": "\u{00AE}",
        "trade": "\u{2122}", "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}"
    ]

    /// The character a reference's name stands for (the part between `&` and `;`), or nil if it isn't one this knows.
    private nonisolated static func decodeEntity(named name: Substring) -> String? {
        if name.hasPrefix("#x") || name.hasPrefix("#X") {
            return UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        if name.hasPrefix("#") {
            return UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        return namedEntities[String(name)]
    }

    /// The text with HTML tags removed and `<br>` turned into line breaks, for a server's HTML shown as plain text.
    nonisolated func strippingHTMLTags() -> String {
        replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .decodingHTMLEntities()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
