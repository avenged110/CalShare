// MARK: - FormatTests.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Testing
@testable import CalShareCore

@Suite struct ContentLineTests {
    @Test func unfoldsContinuationLines() {
        let lines = ContentLineParser.unfold("SUMMARY:Hello\r\n  world\r\nUID:1\n")
        #expect(lines == ["SUMMARY:Hello world", "UID:1"])
    }

    @Test func parsesQuotedParametersAndGroups() throws {
        let property = try ContentLineParser.parseLine(#"item1.ADR;TYPE=home,pref;LABEL="Home: 1 Main St; Apt 2":;;1 Main St;Town;;;"#)
        #expect(property.name == "ADR")
        #expect(property.group == "item1")
        #expect(property.parameters["TYPE"] == ["home", "pref"])
        #expect(property.parameter("LABEL") == "Home: 1 Main St; Apt 2")
        #expect(property.value == ";;1 Main St;Town;;;")
    }

    @Test func rejectsUnbalancedComponents() {
        #expect(throws: ContentParseError.self) { try ContentLineParser.parse("BEGIN:VCALENDAR\nBEGIN:VEVENT\nEND:VCALENDAR\n") }
        #expect(throws: ContentParseError.self) { try ContentLineParser.parse("BEGIN:VCALENDAR\n") }
    }

    @Test func serializationFoldsLongLinesWithoutSplittingCharacters() throws {
        var component = ContentComponent(name: "VEVENT")
        let long = String(repeating: "é", count: 100)
        component.properties = [ContentProperty(name: "SUMMARY", group: nil, parameters: [:], value: long)]
        let text = ContentLineParser.serialize(component)
        for line in text.components(separatedBy: "\r\n") { #expect(line.utf8.count <= 75) }
        let reparsed = try ContentLineParser.parse(text)
        #expect(reparsed.first?.property("SUMMARY")?.value == long)
    }
}

@Suite struct ICalendarTests {
    @Test func validatesSimpleEvent() throws {
        let info = try ICalendar.validate(Data(Fixtures.event(uid: "abc").utf8))
        #expect(info.component == "VEVENT")
        #expect(info.uid == "abc")
        #expect(info.firstOccurrence == TimeZoneResolver.utcDate("20261012T120000Z"))
        #expect(info.lastOccurrence == TimeZoneResolver.utcDate("20261012T130000Z"))
    }

    @Test func rejectsInvalidResources() {
        #expect(throws: CalendarValidationError.notACalendar) { try ICalendar.validate(Data("BEGIN:VCARD\nVERSION:3.0\nEND:VCARD\n".utf8)) }
        let noUID = Fixtures.event().replacingOccurrences(of: #"UID:[^\r]*\r\n"#, with: "", options: .regularExpression)
        #expect(throws: CalendarValidationError.missingUID) { try ICalendar.validate(Data(noUID.utf8)) }
        let twoUIDs = """
            BEGIN:VCALENDAR
            BEGIN:VEVENT
            UID:a
            DTSTART:20261012T120000Z
            END:VEVENT
            BEGIN:VEVENT
            UID:b
            DTSTART:20261012T120000Z
            END:VEVENT
            END:VCALENDAR
            """
        #expect(throws: CalendarValidationError.mixedUIDs) { try ICalendar.validate(Data(twoUIDs.utf8)) }
        let timezoneOnly = "BEGIN:VCALENDAR\nBEGIN:VTIMEZONE\nTZID:X\nEND:VTIMEZONE\nEND:VCALENDAR\n"
        #expect(throws: CalendarValidationError.noComponents) { try ICalendar.validate(Data(timezoneOnly.utf8)) }
    }

    @Test func resolvesTimeZonesAndBoundsCountedRecurrence() throws {
        let info = try ICalendar.validate(Data(Fixtures.timezoneEvent.utf8))
        // 09:00 EDT = 13:00 UTC.
        #expect(info.firstOccurrence == TimeZoneResolver.utcDate("20261012T130000Z"))
        let last = try #require(info.lastOccurrence)
        #expect(last >= TimeZoneResolver.utcDate("20261016T140000Z")!)
        #expect(last < TimeZoneResolver.utcDate("20261120T000000Z")!)
    }

    @Test func unboundedRecurrenceAndUndatedTasks() throws {
        let weekly = try ICalendar.validate(Data(Fixtures.event(extra: "RRULE:FREQ=WEEKLY\r\n").utf8))
        #expect(weekly.lastOccurrence == nil)
        let task = try ICalendar.validate(Data(Fixtures.task().utf8))
        #expect(task.component == "VTODO")
        #expect(task.firstOccurrence == nil && task.lastOccurrence == nil)
    }

    @Test func allDayEventsLastOneDay() throws {
        let allDay = Fixtures.event(start: "20261012", end: "20261012").replacingOccurrences(of: "DTEND:20261012\r\n", with: "")
        let info = try ICalendar.validate(Data(allDay.replacingOccurrences(of: "DTSTART:", with: "DTSTART;VALUE=DATE:").utf8))
        let first = try #require(info.firstOccurrence)
        let last = try #require(info.lastOccurrence)
        #expect(last.timeIntervalSince(first) >= 86_400)
    }

    @Test func parsesDurations() {
        #expect(ICalendar.parseDuration("PT1H30M") == 5_400)
        #expect(ICalendar.parseDuration("P1W") == 604_800)
        #expect(ICalendar.parseDuration("-P1DT2H") == -93_600)
        #expect(ICalendar.parseDuration("garbage") == nil)
    }

    @Test func mergeAndSplitRoundTrip() throws {
        let merged = ICalendar.merge([Data(Fixtures.event(uid: "1").utf8), Data(Fixtures.timezoneEvent.utf8)], name: "Home")
        let split = try ICalendar.split(merged)
        #expect(split.map(\.uid).sorted() == ["1", "tz-1"])
        for part in split { _ = try ICalendar.validate(part.data) }
        #expect(String(decoding: split.first { $0.uid == "tz-1" }!.data, as: UTF8.self).contains("BEGIN:VTIMEZONE"))
    }
}

@Suite struct VCardTests {
    @Test func validatesCards() throws {
        let info = try VCard.validate(Data(Fixtures.card(uid: "card-1").utf8), fallbackUID: "x")
        #expect(info.uid == "card-1")
        #expect(info.formattedName == "Ada Lovelace")
        #expect(throws: ContactValidationError.missingVersion) {
            try VCard.validate(Data("BEGIN:VCARD\nFN:x\nEND:VCARD\n".utf8), fallbackUID: "x")
        }
        let noUID = try VCard.validate(Data("BEGIN:VCARD\nVERSION:3.0\nFN:x\nEND:VCARD\n".utf8), fallbackUID: "fallback")
        #expect(noUID.uid == "fallback")
    }

    @Test func textMatching() {
        #expect(VCard.textMatches("Ada Lovelace", "love", .contains))
        #expect(VCard.textMatches("Ada Lovelace", "ADA", .startsWith))
        #expect(!VCard.textMatches("Ada Lovelace", "ada", .endsWith))
        #expect(VCard.textMatches("ÉCOLE", "école", .equals))
    }
}

@Suite struct XMLTests {
    @Test func refusesDoctypes() {
        let attack = #"<?xml version="1.0"?><!DOCTYPE x [<!ENTITY a "aaaa">]><d:propfind xmlns:d="DAV:">&a;</d:propfind>"#
        #expect(throws: XMLParseError.self) { try XMLRequestParser.parse(Data(attack.utf8)) }
    }

    @Test func parsesNamespaces() throws {
        let body = #"<A:propfind xmlns:A="DAV:"><A:prop><B:calendar-color xmlns:B="http://apple.com/ns/ical/"/></A:prop></A:propfind>"#
        let root = try XMLRequestParser.parse(Data(body.utf8))
        #expect(root.qname == QName(NS.dav, "propfind"))
        #expect(root.child(NS.dav, "prop")?.children.first?.qname == QName(NS.apple, "calendar-color"))
    }

    @Test func escapesText() {
        #expect(XMLEscape.text("a<b>&\"'\u{1}") == "a&lt;b&gt;&amp;&quot;&apos;")
    }
}

@Suite struct HTTPParserTests {
    @Test func parsesContentLengthAndPipelining() {
        var parser = HTTPRequestParser(remoteAddress: "x", isSecure: false)
        parser.feed(Data("PUT /a HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\nhelloGET /b HTTP/1.1\r\nHost: h\r\n\r\n".utf8))
        guard case .request(let first)? = parser.next() else { Issue.record("no first request"); return }
        #expect(first.method == "PUT" && first.body == Data("hello".utf8))
        guard case .request(let second)? = parser.next() else { Issue.record("no second request"); return }
        #expect(second.method == "GET" && second.path == "/b")
        #expect(parser.next() == nil)
    }

    @Test func parsesChunkedBodiesAcrossFeeds() {
        var parser = HTTPRequestParser(remoteAddress: "x", isSecure: false)
        parser.feed(Data("PUT /a HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhel".utf8))
        #expect(parser.next() == nil)
        parser.feed(Data("lo\r\n6\r\n world\r\n0\r\n\r\n".utf8))
        guard case .request(let request)? = parser.next() else { Issue.record("no request"); return }
        #expect(request.body == Data("hello world".utf8))
    }

    @Test func refusesOversizedChunks() {
        // A chunk size near Int.max after a first chunk once overflowed the running total.
        var parser = HTTPRequestParser(remoteAddress: "x", isSecure: false)
        parser.feed(Data("PUT /a HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n1\r\na\r\n7fffffffffffffff\r\n".utf8))
        guard case .error(413)? = parser.next() else { Issue.record("expected 413"); return }

        var limits = HTTPLimits()
        limits.maxBodyBytes = 10
        var small = HTTPRequestParser(limits: limits, remoteAddress: "x", isSecure: false)
        small.feed(Data("PUT /a HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n6\r\nabcdef\r\n5\r\n".utf8))
        guard case .error(413)? = small.next() else { Issue.record("expected 413"); return }
    }

    @Test func decodesChunksFedOneByteAtATime() {
        var parser = HTTPRequestParser(remoteAddress: "x", isSecure: false)
        let message = "PUT /a HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3;ext=1\r\nabc\r\n0\r\nX-Trailer: y\r\n\r\nGET /b HTTP/1.1\r\n\r\n"
        var events: [HTTPRequestParser.Event] = []
        for byte in Data(message.utf8) {
            parser.feed(Data([byte]))
            while let event = parser.next() { events.append(event) }
        }
        guard events.count == 2, case .request(let put) = events[0], case .request(let get) = events[1] else {
            Issue.record("expected two requests, got \(events.count)"); return
        }
        #expect(put.body == Data("abc".utf8))
        #expect(get.path == "/b")

        var bad = HTTPRequestParser(remoteAddress: "x", isSecure: false)
        bad.feed(Data("PUT /a HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabcX\r\n".utf8))
        guard case .error(400)? = bad.next() else { Issue.record("expected 400"); return }
    }

    @Test func refusesTransferCodingsOtherThanChunked() {
        for coding in ["gzip, chunked", "gzip", "chunked, gzip"] {
            var parser = HTTPRequestParser(remoteAddress: "x", isSecure: false)
            parser.feed(Data("PUT /a HTTP/1.1\r\nTransfer-Encoding: \(coding)\r\n\r\n".utf8))
            guard case .error(501)? = parser.next() else { Issue.record("\(coding) was accepted"); continue }
        }
        var plain = HTTPRequestParser(remoteAddress: "x", isSecure: false)
        plain.feed(Data("PUT /a HTTP/1.1\r\nTransfer-Encoding:  Chunked \r\n\r\n2\r\nhi\r\n0\r\n\r\n".utf8))
        guard case .request(let request)? = plain.next() else { Issue.record("chunked was refused"); return }
        #expect(request.body == Data("hi".utf8))
    }

    @Test func handlesExpectContinueAndLimits() {
        var parser = HTTPRequestParser(remoteAddress: "x", isSecure: false)
        parser.feed(Data("PUT /a HTTP/1.1\r\nExpect: 100-continue\r\nContent-Length: 3\r\n\r\n".utf8))
        guard case .needsContinue? = parser.next() else { Issue.record("expected continue"); return }
        parser.feed(Data("abc".utf8))
        guard case .request? = parser.next() else { Issue.record("expected request"); return }

        var limits = HTTPLimits()
        limits.maxBodyBytes = 10
        var small = HTTPRequestParser(limits: limits, remoteAddress: "x", isSecure: false)
        small.feed(Data("PUT /a HTTP/1.1\r\nContent-Length: 11\r\n\r\n".utf8))
        guard case .error(413)? = small.next() else { Issue.record("expected 413"); return }

        var garbage = HTTPRequestParser(remoteAddress: "x", isSecure: false)
        garbage.feed(Data("NONSENSE\r\n\r\n".utf8))
        guard case .error(400)? = garbage.next() else { Issue.record("expected 400"); return }
    }

    @Test func pathHandling() {
        #expect(URLPath.segments("/dav/calendars/alice/My%20Cal/") == ["dav", "calendars", "alice", "My Cal"])
        #expect(URLPath.segments("/dav/../etc/passwd") == nil)
        #expect(URLPath.segments("/dav/%2e%2e/x") == nil)
        #expect(HTTPRequest(method: "GET", target: "https://host:8443/dav/x?y=1").path == "/dav/x")
        #expect(URLPath.build(["dav", "a b"], collection: true) == "/dav/a%20b/")
    }
}

extension HTTPRequestParser.Event: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.needsContinue, .needsContinue): true
        case (.error(let a), .error(let b)): a == b
        case (.request(let a), .request(let b)): a.method == b.method && a.target == b.target
        default: false
        }
    }
}

