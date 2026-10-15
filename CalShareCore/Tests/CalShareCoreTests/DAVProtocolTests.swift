// MARK: - DAVProtocolTests.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// Drives the handler with the request sequences Apple's Calendar, Reminders and Contacts
// send while adding an account and syncing.

import Foundation
import Testing
@testable import CalShareCore

@Suite struct DAVProtocolTests {
    @Test func discoveryLikeAppleAccountSetup() throws {
        let (handler, _, _) = try Fixtures.handler()

        let wellKnown = handler.handle(Fixtures.request("PROPFIND", "/.well-known/caldav", authorized: false))
        #expect(wellKnown.status == 301)
        #expect(wellKnown.headers["Location"] == "/dav/")

        let anonymous = handler.handle(Fixtures.request("PROPFIND", "/dav/", authorized: false))
        #expect(anonymous.status == 401)
        #expect(anonymous.headers["WWW-Authenticate"]?.hasPrefix("Basic realm=\"CalShare\"") == true)

        let options = handler.handle(Fixtures.request("OPTIONS", "/dav/", authorized: false))
        #expect(options.headers["DAV"]?.contains("calendar-access") == true)
        #expect(options.headers["DAV"]?.contains("addressbook") == true)

        let principalQuery = """
            <?xml version="1.0" encoding="UTF-8"?>
            <A:propfind xmlns:A="DAV:"><A:prop><A:current-user-principal/><A:principal-URL/><A:resourcetype/></A:prop></A:propfind>
            """
        let root = handler.handle(Fixtures.request("PROPFIND", "/", body: principalQuery, headers: [("Depth", "0")]))
        #expect(root.status == 207)
        let rootProps = try root.multistatus()
        #expect(rootProps["/"]?.props["current-user-principal"]?.contains("/dav/principals/alice/") == true)

        let homeQuery = """
            <A:propfind xmlns:A="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav" xmlns:D="urn:ietf:params:xml:ns:carddav" xmlns:E="http://calendarserver.org/ns/">
            <A:prop><C:calendar-home-set/><D:addressbook-home-set/><C:calendar-user-address-set/><A:displayname/>
            <C:schedule-inbox-URL/><E:email-address-set/><A:supported-report-set/></A:prop></A:propfind>
            """
        let principal = try handler.handle(Fixtures.request("PROPFIND", "/dav/principals/alice/", body: homeQuery, headers: [("Depth", "0")])).multistatus()
        let entry = try #require(principal["/dav/principals/alice/"])
        #expect(entry.props["calendar-home-set"]?.contains("/dav/calendars/alice/") == true)
        #expect(entry.props["addressbook-home-set"]?.contains("/dav/addressbooks/alice/") == true)
        #expect(entry.props["displayname"] == "Alice")
        #expect(entry.missing.contains("schedule-inbox-URL"))

        let forbidden = handler.handle(Fixtures.request("PROPFIND", "/dav/principals/mallory/", headers: [("Depth", "0")]))
        #expect(forbidden.status == 403)
    }

    @Test func listsCalendarsWithAppleProperties() throws {
        let (handler, _, _) = try Fixtures.handler()
        let query = """
            <A:propfind xmlns:A="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav" xmlns:B="http://calendarserver.org/ns/" xmlns:I="http://apple.com/ns/ical/">
            <A:prop><A:resourcetype/><A:displayname/><C:supported-calendar-component-set/><I:calendar-color/><I:calendar-order/>
            <B:getctag/><A:sync-token/><A:current-user-privilege-set/><A:quota-available-bytes/></A:prop></A:propfind>
            """
        let response = handler.handle(Fixtures.request("PROPFIND", "/dav/calendars/alice/", body: query, headers: [("Depth", "1")]))
        #expect(response.status == 207)
        let results = try response.multistatus()
        let calendar = try #require(results["/dav/calendars/alice/calendar/"])
        #expect(calendar.props["resourcetype"]?.contains("calendar") == true)
        #expect(calendar.props["calendar-color"] == "#1BADF8FF")
        #expect(calendar.props["supported-calendar-component-set"]?.contains("VEVENT") == true)
        #expect(calendar.props["sync-token"]?.hasPrefix(DAVHandler.syncTokenPrefix) == true)
        #expect(calendar.props["current-user-privilege-set"]?.contains("write") == true)
        #expect(calendar.missing.contains("quota-available-bytes"))
        #expect(results["/dav/calendars/alice/reminders/"]?.props["supported-calendar-component-set"]?.contains("VTODO") == true)

        let infinite = handler.handle(Fixtures.request("PROPFIND", "/dav/calendars/alice/", headers: [("Depth", "infinity")]))
        #expect(infinite.status == 403)
    }

