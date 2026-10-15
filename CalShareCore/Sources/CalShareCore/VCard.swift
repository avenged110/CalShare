// MARK: - VCard.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// Validation of address object resources (RFC 6352 §5.1) and the text matching used by
// addressbook-query (RFC 6352 §10.5).

import Foundation

public struct ContactInfo: Sendable, Equatable {
    public var uid: String
    public var formattedName: String
    public var isGroup: Bool
}

public enum ContactValidationError: Error, Equatable, CustomStringConvertible {
    case unparseable(String)
    case notASingleCard
    case missingVersion

    public var description: String {
        switch self {
        case .unparseable(let reason): "Not valid vCard data: \(reason)"
        case .notASingleCard: "An address object resource must hold exactly one VCARD."
        case .missingVersion: "The vCard has no VERSION."
        }
    }
}

public enum VCard {
    public static func parseCard(_ data: Data) throws(ContactValidationError) -> ContentComponent {
        guard let text = String(data: data, encoding: .utf8) else { throw .unparseable("not UTF-8") }
        let roots: [ContentComponent]
        do { roots = try ContentLineParser.parse(text) } catch { throw .unparseable(String(describing: error)) }
        guard roots.count == 1, let card = roots.first, card.name == "VCARD" else { throw .notASingleCard }
        return card
    }

    /// Validates a card. `fallbackUID` is used when the card has none (some clients omit it;
    /// rejecting them would only make contacts silently fail to sync).
    public static func validate(_ data: Data, fallbackUID: String) throws(ContactValidationError) -> ContactInfo {
        let card = try parseCard(data)
        guard card.property("VERSION") != nil else { throw .missingVersion }
        let uid = card.property("UID")?.value.trimmingCharacters(in: .whitespaces)
        let name = card.property("FN").map { ContentLineParser.unescapeText($0.value) } ?? ""
        let kind = (card.property("KIND") ?? card.property("X-ADDRESSBOOKSERVER-KIND"))?.value.lowercased()
        return ContactInfo(uid: (uid?.isEmpty == false ? uid! : fallbackUID), formattedName: name, isGroup: kind == "group")
    }

    public enum MatchType: String, Sendable { case equals, contains, startsWith = "starts-with", endsWith = "ends-with" }

    /// RFC 4790 i;unicode-casemap approximated with case- and width-insensitive folding.
    public static func textMatches(_ haystack: String, _ needle: String, _ type: MatchType) -> Bool {
        let fold: (String) -> String = { $0.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil) }
        let h = fold(haystack), n = fold(needle)
        switch type {
        case .equals: return h == n
        case .contains: return n.isEmpty || h.contains(n)
        case .startsWith: return h.hasPrefix(n)
        case .endsWith: return h.hasSuffix(n)
        }
    }

    /// Concatenates cards for a .vcf export.
    public static func merge(_ cards: [Data]) -> String {
        cards.compactMap { String(data: $0, encoding: .utf8) }
            .map { $0.hasSuffix("\n") ? $0 : $0 + "\r\n" }
            .joined()
    }

    /// Splits an imported .vcf file into its cards.
    public static func split(_ text: String) -> [ContentComponent] {
        (try? ContentLineParser.parse(text))?.filter { $0.name == "VCARD" } ?? []
    }
}
