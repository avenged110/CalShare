// MARK: - Fixtures.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
@testable import CalShareCore

enum Fixtures {
    static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CalShareTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func event(uid: String = UUID().uuidString, summary: String = "Lunch",
                      start: String = "20261012T120000Z", end: String = "20261012T130000Z", extra: String = "") -> String {
        """
        BEGIN:VCALENDAR\r
        VERSION:2.0\r
        PRODID:-//Apple Inc.//macOS 15.6//EN\r
        CALSCALE:GREGORIAN\r
        BEGIN:VEVENT\r
        UID:\(uid)\r
        DTSTAMP:20261009T100000Z\r
        DTSTART:\(start)\r
        DTEND:\(end)\r
        SUMMARY:\(summary)\r
        \(extra)END:VEVENT\r
        END:VCALENDAR\r

        """
    }

    static let timezoneEvent = """
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Apple Inc.//macOS 15.6//EN
        BEGIN:VTIMEZONE
        TZID:America/New_York
        BEGIN:STANDARD
        DTSTART:20071104T020000
        TZOFFSETFROM:-0400
        TZOFFSETTO:-0500
        TZNAME:EST
        END:STANDARD
        END:VTIMEZONE
        BEGIN:VEVENT
        UID:tz-1
        DTSTART;TZID=America/New_York:20261012T090000
        DTEND;TZID=America/New_York:20261012T100000
        SUMMARY:Standup
        RRULE:FREQ=DAILY;COUNT=5
        END:VEVENT
        END:VCALENDAR
        """

    static func task(uid: String = UUID().uuidString, summary: String = "Buy milk") -> String {
        """
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Apple Inc.//iOS 18.6//EN
        BEGIN:VTODO
        UID:\(uid)
        DTSTAMP:20261009T100000Z
        SUMMARY:\(summary)
        END:VTODO
        END:VCALENDAR
        """
    }

    static func card(uid: String = UUID().uuidString, name: String = "Ada Lovelace", email: String = "ada@example.com") -> String {
        let parts = name.split(separator: " ")
        return """
        BEGIN:VCARD\r
        VERSION:3.0\r
        PRODID:-//Apple Inc.//macOS 15.6//EN\r
        N:\(parts.last ?? "");\(parts.first ?? "");;;\r
        FN:\(name)\r
        item1.EMAIL;type=INTERNET;type=pref:\(email)\r
        TEL;type=CELL;type=VOICE;type=pref:+1 555 0100\r
        UID:\(uid)\r
        END:VCARD\r

        """
    }

    /// A store with one user ("alice", password "correct horse") and a handler over it.
    static func handler() throws -> (DAVHandler, Store, User) {
        let directory = temporaryDirectory()
        let store = try Store(url: directory.appendingPathComponent("test.sqlite"))
        let user = try store.createUser(username: "alice", displayName: "Alice",
                                        passwordHash: PasswordHasher.hash("correct horse", iterations: 1_000))
        let handler = DAVHandler(store: store, authenticator: Authenticator(store: store))
        return (handler, store, user)
    }

    static let authorization = "Basic " + Data("alice:correct horse".utf8).base64EncodedString()

    static func request(_ method: String, _ path: String, body: String = "", headers: [(String, String)] = [],
                        authorized: Bool = true) -> HTTPRequest {
        var allHeaders = HTTPHeaders(headers)
        if authorized { allHeaders["Authorization"] = authorization }
        if !body.isEmpty && allHeaders["Content-Type"] == nil {
            allHeaders["Content-Type"] = "application/xml; charset=utf-8"
        }
        return HTTPRequest(method: method, target: path, headers: allHeaders, body: Data(body.utf8),
                           remoteAddress: "192.168.1.20", isSecure: true)
    }
}

extension HTTPResponse {
    var text: String { String(decoding: body, as: UTF8.self) }

    /// Parses a multistatus body into href → (property local name → value text, status).
    func multistatus() throws -> [String: (props: [String: String], missing: Set<String>, status: String?)] {
        let root = try XMLRequestParser.parse(body)
        var result: [String: (props: [String: String], missing: Set<String>, status: String?)] = [:]
        for response in root.children(NS.dav, "response") {
            let href = response.child(NS.dav, "href")?.trimmedText ?? ""
            var props: [String: String] = [:]
            var missing = Set<String>()
            for propstat in response.children(NS.dav, "propstat") {
                let ok = propstat.child(NS.dav, "status")?.trimmedText.contains(" 200 ") ?? false
                for prop in propstat.child(NS.dav, "prop")?.children ?? [] {
                    if ok { props[prop.qname.name] = prop.children.isEmpty ? prop.trimmedText : prop.innerXML }
                    else { missing.insert(prop.qname.name) }
                }
            }
            result[href] = (props, missing, response.child(NS.dav, "status")?.trimmedText)
        }
        return result
    }
}