    @Test func createEditAndDeleteEvents() throws {
        let (handler, _, _) = try Fixtures.handler()
        let path = "/dav/calendars/alice/calendar/E1.ics"
        let created = handler.handle(Fixtures.request("PUT", path, body: Fixtures.event(uid: "E1"),
                                                      headers: [("Content-Type", "text/calendar"), ("If-None-Match", "*")]))
        #expect(created.status == 201)
        let etag = try #require(created.headers["ETag"])

        let again = handler.handle(Fixtures.request("PUT", path, body: Fixtures.event(uid: "E1"), headers: [("If-None-Match", "*")]))
        #expect(again.status == 412)

        let get = handler.handle(Fixtures.request("GET", path))
        #expect(get.status == 200 && get.headers["ETag"] == etag && get.text.contains("SUMMARY:Lunch"))
        #expect(handler.handle(Fixtures.request("GET", path, headers: [("If-None-Match", etag)])).status == 304)
        #expect(handler.handle(Fixtures.request("HEAD", path)).omitBody)

        let stale = handler.handle(Fixtures.request("PUT", path, body: Fixtures.event(uid: "E1", summary: "Dinner"), headers: [("If-Match", "\"stale\"")]))
        #expect(stale.status == 412)
        let updated = handler.handle(Fixtures.request("PUT", path, body: Fixtures.event(uid: "E1", summary: "Dinner"), headers: [("If-Match", etag)]))
        #expect(updated.status == 204 && updated.headers["ETag"] != etag)

        let conflict = handler.handle(Fixtures.request("PUT", "/dav/calendars/alice/calendar/other.ics", body: Fixtures.event(uid: "E1")))
        #expect(conflict.status == 409 && conflict.text.contains("no-uid-conflict"))

        let wrongKind = handler.handle(Fixtures.request("PUT", "/dav/calendars/alice/reminders/x.ics", body: Fixtures.event()))
        #expect(wrongKind.status == 403 && wrongKind.text.contains("supported-calendar-component"))

        let invalid = handler.handle(Fixtures.request("PUT", "/dav/calendars/alice/calendar/bad.ics", body: "hello"))
        #expect(invalid.status == 403 && invalid.text.contains("valid-calendar-data"))

        let missingParent = handler.handle(Fixtures.request("PUT", "/dav/calendars/alice/nope/x.ics", body: Fixtures.event()))
        #expect(missingParent.status == 409)

        #expect(handler.handle(Fixtures.request("DELETE", path, headers: [("If-Match", "\"stale\"")])).status == 412)
        #expect(handler.handle(Fixtures.request("DELETE", path)).status == 204)
        #expect(handler.handle(Fixtures.request("GET", path)).status == 404)
        #expect(handler.handle(Fixtures.request("DELETE", path)).status == 404)
    }

