// MARK: - LargeCollectionTests.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// Collections at real-world size, over real connections. A 1.5 MB listing once stalled
// partway on a real network until the idle timer closed the connection, and the client
// took the cut-off body as complete; nothing local caught it, because loopback never
// stalls and every count looked plausible. These check exact counts and exact sizes.

import Foundation
import Network
import Security
import Testing
@testable import CalShareCore

@Suite(.serialized) struct LargeCollectionTests {

    static let eventCount = 10_000
    /// Events start every three hours from here; every 25th repeats weekly with no end.
    static let base = ISO8601DateFormatter().date(from: "2024-01-01T00:00:00Z")!
    static func start(_ index: Int) -> Date { base.addingTimeInterval(Double(index) * 3 * 3600) }
    static func isRecurring(_ index: Int) -> Bool { index % 25 == 0 }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    static func event(_ index: Int) -> String {
        let start = start(index)
        return Fixtures.event(uid: "large-\(index)", summary: "Show s\(String(format: "%02d", index % 10)) e\(String(format: "%02d", index % 30)) — a long-ish title to give each listing entry realistic weight",
                              start: stamp(start), end: stamp(start.addingTimeInterval(3600)),
                              extra: isRecurring(index) ? "RRULE:FREQ=WEEKLY\r\n" : "")
    }

