// MARK: - IntegrationTests.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// End to end: a real Supervisor on ephemeral ports, spoken to over real TLS with a client
// that trusts only CalShare's authority — the same position an iPhone is in after
// installing the setup profile.

import Foundation
import Security
import Testing
@testable import CalShareCore

final class TrustingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let authority: SecCertificate
    init(authority: SecCertificate) { self.authority = authority }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
        SecTrustSetAnchorCertificates(trust, [authority] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        return SecTrustEvaluateWithError(trust, nil) ? (.useCredential, URLCredential(trust: trust)) : (.cancelAuthenticationChallenge, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

@Suite(.serialized) struct IntegrationTests {
    static func makeSupervisor(at directory: URL) throws -> Supervisor {
        var configuration = ServerConfiguration()
        configuration.httpsPort = 0
        configuration.httpPort = 0
        try ConfigurationStore(url: CalSharePaths(base: directory).configuration).save(configuration)
        var options = Supervisor.Options()
        options.advertiseBonjour = false
        options.watchNetwork = false
        options.manageProcessActivity = false
        return Supervisor(paths: CalSharePaths(base: directory), options: options)
    }

    static func waitForPorts(_ supervisor: Supervisor) async throws -> (https: UInt16, http: UInt16) {
        for _ in 0..<100 {
            let snapshot = supervisor.snapshot()
            if let https = snapshot.httpsPort, let http = snapshot.httpPort { return (https, http) }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CancellationError()
    }

    static func session(for supervisor: Supervisor) throws -> URLSession {
        let der = try #require(supervisor.authorityCertificate)
        let authority = try #require(SecCertificateCreateWithData(nil, der as CFData))
        return URLSession(configuration: .ephemeral, delegate: TrustingDelegate(authority: authority), delegateQueue: nil)
    }

    static func send(_ session: URLSession, _ method: String, _ url: String, body: String? = nil,
                     headers: [String: String] = [:], password: String = "integration-pass") async throws -> (Int, String, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.httpBody = body.map { Data($0.utf8) }
        request.setValue("Basic " + Data("carol:\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.setValue("iOS/18.6 (22G86) dataaccessd/1.0", forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        return (http.statusCode, String(decoding: data, as: UTF8.self), http)
    }

    @Test func fullSyncOverTLS() async throws {
        let directory = Fixtures.temporaryDirectory()
        let supervisor = try Self.makeSupervisor(at: directory)
        supervisor.start()
        defer { supervisor.stop() }
        let ports = try await Self.waitForPorts(supervisor)
        try supervisor.createAccount(username: "carol", displayName: "Carol", password: "integration-pass")
        let session = try Self.session(for: supervisor)
        let base = "https://127.0.0.1:\(ports.https)"

        let (wellKnown, _, wellKnownResponse) = try await Self.send(session, "GET", base + "/.well-known/caldav")
        #expect(wellKnown == 301 && wellKnownResponse.value(forHTTPHeaderField: "Location") == "/dav/")

        let (unauthorized, _, _) = try await Self.send(session, "PROPFIND", base + "/dav/", password: "wrong")
        #expect(unauthorized == 401)

        let principalQuery = #"<A:propfind xmlns:A="DAV:"><A:prop><A:current-user-principal/></A:prop></A:propfind>"#
        let (status, body, _) = try await Self.send(session, "PROPFIND", base + "/dav/", body: principalQuery, headers: ["Depth": "0"])
        #expect(status == 207 && body.contains("/dav/principals/carol/"))

        let event = Fixtures.event(uid: "net-1")
        let (putStatus, _, putResponse) = try await Self.send(session, "PUT", base + "/dav/calendars/carol/calendar/net-1.ics", body: event,
                                                             headers: ["Content-Type": "text/calendar; charset=utf-8", "If-None-Match": "*"])
        #expect(putStatus == 201 && putResponse.value(forHTTPHeaderField: "ETag") != nil)

        let syncBody = """
            <A:sync-collection xmlns:A="DAV:"><A:sync-token/><A:sync-level>1</A:sync-level><A:prop><A:getetag/></A:prop></A:sync-collection>
            """
        let (syncStatus, syncText, _) = try await Self.send(session, "REPORT", base + "/dav/calendars/carol/calendar/", body: syncBody, headers: ["Depth": "1"])
        #expect(syncStatus == 207 && syncText.contains("net-1.ics") && syncText.contains(DAVHandler.syncTokenPrefix))

        // Large-ish body (a contact with a photo) exercises multi-segment receives.
        let photo = Data((0..<300_000).map { UInt8($0 % 251) }).base64EncodedString()
        let card = Fixtures.card(uid: "big").replacingOccurrences(of: "UID:big", with: "PHOTO;ENCODING=b;TYPE=JPEG:\(photo)\r\nUID:big")
        let (cardStatus, _, _) = try await Self.send(session, "PUT", base + "/dav/addressbooks/carol/contacts/big.vcf", body: card)
        #expect(cardStatus == 201)
        let (getStatus, getBody, _) = try await Self.send(session, "GET", base + "/dav/addressbooks/carol/contacts/big.vcf")
        #expect(getStatus == 200 && getBody.count == card.count)

        let snapshot = supervisor.snapshot()
        #expect(snapshot.statistics.events == 1 && snapshot.statistics.contacts == 1)
        #expect(snapshot.clients.first?.platform == "iOS 18.6")
        #expect(snapshot.requests.count >= 6)
        #expect(snapshot.health.first { $0.id == "server" }?.state == .ok)
        #expect(snapshot.health.first { $0.id == "certificate" }?.state == .ok)
        #expect(SelfProbe.run(port: ports.https, authorityDER: supervisor.authorityCertificate!))
    }

    /// NWListener.newConnectionLimit is a lifetime countdown, not a concurrent cap: a
    /// listener that used it stopped accepting for good after that many connections had
    /// come and gone, which left the server deaf after about forty minutes of self-probes.
    @Test func keepsAcceptingPastTheConnectionCap() async throws {
        let server = HTTPServer(name: "Test", port: 0, identity: nil) { _ in .text(200, "ok") }
        server.maxConnections = 3
        server.start()
        defer { server.stop() }
        var port: UInt16?
        for _ in 0..<100 {
            if case .ready(let ready) = server.state.current { port = ready; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let ready = try #require(port)
        for attempt in 0..<20 {
            // A fresh session each time, so every request is a new connection.
            let session = URLSession(configuration: .ephemeral)
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(ready)/")!)
            request.setValue("close", forHTTPHeaderField: "Connection")
            request.timeoutInterval = 5
            let (_, response) = try await session.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200, "request \(attempt)")
            session.invalidateAndCancel()
        }
    }

    /// The server sends the authority after its own certificate, so a client that trusts
    /// the authority (by trust settings rather than as a keychain item) can build the chain.
    @Test func handshakeCarriesTheAuthority() async throws {
        final class ChainCounter: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
            let count = Locked(0)
            func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
                -> (URLSession.AuthChallengeDisposition, URLCredential?) {
                guard let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
                count.withLock { $0 = SecTrustGetCertificateCount(trust) }
                return (.cancelAuthenticationChallenge, nil)
            }
        }
        let directory = Fixtures.temporaryDirectory()
        let supervisor = try Self.makeSupervisor(at: directory)
        supervisor.start()
        defer { supervisor.stop() }
        let ports = try await Self.waitForPorts(supervisor)
        let counter = ChainCounter()
        let session = URLSession(configuration: .ephemeral, delegate: counter, delegateQueue: nil)
        _ = try? await session.data(from: URL(string: "https://127.0.0.1:\(ports.https)/")!)
        #expect(counter.count.current == 2)
    }

    @Test func enrollmentServesProfileOverHTTP() async throws {
        let directory = Fixtures.temporaryDirectory()
        let supervisor = try Self.makeSupervisor(at: directory)
        supervisor.start()
        defer { supervisor.stop() }
        let ports = try await Self.waitForPorts(supervisor)
        try supervisor.createAccount(username: "carol", displayName: "Carol", password: "integration-pass")
        let link = try #require(supervisor.enrollmentURL(for: "carol"))
        var components = URLComponents(url: link, resolvingAgainstBaseURL: false)!
        components.host = "127.0.0.1"
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "application/x-apple-aspen-config")
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let payloads = try #require(plist["PayloadContent"] as? [[String: Any]])
        #expect(payloads.count == 3)

        let (_, expired) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(ports.http)/enroll/not-a-token")!)
        #expect((expired as? HTTPURLResponse)?.statusCode == 404)

        var redirectRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(ports.http)/.well-known/carddav")!)
        redirectRequest.httpMethod = "PROPFIND"
        let noRedirect = URLSession(configuration: .ephemeral, delegate: TrustingDelegate(authority: SecCertificateCreateWithData(nil, supervisor.authorityCertificate! as CFData)!), delegateQueue: nil)
        let (_, redirect) = try await noRedirect.data(for: redirectRequest)
        #expect((redirect as? HTTPURLResponse)?.statusCode == 301)
        #expect((redirect as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location") == "https://127.0.0.1:\(ports.https)/dav/")

        // The setup port never serves calendar data.
        let (_, dav) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(ports.http)/dav/calendars/carol/")!)
        #expect((dav as? HTTPURLResponse)?.statusCode == 404)
    }

    @Test func enrollmentServesProfileOverHTTPS() async throws {
        let directory = Fixtures.temporaryDirectory()
        let supervisor = try Self.makeSupervisor(at: directory)
        supervisor.start()
        defer { supervisor.stop() }
        let ports = try await Self.waitForPorts(supervisor)
        try supervisor.createAccount(username: "carol", displayName: "Carol", password: "integration-pass")
        let link = try #require(supervisor.enrollmentURL(for: "carol", secure: true))
        #expect(link.scheme == "https" && link.port == Int(ports.https))
        var components = URLComponents(url: link, resolvingAgainstBaseURL: false)!
        components.host = "127.0.0.1"

        // A client that doesn't trust the authority is refused before anything is served,
        // and the attempt doesn't spend the link.
        await #expect(throws: (any Error).self) { _ = try await URLSession(configuration: .ephemeral).data(from: components.url!) }

        let session = try Self.session(for: supervisor)
        let (data, response) = try await session.data(from: components.url!)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "application/x-apple-aspen-config")
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect((plist["PayloadContent"] as? [[String: Any]])?.count == 3)
        #expect(supervisor.snapshot().enrollmentUses == 1)

        // The HTTPS side still serves only setup links besides calendar data.
        let (_, certificate) = try await session.data(from: URL(string: "https://127.0.0.1:\(ports.https)/calshare-authority.cer")!)
        #expect((certificate as? HTTPURLResponse)?.statusCode != 200)
    }

    @Test func replacesAnUnconstrainedAuthority() async throws {
        let directory = Fixtures.temporaryDirectory()
        // As saved by earlier versions: an authority with no recorded constraints.
        var legacy = try CertificateBuilder.makeAuthority(commonName: "Old")
        legacy.names = []
        try CertificateStore(directory: CalSharePaths(base: directory).certificates).save(legacy, as: "authority")
        let supervisor = try Self.makeSupervisor(at: directory)
        supervisor.start()
        defer { supervisor.stop() }
        _ = try await Self.waitForPorts(supervisor)
        let snapshot = supervisor.snapshot()
        #expect(snapshot.authorityFingerprint != legacy.fingerprint)
        #expect(snapshot.authorityPermittedNames == ["local", "localhost"])
    }

    @Test func recoversFromCorruptDatabase() async throws {
        let directory = Fixtures.temporaryDirectory()
        do {
            let supervisor = try Self.makeSupervisor(at: directory)
            supervisor.start()
            _ = try await Self.waitForPorts(supervisor)
            try supervisor.createAccount(username: "carol", displayName: "Carol", password: "integration-pass")
            supervisor.perform(.backupNow)
            for _ in 0..<50 where supervisor.snapshot().backups.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
            #expect(!supervisor.snapshot().backups.isEmpty)
            supervisor.stop()
        }
        // Wreck the database file.
        let database = CalSharePaths(base: directory).database
        let handle = try FileHandle(forWritingTo: database)
        try handle.write(contentsOf: Data(repeating: 0x42, count: 8192))
        try handle.close()

        let supervisor = try Self.makeSupervisor(at: directory)
        supervisor.start()
        defer { supervisor.stop() }
        _ = try await Self.waitForPorts(supervisor)
        let snapshot = supervisor.snapshot()
        #expect(snapshot.accounts.map(\.username) == ["carol"])
        #expect(snapshot.health.first { $0.id == "database" }?.summary == "Restored from backup")
        #expect(snapshot.events.contains { $0.message.contains("Restored the database") })
        #expect(FileManager.default.fileExists(atPath: CalSharePaths(base: directory).damaged.path))
    }

    @Test func restoreFromBackupAndPortConflict() async throws {
        let directory = Fixtures.temporaryDirectory()
        let supervisor = try Self.makeSupervisor(at: directory)
        supervisor.start()
        defer { supervisor.stop() }
        _ = try await Self.waitForPorts(supervisor)
        try supervisor.createAccount(username: "carol", displayName: "Carol", password: "integration-pass")
        supervisor.perform(.backupNow)
        for _ in 0..<50 where !supervisor.snapshot().backups.contains(where: { $0.kind == "manual" }) {
            try await Task.sleep(for: .milliseconds(100))
        }
        let backup = try #require(supervisor.snapshot().backups.first { $0.kind == "manual" })
        try supervisor.createAccount(username: "dave", displayName: "Dave", password: "integration-pass")
        #expect(supervisor.snapshot().accounts.count == 2)
        try supervisor.restore(backup)
        #expect(supervisor.snapshot().accounts.map(\.username) == ["carol"])
        #expect(supervisor.snapshot().backups.contains { $0.kind == "pre-restore" })
        let ports = try await Self.waitForPorts(supervisor)

        // A second server asked for the first one's port reports the conflict.
        var configuration = ServerConfiguration()
        configuration.httpsPort = ports.https
        configuration.httpPort = 0
        let otherDirectory = Fixtures.temporaryDirectory()
        try ConfigurationStore(url: CalSharePaths(base: otherDirectory).configuration).save(configuration)
        var options = Supervisor.Options()
        options.advertiseBonjour = false
        options.watchNetwork = false
        options.manageProcessActivity = false
        let rival = Supervisor(paths: CalSharePaths(base: otherDirectory), options: options)
        rival.start()
        defer { rival.stop() }
        var serverHealth: ComponentHealth?
        for _ in 0..<50 {
            serverHealth = rival.snapshot().health.first { $0.id == "server" }
            if serverHealth?.state == .error { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(serverHealth?.state == .error)
        #expect(serverHealth?.fix == .useNextFreePort)
    }
}