    @Test func syncCollectionReportsChangesAndDeletions() throws {
        let (handler, _, _) = try Fixtures.handler()
        let collection = "/dav/calendars/alice/calendar/"
        func sync(_ token: String) throws -> (HTTPResponse, String) {
            let body = """
                <A:sync-collection xmlns:A="DAV:"><A:sync-token>\(token)</A:sync-token><A:sync-level>1</A:sync-level>
                <A:prop><A:getetag/><A:getcontenttype/></A:prop></A:sync-collection>
                """
            let response = handler.handle(Fixtures.request("REPORT", collection, body: body, headers: [("Depth", "1")]))
            let root = try XMLRequestParser.parse(response.body)
            return (response, root.child(NS.dav, "sync-token")?.trimmedText ?? "")
        }
        let (initial, token0) = try sync("")
        #expect(initial.status == 207 && !token0.isEmpty)
        #expect(try initial.multistatus().isEmpty)

        _ = handler.handle(Fixtures.request("PUT", collection + "a.ics", body: Fixtures.event(uid: "a")))
        _ = handler.handle(Fixtures.request("PUT", collection + "b.ics", body: Fixtures.event(uid: "b")))
        let (first, token1) = try sync(token0)
        let firstResults = try first.multistatus()
        #expect(Set(firstResults.keys) == [collection + "a.ics", collection + "b.ics"])
        #expect(firstResults[collection + "a.ics"]?.props["getetag"]?.hasPrefix("\"") == true)

        _ = handler.handle(Fixtures.request("DELETE", collection + "a.ics"))
        _ = handler.handle(Fixtures.request("PUT", collection + "b.ics", body: Fixtures.event(uid: "b", summary: "Changed")))
        let (second, token2) = try sync(token1)
        let secondResults = try second.multistatus()
        #expect(secondResults[collection + "a.ics"]?.status?.contains("404") == true)
        #expect(secondResults[collection + "b.ics"]?.props["getetag"] != nil)

        let (quiet, token3) = try sync(token2)
        #expect(try quiet.multistatus().isEmpty && token3 == token2)

        let (bad, _) = try sync(DAVHandler.syncTokenPrefix + "999/1")
        #expect(bad.status == 403 && bad.text.contains("valid-sync-token"))

        // A restored database starts a new token generation: every token issued before is
        // refused (so the client resyncs in full), and new ones work.
        try handler.store.renewSyncEpoch()
        let (stale, _) = try sync(token3)
        #expect(stale.status == 403 && stale.text.contains("valid-sync-token"))
        let (fresh, token4) = try sync("")
        #expect(fresh.status == 207 && token4 != token3)
        let (afterRestore, _) = try sync(token4)
        #expect(try afterRestore.status == 207 && afterRestore.multistatus().isEmpty)
    }