    /// Counts DAV:response elements, and fails on any parse error: the parser Apple's
    /// clients use is the one that gave up on a cut-off body.
    static func responses(in data: Data) throws -> [String: String] {
        final class Collector: NSObject, XMLParserDelegate {
            var hrefs: [String: String] = [:]
            var href = "", data = "", text = ""
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                        attributes: [String: String] = [:]) { text = "" }
            func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
            func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
                switch name {
                case "href" where href.isEmpty: href = text
                case "calendar-data": data = text
                case "response": hrefs[href] = data; href = ""; data = ""
                default: break
                }
            }
        }
        let collector = Collector()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = collector
        guard parser.parse() else { throw parser.parserError ?? CocoaError(.coderReadCorrupt) }
        return collector.hrefs
    }

    static func send(_ session: URLSession, _ method: String, _ url: String, body: String? = nil,
                     headers: [String: String] = [:]) async throws -> (Int, Data, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.httpBody = body.map { Data($0.utf8) }
        request.timeoutInterval = 120
        request.setValue("Basic " + Data("carol:integration-pass".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        // The whole body, exactly: the failure this suite exists for was a short body
        // delivered without an error.
        #expect(http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init) == data.count, "\(method) \(url)")
        return (http.statusCode, data, http)
    }

    // MARK: 10,000 events, every way a device reads them

    @Test func tenThousandEventsSyncCompletely() async throws {
        let directory = Fixtures.temporaryDirectory()
        let supervisor = try IntegrationTests.makeSupervisor(at: directory)
        supervisor.start()
        defer { supervisor.stop() }
        let ports = try await IntegrationTests.waitForPorts(supervisor)
        try supervisor.createAccount(username: "carol", displayName: "Carol", password: "integration-pass")
        let session = try IntegrationTests.session(for: supervisor)
        let calendar = "https://127.0.0.1:\(ports.https)/dav/calendars/carol/calendar/"

        // Uploaded the way a Mac imports: one PUT each, several at a time.
        try await withThrowingTaskGroup(of: Int.self) { group in
            for lane in 0..<8 {
                group.addTask {
                    var created = 0
                    for index in stride(from: lane, to: Self.eventCount, by: 8) {
                        let (status, _, _) = try await Self.send(session, "PUT", calendar + "large-\(index).ics", body: Self.event(index),
                                                                 headers: ["Content-Type": "text/calendar; charset=utf-8"])
                        if status == 201 { created += 1 }
                    }
                    return created
                }
            }
            var total = 0
            for try await created in group { total += created }
            #expect(total == Self.eventCount)
        }
        let everyHref = Set((0..<Self.eventCount).map { "/dav/calendars/carol/calendar/large-\($0).ics" })

        // The listing a first sync starts with: the one iOS gave up on.
        let (listStatus, listData, _) = try await Self.send(session, "PROPFIND", calendar,
            body: #"<d:propfind xmlns:d="DAV:"><d:prop><d:getetag/><d:getcontenttype/><d:resourcetype/></d:prop></d:propfind>"#,
            headers: ["Depth": "1"])
        #expect(listStatus == 207 && listData.count > 2_000_000)
        let listed = try Self.responses(in: listData)
        #expect(Set(listed.keys).subtracting(["/dav/calendars/carol/calendar/"]) == everyHref)

        // sync-collection from nothing, as an incremental-capable client starts.
        let (syncStatus, syncData, _) = try await Self.send(session, "REPORT", calendar, body: """
            <d:sync-collection xmlns:d="DAV:"><d:sync-token/><d:sync-level>1</d:sync-level><d:prop><d:getetag/></d:prop></d:sync-collection>
            """, headers: ["Depth": "1"])
        #expect(syncStatus == 207)
        #expect(Set(try Self.responses(in: syncData).keys) == everyHref)

        // Every event's data, in one multiget: a large request body and a larger response.
        let hrefs = everyHref.sorted().map { "<d:href>\($0)</d:href>" }.joined()
        let (getStatus, getData, _) = try await Self.send(session, "REPORT", calendar, body: """
            <c:calendar-multiget xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop><d:getetag/><c:calendar-data/></d:prop>\(hrefs)</c:calendar-multiget>
            """, headers: ["Depth": "1"])
        #expect(getStatus == 207 && getData.count > 5_000_000)
        let fetched = try Self.responses(in: getData)
        #expect(Set(fetched.keys) == everyHref)
        #expect(fetched.values.allSatisfy { $0.contains("BEGIN:VEVENT") })

        // The unfiltered search the bulk-edit script first used.
        let (allStatus, allData, _) = try await Self.send(session, "REPORT", calendar, body: """
            <c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop><d:getetag/><c:calendar-data/></d:prop><c:filter><c:comp-filter name="VCALENDAR"/></c:filter></c:calendar-query>
            """, headers: ["Depth": "1"])
        #expect(allStatus == 207)
        #expect(Set(try Self.responses(in: allData).keys) == everyHref)

        // A time-range search, as iOS syncs with a window like "6 months back": exactly the
        // one-off events that start in it, plus every weekly series begun before its end.
        let first = 4_000, last = 5_500
        let (rangeStatus, rangeData, _) = try await Self.send(session, "REPORT", calendar, body: """
            <c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop><d:getetag/></d:prop>\
            <c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VEVENT">\
            <c:time-range start="\(Self.stamp(Self.start(first)))" end="\(Self.stamp(Self.start(last)))"/>\
            </c:comp-filter></c:comp-filter></c:filter></c:calendar-query>
            """, headers: ["Depth": "1"])
        #expect(rangeStatus == 207)
        let expected = Set((0..<Self.eventCount).filter { Self.isRecurring($0) ? $0 < last : (first..<last).contains($0) }
            .map { "/dav/calendars/carol/calendar/large-\($0).ics" })
        #expect(Set(try Self.responses(in: rangeData).keys) == expected)

        // Verify Data agrees: every item accounted for everywhere, nothing reported.
        let report = try await withCheckedThrowingContinuation { continuation in
            supervisor.verifyData { continuation.resume(with: $0) }
        }
        let checked = try #require(report.results.first { $0.name == "Calendar" || $0.name == "calendar" })
        #expect(checked.stored == Self.eventCount && checked.listed == Self.eventCount
                && checked.synced == Self.eventCount && checked.fetched == Self.eventCount)
        #expect(report.isClean, "\(report.results.flatMap(\.problems).prefix(5))")
    }

    // MARK: Sending

    /// A raw TLS client that reads at its own pace, so the test controls flow.
    final class SlowClient: @unchecked Sendable {
        let connection: NWConnection
        private let queue = DispatchQueue(label: "SlowClient")
        init(port: UInt16, tls: Bool) {
            let parameters: NWParameters
            if tls {
                let options = NWProtocolTLS.Options()
                sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, _, complete in complete(true) }, queue)
                parameters = NWParameters(tls: options)
            } else {
                parameters = .tcp
            }
            connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: parameters)
        }
        func start() async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let resumed = Locked(false)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: if !resumed.withLock({ let was = $0; $0 = true; return was }) { continuation.resume() }
                    case .failed(let error): if !resumed.withLock({ let was = $0; $0 = true; return was }) { continuation.resume(throwing: error) }
                    default: break
                    }
                }
                connection.start(queue: queue)
            }
        }
        func send(_ text: String, final: Bool = false) {
            connection.send(content: Data(text.utf8), contentContext: final ? .finalMessage : .defaultMessage,
                            isComplete: true, completion: .contentProcessed { _ in })
        }
        /// Reads until the connection ends, pausing after each read.
        func readAll(pause: Duration) async -> Data {
            var received = Data()
            while true {
                let (chunk, done): (Data?, Bool) = await withCheckedContinuation { continuation in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                        continuation.resume(returning: (data, isComplete || error != nil))
                    }
                }
                if let chunk { received.append(chunk) }
                if done { return received }
                try? await Task.sleep(for: pause)
            }
        }
    }

    static func bodyLength(of response: Data) -> (declared: Int?, received: Int) {
        guard let split = response.range(of: Data("\r\n\r\n".utf8)) else { return (nil, 0) }
        let head = String(decoding: response[..<split.lowerBound], as: UTF8.self)
        let declared = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) }
        return (declared, response.count - split.upperBound)
    }

    static func readyPort(_ server: HTTPServer) async throws -> UInt16 {
        for _ in 0..<100 {
            if case .ready(let port) = server.state.current { return port }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CancellationError()
    }

    static func testIdentity() throws -> SecIdentity {
        let authority = try CertificateBuilder.makeAuthority(commonName: "Large Test CA")
        let leaf = try CertificateBuilder.makeServerCertificate(names: ["localhost"], addresses: ["127.0.0.1"],
                                                                authority: authority, authorityName: "Large Test CA")
        return try #require(CertificateBuilder.identity(for: leaf))
    }

    /// A response that takes longer to read than the idle timeout still arrives whole: going
    /// out counts as activity. Before, only incoming data did, and a 3 MB body read over
    /// longer than the timeout was cut off with the connection closed cleanly.
    @Test func slowReaderGetsTheWholeResponse() async throws {
        // Far larger than loopback socket buffers, so most of it is still queued in the server
        // when the idle timeout passes, as on a real network.
        let body = String(repeating: "<d:response>0123456789abcdef</d:response>", count: 1_200_000)  // ~50 MB
        let server = HTTPServer(name: "Slow", port: 0, identity: try Self.testIdentity()) { _ in .xml(207, body) }
        server.idleTimeout = 1
        let failures = Locked<[String]>([])
        server.onSendFailure.withLock { $0 = { message in failures.withLock { $0.append(message) } } }
        server.start()
        defer { server.stop() }
        let client = SlowClient(port: try await Self.readyPort(server), tls: true)
        try await client.start()
        client.send("GET / HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n")
        let started = Date()
        let response = await client.readAll(pause: .milliseconds(10))
        let length = Self.bodyLength(of: response)
        #expect(Date().timeIntervalSince(started) > 1.5, "the read should outlast the idle timeout")
        #expect(length.declared == length.received && length.received == Data(body.utf8).count)
        #expect(failures.current.isEmpty)
    }

    /// A client that stops reading entirely is still dropped after the idle timeout, and
    /// the cut-off is reported rather than passing silently.
    @Test func stalledReaderIsReported() async throws {
        let body = String(repeating: "x", count: 20_000_000)
        let server = HTTPServer(name: "Stalled", port: 0, identity: nil) { _ in .text(200, body) }
        server.idleTimeout = 1
        let failures = Locked<[String]>([])
        server.onSendFailure.withLock { $0 = { message in failures.withLock { $0.append(message) } } }
        server.start()
        defer { server.stop() }
        let client = SlowClient(port: try await Self.readyPort(server), tls: false)
        try await client.start()
        client.send("GET /big HTTP/1.1\r\nHost: test\r\nUser-Agent: StallTest\r\n\r\n")
        // Never read: the socket buffers fill and the server's send stops progressing.
        for _ in 0..<50 where failures.current.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        client.connection.cancel()
        let message = try #require(failures.current.first)
        #expect(message.contains("GET /big") && message.contains("StallTest") && message.contains("cut off"))
    }

    /// Stopping the server (Restart, a new certificate, quitting) cuts off a response on
    /// purpose; that isn't reported as a fault.
    @Test func stoppingTheServerIsNotReported() async throws {
        let body = String(repeating: "z", count: 20_000_000)
        let server = HTTPServer(name: "Stopping", port: 0, identity: nil) { _ in .text(200, body) }
        let failures = Locked<[String]>([])
        server.onSendFailure.withLock { $0 = { message in failures.withLock { $0.append(message) } } }
        server.start()
        let client = SlowClient(port: try await Self.readyPort(server), tls: false)
        try await client.start()
        client.send("GET / HTTP/1.1\r\nHost: test\r\n\r\n")
        try await Task.sleep(for: .milliseconds(300))  // well into the send; the client isn't reading
        server.stop()
        try await Task.sleep(for: .milliseconds(300))
        client.connection.cancel()
        #expect(failures.current.isEmpty, "\(failures.current)")
    }

    /// A client that drops the connection partway through a large response is reported:
    /// the connection is let go at once, so this is caught from its state, not the send.
    @Test func droppedConnectionIsReported() async throws {
        let body = String(repeating: "w", count: 20_000_000)
        let server = HTTPServer(name: "Dropped", port: 0, identity: nil) { _ in .text(200, body) }
        let failures = Locked<[String]>([])
        server.onSendFailure.withLock { $0 = { message in failures.withLock { $0.append(message) } } }
        server.start()
        defer { server.stop() }
        let client = SlowClient(port: try await Self.readyPort(server), tls: false)
        try await client.start()
        client.send("GET /dropped HTTP/1.1\r\nHost: test\r\n\r\n")
        try await Task.sleep(for: .milliseconds(300))
        client.connection.forceCancel()  // a reset, as a device leaving Wi-Fi might
        for _ in 0..<30 where failures.current.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        #expect(failures.current.count == 1 && failures.current.first?.contains("GET /dropped") == true, "\(failures.current)")
    }

    /// A client that finishes sending (half-closes) right after its request still gets the
    /// whole response; the server used to close at once and drop it.
    @Test func halfClosedClientGetsTheResponse() async throws {
        let body = String(repeating: "y", count: 50_000_000)
        let server = HTTPServer(name: "HalfClose", port: 0, identity: nil) { _ in .text(200, body) }
        server.start()
        defer { server.stop() }
        let client = SlowClient(port: try await Self.readyPort(server), tls: false)
        try await client.start()
        client.send("GET / HTTP/1.1\r\nHost: test\r\n\r\n", final: true)
        let response = await client.readAll(pause: .milliseconds(1))
        let length = Self.bodyLength(of: response)
        #expect(length.declared == length.received && length.received > 50_000_000)
    }

    /// Pipelined requests on one connection get their responses whole and in order, now
    /// that responses go out in pieces.
    @Test func pipelinedResponsesStayInOrder() async throws {
        let server = HTTPServer(name: "Pipeline", port: 0, identity: nil) { request in
            .text(200, String(repeating: request.path.dropFirst().description, count: 200_000))
        }
        server.start()
        defer { server.stop() }
        let client = SlowClient(port: try await Self.readyPort(server), tls: false)
        try await client.start()
        client.send("GET /a HTTP/1.1\r\nHost: t\r\n\r\nGET /b HTTP/1.1\r\nHost: t\r\n\r\nGET /c HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n")
        let text = String(decoding: await client.readAll(pause: .milliseconds(1)), as: UTF8.self)
        let bodies = text.components(separatedBy: "\r\n\r\n").dropFirst().map { $0.prefix(200_000) }
        #expect(bodies.count == 3)
        #expect(bodies.map { Set($0) } == [["a"], ["b"], ["c"]])
    }

    // MARK: Verify Data

    /// Verify Data names a damaged item instead of passing over it.
    @Test func verifyDataReportsADamagedItem() throws {
        let (handler, store, user) = try Fixtures.handler()
        let calendar = try #require(try store.collections(ownerID: user.id, kind: .calendar).first)
        for index in 0..<600 {  // more than one fetch batch
            _ = handler.handle(Fixtures.request("PUT", "/dav/calendars/alice/\(calendar.uri)/ok-\(index).ics",
                                                body: Fixtures.event(uid: "ok-\(index)"), headers: [("Content-Type", "text/calendar")]))
        }
        // Contacts too, including a folded line: the XML layer turns CRLF into LF, which
        // the readers must still accept rather than flag every item.
        let book = try #require(try store.collections(ownerID: user.id, kind: .addressBook).first)
        for index in 0..<3 {
            let card = Fixtures.card(uid: "c-\(index)").replacingOccurrences(of: "UID:", with: "NOTE:A note long enough to be\r\n  folded onto a second line\r\nUID:")
            let put = handler.handle(Fixtures.request("PUT", "/dav/addressbooks/alice/\(book.uri)/c-\(index).vcf", body: card,
                                                      headers: [("Content-Type", "text/vcard")]))
            #expect(put.status == 201)
        }
        let clean = try Verifier.run(handler: handler, store: store)
        #expect(clean.isClean && clean.itemCount == 603, "\(clean.results.flatMap(\.problems).prefix(3))")

        _ = try store.putResource(collectionID: calendar.id, uri: "broken.ics",
                                  input: .init(data: Data("BEGIN:VCALENDAR\r\nnot really\r\n".utf8), component: "VEVENT", uid: "broken"))
        let damaged = try Verifier.run(handler: handler, store: store)
        #expect(!damaged.isClean)
        let problems = damaged.results.flatMap(\.problems)
        #expect(problems.count == 1 && problems.first?.hasPrefix("broken.ics: can't be read") == true, "\(problems)")
    }

    /// Devices writing while Verify Data runs (adding, editing, deleting) aren't reported as
    /// problems: only items unchanged throughout the check are held to account.
    @Test func verifyDataIgnoresWritesInProgress() async throws {
        let (handler, store, user) = try Fixtures.handler()
        let calendar = try #require(try store.collections(ownerID: user.id, kind: .calendar).first)
        let base = "/dav/calendars/alice/\(calendar.uri)/"
        for index in 0..<1_500 {
            _ = handler.handle(Fixtures.request("PUT", base + "e-\(index).ics", body: Fixtures.event(uid: "e-\(index)"),
                                                headers: [("Content-Type", "text/calendar")]))
        }
        let writing = Locked(true)
        let writer = Task.detached {
            var round = 0
            while writing.current {
                round += 1
                let index = round % 1_500
                // Add one, edit one, delete one, as a busy device might.
                _ = handler.handle(Fixtures.request("PUT", base + "new-\(round).ics", body: Fixtures.event(uid: "new-\(round)"),
                                                    headers: [("Content-Type", "text/calendar")]))
                _ = handler.handle(Fixtures.request("PUT", base + "e-\(index).ics",
                                                    body: Fixtures.event(uid: "e-\(index)", summary: "Edit \(round)"),
                                                    headers: [("Content-Type", "text/calendar")]))
                _ = handler.handle(Fixtures.request("DELETE", base + "new-\(round - 1).ics"))
            }
            return round
        }
        for _ in 0..<5 {
            let report = try Verifier.run(handler: handler, store: store)
            #expect(report.isClean, "\(report.results.flatMap(\.problems).prefix(5))")
        }
        writing.withLock { $0 = false }
        let rounds = await writer.value
        #expect(rounds > 50, "the writer should have overlapped the checks")
    }

    // MARK: Unreadable items

    /// An item the server can't parse comes back from a search unfiltered, instead of
    /// silently vanishing from every device that syncs by date, and it's reported once.
    @Test func unreadableItemIsReturnedAndReported() throws {
        let (handler, store, user) = try Fixtures.handler()
        let reports = Locked<[String]>([])
        handler.onUnreadableResource.withLock { $0 = { message in reports.withLock { $0.append(message) } } }
        let calendar = try #require(try store.collections(ownerID: user.id, kind: .calendar).first)
        _ = handler.handle(Fixtures.request("PUT", "/dav/calendars/alice/\(calendar.uri)/good.ics", body: Fixtures.event(uid: "good"),
                                            headers: [("Content-Type", "text/calendar")]))
        // Stored directly, as damaged data would be: PUT validation would refuse it.
        _ = try store.putResource(collectionID: calendar.id, uri: "broken.ics",
                                  input: .init(data: Data("BEGIN:VCALENDAR\r\nnot really\r\n".utf8), component: "VEVENT", uid: "broken"))
        let query = """
            <c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop><d:getetag/></d:prop>\
            <c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VEVENT"/></c:comp-filter></c:filter></c:calendar-query>
            """
        for _ in 0..<2 {
            let response = handler.handle(Fixtures.request("REPORT", "/dav/calendars/alice/\(calendar.uri)/", body: query, headers: [("Depth", "1")]))
            #expect(response.status == 207)
            #expect(response.text.contains("good.ics") && response.text.contains("broken.ics"))
        }
        #expect(reports.current.count == 1)
        #expect(reports.current.first?.contains("broken.ics") == true)
    }
}