@Suite struct AddressAndRandomTests {
    @Test func parsesNumericAddressesStrictly() {
        #expect(IPAddressBytes.parse("192.168.1.10") == Data([192, 168, 1, 10]))
        #expect(IPAddressBytes.parse("100.64.0.1") == Data([100, 64, 0, 1]))
        var loopback = Data(count: 16)
        loopback[15] = 1
        #expect(IPAddressBytes.parse("::1") == loopback)
        #expect(IPAddressBytes.parse("2001:db8::1") == Data([0x20, 0x01, 0x0d, 0xb8] + Array(repeating: 0, count: 11) + [1]))
        for shorthand in ["127.1", "1.2.3", "0x7f.0.0.1", "1.2.3.4.5", "example.com", ""] {
            #expect(IPAddressBytes.parse(shorthand) == nil)
        }
    }

    @Test func hexAndRandomBytes() {
        #expect(Hashing.sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(Hashing.fingerprint(Data()).hasPrefix("E3:B0:C4:42:98:FC"))
        #expect(RandomToken.bytes(0).isEmpty)
        #expect(RandomToken.bytes(32).count == 32)
        #expect(RandomToken.bytes(32) != RandomToken.bytes(32))
        #expect(RandomToken.urlSafe(18).count == 24)
    }
}