    @Test func multigetAndCalendarQuery() throws {
        let (handler, _, _) = try Fixtures.handler()
        let collection = "/dav/calendars/alice/calendar/"
        _ = handler.handle(Fixtures.request("PUT", collection + "oct.ics", body: Fixtures.event(uid: "oct", summary: "October")))
        _ = handler.handle(Fixtures.request("PUT", collection + "dec.ics", body: Fixtures.event(uid: "dec", summary: "December", start: "20261215T120000Z", end: "20261215T130000Z")))
        _ = handler.handle(Fixtures.request("PUT", collection + "tz.ics", body: Fixtures.timezoneEvent))

        let multiget = """
            <C:calendar-multiget xmlns:A="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
            <A:prop><A:getetag/><C:calendar-data/></A:prop>
            <A:href>\(collection)oct.ics</A:href><A:href>https://mac.local:8443\(collection)dec.ics</A:href><A:href>\(collection)missing.ics</A:href>
            </C:calendar-multiget>
            """
        let results = try handler.handle(Fixtures.request("REPORT", collection, body: multiget, headers: [("Depth", "1")])).multistatus()
        #expect(results[collection + "oct.ics"]?.props["calendar-data"]?.contains("SUMMARY:October") == true)
        #expect(results[collection + "dec.ics"]?.props["calendar-data"]?.contains("December") == true)
        #expect(results[collection + "missing.ics"]?.status?.contains("404") == true)

        func query(_ filter: String) throws -> Set<String> {
            let body = """
                <C:calendar-query xmlns:A="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"><A:prop><A:getetag/></A:prop>
                <C:filter><C:comp-filter name="VCALENDAR">\(filter)</C:comp-filter></C:filter></C:calendar-query>
                """
            return Set(try handler.handle(Fixtures.request("REPORT", collection, body: body, headers: [("Depth", "1")])).multistatus().keys)
        }
        #expect(try query(#"<C:comp-filter name="VEVENT"><C:time-range start="20261001T000000Z" end="20261101T000000Z"/></C:comp-filter>"#)
                == [collection + "oct.ics", collection + "tz.ics"])
        #expect(try query(#"<C:comp-filter name="VEVENT"><C:time-range start="20261201T000000Z"/></C:comp-filter>"#) == [collection + "dec.ics"])
        #expect(try query(#"<C:comp-filter name="VEVENT"><C:prop-filter name="UID"><C:text-match>dec</C:text-match></C:prop-filter></C:comp-filter>"#)
                == [collection + "dec.ics"])
        #expect(try query(#"<C:comp-filter name="VTODO"/>"#).isEmpty)
        #expect(try query("").count == 3)
    }

    @Test func mkcalendarProppatchAndDelete() throws {
        let (handler, store, user) = try Fixtures.handler()
        let path = "/dav/calendars/alice/7F3C-NEW/"
        let body = """
            <C:mkcalendar xmlns:A="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav" xmlns:I="http://apple.com/ns/ical/">
            <A:set><A:prop><A:displayname>Work</A:displayname><I:calendar-color>#FF2968FF</I:calendar-color>
            <C:supported-calendar-component-set><C:comp name="VEVENT"/></C:supported-calendar-component-set>
            <C:calendar-free-busy-set/></A:prop></A:set></C:mkcalendar>
            """
        #expect(handler.handle(Fixtures.request("MKCALENDAR", path, body: body)).status == 201)
        #expect(handler.handle(Fixtures.request("MKCALENDAR", path, body: body)).status == 405)
        let created = try #require(try store.collection(ownerID: user.id, kind: .calendar, uri: "7F3C-NEW"))
        #expect(created.displayName == "Work" && created.color == "#FF2968FF" && created.components == ["VEVENT"])

        let patch = """
            <A:propertyupdate xmlns:A="DAV:" xmlns:I="http://apple.com/ns/ical/" xmlns:X="http://example.com/ns">
            <A:set><A:prop><A:displayname>Work Stuff</A:displayname><I:calendar-order>4</I:calendar-order><X:custom>keep me</X:custom></A:prop></A:set>
            </A:propertyupdate>
            """
        let patched = try handler.handle(Fixtures.request("PROPPATCH", path, body: patch)).multistatus()
        #expect(patched[path]?.props.keys.contains("displayname") == true)
        let refreshed = try #require(try store.collection(ownerID: user.id, kind: .calendar, uri: "7F3C-NEW"))
        #expect(refreshed.displayName == "Work Stuff" && refreshed.order == 4)

        let readBack = """
            <A:propfind xmlns:A="DAV:" xmlns:X="http://example.com/ns"><A:prop><X:custom/></A:prop></A:propfind>
            """
        let props = try handler.handle(Fixtures.request("PROPFIND", path, body: readBack, headers: [("Depth", "0")])).multistatus()
        #expect(props[path]?.props["custom"] == "keep me")

        let protected = """
            <A:propertyupdate xmlns:A="DAV:"><A:set><A:prop><A:displayname>X</A:displayname><A:getetag>"x"</A:getetag></A:prop></A:set></A:propertyupdate>
            """
        let rejected = handler.handle(Fixtures.request("PROPPATCH", path, body: protected)).text
        #expect(rejected.contains("403") && rejected.contains("424"))
        #expect(try store.collection(ownerID: user.id, kind: .calendar, uri: "7F3C-NEW")?.displayName == "Work Stuff")

        #expect(handler.handle(Fixtures.request("DELETE", path)).status == 204)
        #expect(try store.collection(ownerID: user.id, kind: .calendar, uri: "7F3C-NEW") == nil)
    }

    @Test func remindersListsAndTasks() throws {
        let (handler, _, _) = try Fixtures.handler()
        let path = "/dav/calendars/alice/groceries/"
        let body = """
            <B:mkcalendar xmlns:B="urn:ietf:params:xml:ns:caldav" xmlns:A="DAV:"><A:set><A:prop><A:displayname>Groceries</A:displayname>
            <B:supported-calendar-component-set><B:comp name="VTODO"/></B:supported-calendar-component-set></A:prop></A:set></B:mkcalendar>
            """
        #expect(handler.handle(Fixtures.request("MKCALENDAR", path, body: body)).status == 201)
        #expect(handler.handle(Fixtures.request("PUT", path + "t1.ics", body: Fixtures.task(uid: "t1"))).status == 201)
        let query = """
            <C:calendar-query xmlns:A="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"><A:prop><A:getetag/></A:prop>
            <C:filter><C:comp-filter name="VCALENDAR"><C:comp-filter name="VTODO">
            <C:prop-filter name="COMPLETED"><C:is-not-defined/></C:prop-filter></C:comp-filter></C:comp-filter></C:filter></C:calendar-query>
            """
        let results = try handler.handle(Fixtures.request("REPORT", path, body: query, headers: [("Depth", "1")])).multistatus()
        #expect(results.keys.contains(path + "t1.ics"))
    }

    @Test func contactsFlow() throws {
        let (handler, store, user) = try Fixtures.handler()
        let book = "/dav/addressbooks/alice/contacts/"
        let home = """
            <A:propfind xmlns:A="DAV:" xmlns:D="urn:ietf:params:xml:ns:carddav"><A:prop><A:resourcetype/><D:supported-address-data/><A:sync-token/></A:prop></A:propfind>
            """
        let listing = try handler.handle(Fixtures.request("PROPFIND", "/dav/addressbooks/alice/", body: home, headers: [("Depth", "1")])).multistatus()
        #expect(listing[book]?.props["resourcetype"]?.contains("addressbook") == true)

        #expect(handler.handle(Fixtures.request("PUT", book + "ada.vcf", body: Fixtures.card(uid: "ada"), headers: [("Content-Type", "text/vcard")])).status == 201)
        #expect(handler.handle(Fixtures.request("PUT", book + "grace.vcf", body: Fixtures.card(uid: "grace", name: "Grace Hopper", email: "grace@navy.mil"))).status == 201)
        #expect(handler.handle(Fixtures.request("PUT", book + "bad.vcf", body: "BEGIN:VCARD\nFN:x\nEND:VCARD\n")).status == 403)

        let query = """
            <C:addressbook-query xmlns:A="DAV:" xmlns:C="urn:ietf:params:xml:ns:carddav"><A:prop><A:getetag/><C:address-data/></A:prop>
            <C:filter test="anyof"><C:prop-filter name="EMAIL"><C:text-match collation="i;unicode-casemap" match-type="ends-with">NAVY.MIL</C:text-match></C:prop-filter></C:filter>
            </C:addressbook-query>
            """
        let results = try handler.handle(Fixtures.request("REPORT", book, body: query, headers: [("Depth", "1")])).multistatus()
        #expect(Set(results.keys) == [book + "grace.vcf"])
        #expect(results[book + "grace.vcf"]?.props["address-data"]?.contains("Grace Hopper") == true)

        // A limit below zero once trapped in prefix(_:); it now returns no matches.
        let negative = """
            <C:addressbook-query xmlns:A="DAV:" xmlns:C="urn:ietf:params:xml:ns:carddav"><A:prop><A:getetag/></A:prop>
            <C:limit><C:nresults>-1</C:nresults></C:limit></C:addressbook-query>
            """
        let limited = handler.handle(Fixtures.request("REPORT", book, body: negative, headers: [("Depth", "1")]))
        #expect(limited.status == 207)
        #expect(try limited.multistatus().keys.allSatisfy { !$0.hasSuffix(".vcf") })

        let multiget = """
            <C:addressbook-multiget xmlns:A="DAV:" xmlns:C="urn:ietf:params:xml:ns:carddav"><A:prop><C:address-data/></A:prop>
            <A:href>\(book)ada.vcf</A:href></C:addressbook-multiget>
            """
        #expect(try handler.handle(Fixtures.request("REPORT", book, body: multiget)).multistatus()[book + "ada.vcf"]?.props["address-data"]?.contains("Ada") == true)

        let export = handler.handle(Fixtures.request("GET", book))
        #expect(export.text.components(separatedBy: "BEGIN:VCARD").count == 3)

        // The only address book can't be deleted, contacts and all; it can once there's another.
        #expect(handler.handle(Fixtures.request("DELETE", book)).status == 403)
        #expect(try store.collections(ownerID: user.id, kind: .addressBook).count == 1)
        try store.createCollection(ownerID: user.id, kind: .addressBook, uri: "work", displayName: "Work")
        #expect(handler.handle(Fixtures.request("DELETE", book)).status == 204)
        #expect(try store.collections(ownerID: user.id, kind: .addressBook).map(\.uri) == ["work"])
    }

    @Test func keepsTheLastEventCalendar() throws {
        let (handler, store, user) = try Fixtures.handler()
        let calendar = "/dav/calendars/alice/calendar/"
        let reminders = "/dav/calendars/alice/reminders/"
        // The last calendar for events stays, and says why.
        let refused = handler.handle(Fixtures.request("DELETE", calendar))
        #expect(refused.status == 403 && refused.text.contains("at least one calendar"))
        // Reminders lists aren't held back.
        #expect(handler.handle(Fixtures.request("DELETE", reminders)).status == 204)
        // With a second event calendar, either may go, but not both.
        let body = """
            <C:mkcalendar xmlns:A="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"><A:set><A:prop><A:displayname>Work</A:displayname></A:prop></A:set></C:mkcalendar>
            """
        #expect(handler.handle(Fixtures.request("MKCALENDAR", "/dav/calendars/alice/work/", body: body)).status == 201)
        #expect(handler.handle(Fixtures.request("DELETE", calendar)).status == 204)
        #expect(handler.handle(Fixtures.request("DELETE", "/dav/calendars/alice/work/")).status == 403)
        #expect(try store.collections(ownerID: user.id, kind: .calendar).map(\.uri) == ["work"])
    }

    @Test func refusedMkcolLeavesNothingBehind() throws {
        let (handler, store, user) = try Fixtures.handler()
        let body = """
            <C:mkcalendar xmlns:A="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"><A:set><A:prop><A:displayname>X</A:displayname>
            <A:getetag>"x"</A:getetag></A:prop></A:set></C:mkcalendar>
            """
        let response = handler.handle(Fixtures.request("MKCALENDAR", "/dav/calendars/alice/bad/", body: body))
        #expect(response.status == 207 && response.text.contains("403"))
        #expect(try store.collection(ownerID: user.id, kind: .calendar, uri: "bad") == nil)
        // The name is free for a valid attempt afterward.
        let valid = """
            <C:mkcalendar xmlns:A="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"><A:set><A:prop><A:displayname>X</A:displayname></A:prop></A:set></C:mkcalendar>
            """
        #expect(handler.handle(Fixtures.request("MKCALENDAR", "/dav/calendars/alice/bad/", body: valid)).status == 201)
    }

    @Test func calendarQueryOnOneObjectHonorsTimeRange() throws {
        let (handler, _, _) = try Fixtures.handler()
        let path = "/dav/calendars/alice/calendar/lunch.ics"
        #expect(handler.handle(Fixtures.request("PUT", path, body: Fixtures.event(uid: "lunch"))).status == 201)
        func query(_ start: String, _ end: String) throws -> Bool {
            let body = """
                <C:calendar-query xmlns:A="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"><A:prop><A:getetag/></A:prop>
                <C:filter><C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT"><C:time-range start="\(start)" end="\(end)"/>
                </C:comp-filter></C:comp-filter></C:filter></C:calendar-query>
                """
            return try handler.handle(Fixtures.request("REPORT", path, body: body)).multistatus().keys.contains(path)
        }
        // The event is 12:00–13:00 UTC on October 12, 2026.
        #expect(try query("20261012T000000Z", "20261013T000000Z"))
        #expect(try query("20261012T125900Z", "20261012T130100Z"))
        #expect(try !query("20261013T000000Z", "20261014T000000Z"))
        #expect(try !query("20261012T130000Z", "20261012T140000Z"))
        #expect(try !query("20261011T000000Z", "20261012T120000Z"))
    }

    @Test func extendedMkcolCreatesAddressBooks() throws {
        let (handler, store, user) = try Fixtures.handler()
        let body = """
            <A:mkcol xmlns:A="DAV:" xmlns:D="urn:ietf:params:xml:ns:carddav"><A:set><A:prop>
            <A:resourcetype><A:collection/><D:addressbook/></A:resourcetype><A:displayname>Work</A:displayname></A:prop></A:set></A:mkcol>
            """
        #expect(handler.handle(Fixtures.request("MKCOL", "/dav/addressbooks/alice/work/", body: body)).status == 201)
        #expect(try store.collection(ownerID: user.id, kind: .addressBook, uri: "work")?.displayName == "Work")
        #expect(handler.handle(Fixtures.request("MKCOL", "/dav/addressbooks/alice/plain/")).status == 403)
        #expect(handler.handle(Fixtures.request("MKCOL", "/dav/calendars/alice/oops/", body: body)).status == 403)
    }

    @Test func moveBetweenCalendars() throws {
        let (handler, store, user) = try Fixtures.handler()
        let body = #"<C:mkcalendar xmlns:C="urn:ietf:params:xml:ns:caldav"/>"#
        #expect(handler.handle(Fixtures.request("MKCALENDAR", "/dav/calendars/alice/work/", body: body)).status == 201)
        _ = handler.handle(Fixtures.request("PUT", "/dav/calendars/alice/calendar/m.ics", body: Fixtures.event(uid: "m")))
        let moved = handler.handle(Fixtures.request("MOVE", "/dav/calendars/alice/calendar/m.ics",
                                                    headers: [("Destination", "https://mac.local:8443/dav/calendars/alice/work/m.ics")]))
        #expect(moved.status == 201)
        let work = try #require(try store.collection(ownerID: user.id, kind: .calendar, uri: "work"))
        #expect(try store.resource(collectionID: work.id, uri: "m.ics") != nil)
        #expect(handler.handle(Fixtures.request("GET", "/dav/calendars/alice/calendar/m.ics")).status == 404)

        // Moving a resource onto itself is refused and must never lose it.
        let onto = handler.handle(Fixtures.request("MOVE", "/dav/calendars/alice/work/m.ics",
                                                   headers: [("Destination", "/dav/calendars/alice/work/m.ics")]))
        #expect(onto.status == 403)
        #expect(try store.resource(collectionID: work.id, uri: "m.ics") != nil)
        #expect(try store.moveResource(from: work.id, uri: "m.ics", to: work.id, newURI: "m.ics", overwrite: true) == false)
        #expect(try store.resource(collectionID: work.id, uri: "m.ics") != nil)
    }

    @Test func expandPropertyAndUnsupportedReports() throws {
        let (handler, _, _) = try Fixtures.handler()
        let body = """
            <A:expand-property xmlns:A="DAV:"><A:property name="calendar-proxy-write-for" namespace="http://calendarserver.org/ns/">
            <A:property name="displayname" namespace="DAV:"/></A:property><A:property name="displayname" namespace="DAV:"/></A:expand-property>
            """
        let response = handler.handle(Fixtures.request("REPORT", "/dav/principals/alice/", body: body, headers: [("Depth", "0")]))
        #expect(response.status == 207)
        #expect(try response.multistatus()["/dav/principals/alice/"]?.props["displayname"] == "Alice")

        let unknown = handler.handle(Fixtures.request("REPORT", "/dav/calendars/alice/calendar/", body: #"<C:free-busy-query xmlns:C="urn:ietf:params:xml:ns:caldav"/>"#))
        #expect(unknown.status == 403 && unknown.text.contains("supported-report"))
        #expect(handler.handle(Fixtures.request("PROPFIND", "/dav/", body: "<not xml")).status == 400)
    }
}
