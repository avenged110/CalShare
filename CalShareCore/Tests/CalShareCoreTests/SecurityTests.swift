// MARK: - SecurityTests.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// Regression tests for the hardening from the security audit: XML declarations in any
// encoding, IPv6 lockouts by /64, unwritable property names, the per-address connection
// cap, and port changes that are checked before they're made.

import Foundation
import Network
import Security
import Testing
@testable import CalShareCore

@Suite struct SecurityTests {
    // MARK: XML

    static let entityBomb = """
        <?xml version="1.0" encoding="UTF-16"?>
        <!DOCTYPE d:propfind [<!ENTITY a "AAAAAAAAAA"><!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">]>
        <d:propfind xmlns:d="DAV:"><d:prop>&b;</d:prop></d:propfind>
        """

    @Test func declarationsAreRefusedInAnyEncoding() throws {
        for encoding in [String.Encoding.utf16, .utf16BigEndian, .utf16LittleEndian, .utf32] {
            let data = try #require(Self.entityBomb.data(using: encoding))
            #expect(Self.refusesDeclaration(data), "\(encoding)")
        }
        // And in UTF-8, as before.
        #expect(Self.refusesDeclaration(Data(Self.entityBomb.utf8)))
        // A declaration that reaches the parser is refused there, not merely left unparsed.
        let lowercase = Data(Self.entityBomb.replacingOccurrences(of: "UTF-16", with: "utf-8")
            .replacingOccurrences(of: "<!DOCTYPE", with: "<!DOCTYPE ").utf8)
        #expect(Self.refusesDeclaration(lowercase))
    }

    static func refusesDeclaration(_ data: Data) -> Bool {
        do { _ = try XMLRequestParser.parse(data); return false }
        catch XMLParseError.doctypeNotAllowed { return true }
        catch { return false }
    }

    @Test func ordinaryBodiesStillParse() throws {
        let body = #"<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:displayname/></d:prop></d:propfind>"#
        let root = try XMLRequestParser.parse(Data(body.utf8))
        #expect(root.qname == QName(NS.dav, "propfind"))
        #expect(root.child(NS.dav, "prop")?.children.first?.qname == QName(NS.dav, "displayname"))
    }

    @Test func writableNames() {
        #expect(QName(NS.dav, "displayname").hasWritableName)
        #expect(QName(NS.caldav, "calendar-home-set").hasWritableName)
        #expect(QName(NS.dav, "_private.v2").hasWritableName)
        #expect(!QName(NS.dav, "").hasWritableName)
        #expect(!QName(NS.dav, "1st").hasWritableName)
        #expect(!QName(NS.dav, #"x"><evil/><y"#).hasWritableName)
        #expect(!QName(NS.dav, "a b").hasWritableName)
    }

    @Test func expandPropertySkipsNamesThatAreNotNames() throws {
        let (handler, _, _) = try Fixtures.handler()
        let body = """
            <?xml version="1.0" encoding="utf-8"?>
            <d:expand-property xmlns:d="DAV:">
              <d:property name="current-user-principal"/>
              <d:property name="x&quot;&gt;&lt;injected/&gt;&lt;y"/>
            </d:expand-property>
            """
        var request = HTTPRequest(method: "REPORT", target: "/dav/principals/alice/", body: Data(body.utf8), remoteAddress: "10.0.0.2", isSecure: true)
        request.headers["Authorization"] = "Basic " + Data("alice:correct horse".utf8).base64EncodedString()
        let response = handler.handle(request)
        #expect(response.status == 207)
        let text = String(decoding: response.body, as: UTF8.self)
        #expect(!text.contains("<injected"))
        // The response is still well-formed XML.
        #expect((try? XMLRequestParser.parse(response.body)) != nil)
    }

    // MARK: Lockouts

    @Test func ipv6LockoutsCoverTheWholePrefix() throws {
        #expect(Authenticator.lockoutKey("10.0.0.7") == "10.0.0.7")
        #expect(Authenticator.lockoutKey("2001:db8:1:2::5") == "2001:db8:1:2::/64")
        #expect(Authenticator.lockoutKey("2001:db8:1:2:aaaa::9") == "2001:db8:1:2::/64")
        #expect(Authenticator.lockoutKey("2001:db8:1:3::5") == "2001:db8:1:3::/64")

        let (handler, _, _) = try Fixtures.handler()
        let authenticator = handler.authenticator
        let wrong = BasicCredentials(username: "alice", password: "wrong")
        // Each guess from a fresh address in the same /64 still counts against it.
        for index in 1...authenticator.maxFailures {
            #expect(authenticator.authenticate(wrong, from: "2001:db8:1:2::\(index)") == .failure)
        }
        let right = BasicCredentials(username: "alice", password: "correct horse")
        guard case .lockedOut = authenticator.authenticate(right, from: "2001:db8:1:2::ffff") else {
            Issue.record("A new address in a locked-out /64 should be locked out too")
            return
        }
        // Another network isn't affected.
        guard case .success = authenticator.authenticate(right, from: "2001:db8:9:9::1") else {
            Issue.record("A different /64 should not be locked out")
            return
        }
    }

    // MARK: Connections

    @Test func oneAddressCannotTakeEveryConnection() async throws {
        let server = HTTPServer(name: "Test", port: 0, identity: nil) { _ in .text(200, "ok") }
        server.maxConnectionsPerAddress = 4
        server.start()
        defer { server.stop() }
        var port: UInt16?
        for _ in 0..<50 {
            if case .ready(let ready) = server.state.current { port = ready; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let open = try #require(port)
        let queue = DispatchQueue(label: "SecurityTests.clients")
        let clients = (0..<10).map { _ in
            NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: open)!, using: .tcp)
        }
        for client in clients { client.start(queue: queue) }
        defer { for client in clients { client.cancel() } }
        for _ in 0..<50 where server.connectionCount < 4 { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(server.connectionCount == 4)
    }

    // MARK: TLS

    @Test func onlyTLS13IsAccepted() async throws {
        let directory = Fixtures.temporaryDirectory()
        let supervisor = try IntegrationTests.makeSupervisor(at: directory)
        supervisor.start()
        defer { supervisor.stop() }
        let ports = try await IntegrationTests.waitForPorts(supervisor)
        let der = try #require(supervisor.authorityCertificate)
        let authority = try #require(SecCertificateCreateWithData(nil, der as CFData))
        let url = try #require(URL(string: "https://localhost:\(ports.https)/"))

        func status(maximum: tls_protocol_version_t) async -> Int? {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.tlsMaximumSupportedProtocolVersion = maximum
            let session = URLSession(configuration: configuration, delegate: TrustingDelegate(authority: authority), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            return try? await (session.data(from: url).1 as? HTTPURLResponse)?.statusCode
        }
        #expect(await status(maximum: .TLSv13) == 200)
        #expect(await status(maximum: .TLSv12) == nil)
    }

    // MARK: Ports

    @Test func portChangesAreCheckedFirst() async throws {
        let directory = Fixtures.temporaryDirectory()
        let supervisor = try IntegrationTests.makeSupervisor(at: directory)
        supervisor.start()
        defer { supervisor.stop() }
        let ports = try await IntegrationTests.waitForPorts(supervisor)

        #expect(throws: PortChangeError.self) { try supervisor.changePorts(https: 443, http: ports.http) }
        #expect(throws: PortChangeError.self) { try supervisor.changePorts(https: ports.https, http: ports.https) }

        // A port another listener holds is refused, and nothing changes.
        let blocker = HTTPServer(name: "Blocker", port: 0, identity: nil) { _ in .text(200, "") }
        blocker.start()
        defer { blocker.stop() }
        var taken: UInt16?
        for _ in 0..<50 {
            if case .ready(let ready) = blocker.state.current { taken = ready; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let blocked = try #require(taken)
        let before = supervisor.currentConfiguration
        #expect(throws: PortChangeError.self) { try supervisor.changePorts(https: ports.https, http: blocked) }
        #expect(supervisor.currentConfiguration == before)

        // A free one is taken.
        let free = PortFinder.nextFree(after: 40_000, avoiding: [ports.https, ports.http, blocked])
        try supervisor.changePorts(https: ports.https, http: free)
        #expect(supervisor.currentConfiguration.httpPort == free)
    }
}
