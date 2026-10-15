// MARK: - InfrastructureTests.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only

import CryptoKit
import Foundation
import Security
import Testing
@testable import CalShareCore

@Suite struct StoreTests {
    func makeStore() throws -> Store { try Store(url: Fixtures.temporaryDirectory().appendingPathComponent("s.sqlite")) }

    @Test func newAccountsGetDefaultCollections() throws {
        let store = try makeStore()
        let user = try store.createUser(username: "Bob", displayName: "Bob", passwordHash: "x")
        #expect(user.username == "bob")
        let calendars = try store.collections(ownerID: user.id, kind: .calendar)
        #expect(calendars.map(\.uri) == ["calendar", "reminders"])
        #expect(calendars[1].components == ["VTODO"])
        #expect(try store.collections(ownerID: user.id, kind: .addressBook).map(\.uri) == ["contacts"])
        #expect(throws: StoreError.userExists) { try store.createUser(username: "bob", displayName: "", passwordHash: "x") }
        #expect(throws: StoreError.invalidUsername) { try store.createUser(username: "no spaces", displayName: "", passwordHash: "x") }
    }

    @Test func upgradesVersionTwoDatabases() throws {
        let url = Fixtures.temporaryDirectory().appendingPathComponent("s.sqlite")
        do {
            let store = try Store(url: url)
            try store.db.execute("DROP INDEX resources_component; PRAGMA user_version = 2;")
            store.close()
        }
        let store = try Store(url: url)
        #expect(try store.db.queryOne("PRAGMA user_version")?.int("user_version") == 3)
        let index = try store.db.queryOne("SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'resources_component'")
        #expect(index != nil)
        let plan = try store.db.query("EXPLAIN QUERY PLAN SELECT COUNT(*) AS n FROM resources WHERE component = 'VEVENT'")
        #expect(plan.contains { $0.string("detail").contains("resources_component") })
    }

    @Test func putTracksChangesAndPreconditions() throws {
        let store = try makeStore()
        let user = try store.createUser(username: "bob", displayName: "", passwordHash: "x")
        let calendar = try #require(try store.collection(ownerID: user.id, kind: .calendar, uri: "calendar"))
        let start = calendar.syncToken
        let input = Store.ResourceInput(data: Data("a".utf8), component: "VEVENT", uid: "u1")
        guard case .created(let etag) = try store.putResource(collectionID: calendar.id, uri: "1.ics", input: input) else {
            Issue.record("expected created"); return
        }
        #expect(try store.putResource(collectionID: calendar.id, uri: "1.ics", input: input, precondition: .mustNotExist) == .preconditionFailed)
        #expect(try store.putResource(collectionID: calendar.id, uri: "1.ics", input: input, precondition: .ifMatch(["\"nope\""])) == .preconditionFailed)
        var changedInput = input
        changedInput.data = Data("b".utf8)
        #expect(try store.putResource(collectionID: calendar.id, uri: "1.ics", input: changedInput, precondition: .ifMatch([etag])) == .updated(etag: Store.etag(for: Data("b".utf8))))
        #expect(throws: StoreError.uidConflict(existingURI: "1.ics")) {
            try store.putResource(collectionID: calendar.id, uri: "2.ics", input: input)
        }
        let changes = try #require(try store.changes(collectionID: calendar.id, since: start))
        #expect(changes.changed == ["1.ics"])
        #expect(try store.deleteResource(collectionID: calendar.id, uri: "1.ics") == .deleted)
        let after = try #require(try store.changes(collectionID: calendar.id, since: start))
        #expect(after.changed.isEmpty && after.deleted == ["1.ics"])
        #expect(try store.changes(collectionID: calendar.id, since: after.newToken + 5) == nil)
    }

    @Test func timeRangeIndex() throws {
        let store = try makeStore()
        let user = try store.createUser(username: "bob", displayName: "", passwordHash: "x")
        let calendar = try #require(try store.collection(ownerID: user.id, kind: .calendar, uri: "calendar"))
        for (uri, day) in [("a", "12"), ("b", "20")] {
            let info = try ICalendar.validate(Data(Fixtures.event(uid: uri, start: "202610\(day)T120000Z", end: "202610\(day)T130000Z").utf8))
            _ = try store.putResource(collectionID: calendar.id, uri: uri, input: .init(
                data: Data(), component: info.component, uid: info.uid, firstOccurrence: info.firstOccurrence, lastOccurrence: info.lastOccurrence))
        }
        let hits = try store.resources(collectionID: calendar.id, component: "VEVENT",
                                       overlapping: TimeZoneResolver.utcDate("20261010T000000Z"), TimeZoneResolver.utcDate("20261015T000000Z"))
        #expect(hits.map(\.uri) == ["a"])
    }

    @Test func backupsVerifyAndPrune() throws {
        let directory = Fixtures.temporaryDirectory()
        let store = try Store(url: directory.appendingPathComponent("s.sqlite"))
        try store.createUser(username: "bob", displayName: "", passwordHash: "x")
        let manager = BackupManager(directory: directory.appendingPathComponent("Backups"))
        let record = try manager.create(from: store, kind: "manual")
        #expect(try FileManager.default.contentsOfDirectory(atPath: manager.directory.path) == [record.url.lastPathComponent])
        #expect(BackupManager.verify(record.url))
        #expect(manager.list().first?.kind == "manual")
        try manager.create(from: store, kind: "pre-restore")
        #expect(Set(manager.list().map(\.kind)) == ["manual", "pre-restore"])
        try Data("not a database".utf8).write(to: directory.appendingPathComponent("junk.sqlite"))
        #expect(!BackupManager.verify(directory.appendingPathComponent("junk.sqlite")))
    }

    @Test func exportWritesICSAndVCF() throws {
        let directory = Fixtures.temporaryDirectory()
        let store = try Store(url: directory.appendingPathComponent("s.sqlite"))
        let user = try store.createUser(username: "bob", displayName: "", passwordHash: "x")
        let calendar = try #require(try store.collection(ownerID: user.id, kind: .calendar, uri: "calendar"))
        _ = try store.putResource(collectionID: calendar.id, uri: "e.ics", input: .init(data: Data(Fixtures.event(uid: "e").utf8), component: "VEVENT", uid: "e"))
        let out = directory.appendingPathComponent("Export")
        #expect(try Exporter.export(store: store, to: out) == 3)
        let ics = try String(contentsOf: out.appendingPathComponent("bob/Calendar.ics"), encoding: .utf8)
        #expect(ics.contains("UID:e"))
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("bob/Contacts.vcf").path))
    }
}

@Suite struct AuthTests {
    @Test func setupLinksWorkOnce() throws {
        let enrollment = EnrollmentHandler(profileProvider: { _ in Data("profile".utf8) },
                                           authorityProvider: { nil }, secureEndpoint: { (8443, "mac.local") })
        let token = enrollment.issueToken(for: "alice").token
        func fetch(_ method: String = "GET", from address: String) -> Int {
            enrollment.handle(HTTPRequest(method: method, target: "/enroll/\(token)", remoteAddress: address)).status
        }
        // Looking doesn't spend it, and other methods can't.
        #expect(fetch("HEAD", from: "10.0.0.5") == 200)
        #expect(fetch("PROPFIND", from: "10.0.0.5") == 405)
        #expect(enrollment.uses.current == 0)
        // The first download spends it; the same device may fetch again within the grace period.
        #expect(fetch(from: "10.0.0.5") == 200)
        #expect(fetch(from: "10.0.0.5") == 200)
        #expect(enrollment.uses.current == 1)
        // Any other device is turned away.
        #expect(fetch(from: "10.0.0.9") == 404)
        #expect(fetch("HEAD", from: "10.0.0.9") == 404)
        // After the grace period, even the same device is.
        enrollment.tokens.withLock { $0[token]?.usedAt = Date().addingTimeInterval(-EnrollmentHandler.reuseGrace - 1) }
        #expect(fetch(from: "10.0.0.5") == 404)
    }

    @Test func hashesVerifyAndAreSalted() {
        let a = PasswordHasher.hash("secret", iterations: 1_000)
        let b = PasswordHasher.hash("secret", iterations: 1_000)
        #expect(a != b)
        #expect(PasswordHasher.verify("secret", against: a))
        #expect(!PasswordHasher.verify("Secret", against: a))
        #expect(!PasswordHasher.verify("secret", against: "garbage"))
    }

    @Test func parsesBasicCredentials() {
        let header = "Basic " + Data("alice:pa:ss".utf8).base64EncodedString()
        #expect(BasicCredentials.parse(header) == BasicCredentials(username: "alice", password: "pa:ss"))
        #expect(BasicCredentials.parse("Bearer abc") == nil)
    }

    @Test func locksOutAfterRepeatedFailures() throws {
        let (_, store, _) = try Fixtures.handler()
        let auth = Authenticator(store: store)
        auth.maxFailures = 3
        let bad = BasicCredentials(username: "alice", password: "wrong")
        let good = BasicCredentials(username: "alice", password: "correct horse")
        #expect(auth.authenticate(bad, from: "10.0.0.9") == .failure)
        #expect(auth.authenticate(bad, from: "10.0.0.9") == .failure)
        #expect(auth.authenticate(bad, from: "10.0.0.9") == .failure)
        guard case .lockedOut = auth.authenticate(good, from: "10.0.0.9") else { Issue.record("expected lockout"); return }
        guard case .success = auth.authenticate(good, from: "10.0.0.10") else { Issue.record("other address should work"); return }
        auth.clearLockouts()
        guard case .success = auth.authenticate(good, from: "10.0.0.9") else { Issue.record("expected success"); return }
    }

    @Test func passwordChangeInvalidatesCache() throws {
        let (_, store, user) = try Fixtures.handler()
        let auth = Authenticator(store: store)
        let old = BasicCredentials(username: "alice", password: "correct horse")
        guard case .success = auth.authenticate(old, from: "a") else { Issue.record("expected success"); return }
        try store.setPasswordHash(PasswordHasher.hash("new password", iterations: 1_000), for: user.id)
        #expect(auth.authenticate(old, from: "a") == .failure)
    }
}

@Suite struct CertificateTests {
    @Test func authoritySignsTrustedServerCertificates() throws {
        let authority = try CertificateBuilder.makeAuthority(commonName: "Test Authority")
        let server = try CertificateBuilder.makeServerCertificate(
            names: ["mac.local", "localhost"], addresses: ["192.168.1.5", "127.0.0.1", "::1"],
            authority: authority, authorityName: "Test Authority")
        #expect(CertificateBuilder.evaluate(server, authority: authority, hostname: "mac.local"))
        #expect(CertificateBuilder.evaluate(server, authority: authority, hostname: "192.168.1.5"))
        #expect(!CertificateBuilder.evaluate(server, authority: authority, hostname: "other.local"))
        let stranger = try CertificateBuilder.makeAuthority(commonName: "Test Authority")
        #expect(!CertificateBuilder.evaluate(server, authority: stranger, hostname: "mac.local"))
        #expect(CertificateBuilder.identity(for: server) != nil)
        let certificate = try #require(SecCertificateCreateWithData(nil, server.certificateDER as CFData))
        #expect(SecCertificateCopySubjectSummary(certificate) as String? == "mac.local")
    }

    @Test func authorityIsLimitedToThisMacsNames() throws {
        let authority = try CertificateBuilder.makeAuthority(commonName: "A", permittedNames: NameConstraints.names(customHostnames: ["cal.example.net"]))
        #expect(authority.names == ["local", "localhost", "cal.example.net"])
        let allowed = try CertificateBuilder.makeServerCertificate(
            names: ["mac.local", "localhost", "cal.example.net"],
            addresses: ["192.168.1.5", "10.0.0.2", "172.20.1.1", "100.100.1.1", "127.0.0.1", "::1", "fd7a:115c:a1e0::1"],
            authority: authority, authorityName: "A")
        for host in ["mac.local", "localhost", "cal.example.net", "192.168.1.5", "100.100.1.1", "fd7a:115c:a1e0::1"] {
            #expect(CertificateBuilder.evaluate(allowed, authority: authority, hostname: host), "\(host)")
        }
        // Anything outside the constraints fails the whole certificate, which is the point:
        // a leaked key can't vouch for public sites.
        for (names, addresses) in [(["www.apple.com"], [String]()), (["mac.local", "bank.example.com"], []),
                                   (["mac.local"], ["8.8.8.8"]), (["mac.local"], ["2001:db8::1"])] {
            let rogue = try CertificateBuilder.makeServerCertificate(names: names, addresses: addresses, authority: authority, authorityName: "A")
            #expect(!CertificateBuilder.evaluate(rogue, authority: authority, hostname: names.last!))
        }
    }

    @Test func constraintMatching() {
        #expect(NameConstraints.permits(name: "Mac.Local", within: ["local"]))
        #expect(NameConstraints.permits(name: "a.b.example.net", within: ["example.net"]))
        #expect(!NameConstraints.permits(name: "notexample.net", within: ["example.net"]))
        #expect(NameConstraints.permits(address: "172.31.255.255"))
        #expect(!NameConstraints.permits(address: "172.32.0.1"))
        #expect(NameConstraints.permits(address: "100.127.0.1"))
        #expect(!NameConstraints.permits(address: "100.128.0.1"))
        #expect(NameConstraints.permits(address: "fdab::1"))
        #expect(!NameConstraints.permits(address: "fe80::1"))
        #expect(!NameConstraints.permits(address: "203.0.113.9"))
    }

    @Test func persistenceRoundTrip() throws {
        let store = CertificateStore(directory: Fixtures.temporaryDirectory())
        let authority = try CertificateBuilder.makeAuthority(commonName: "A")
        try store.save(authority, as: "authority")
        let loaded = try #require(store.load("authority"))
        #expect(loaded.certificateDER == authority.certificateDER)
        #expect(loaded.privateKey.rawRepresentation == authority.privateKey.rawRepresentation)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.directory.appendingPathComponent("authority.json").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func derEncoding() {
        #expect(DER.length(5) == Data([5]))
        #expect(DER.length(300) == Data([0x82, 0x01, 0x2C]))
        #expect(DER.oid("1.2.840.10045.2.1") == Data([0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]))
        #expect(DER.integer(Data([0x80])) == Data([0x02, 0x02, 0x00, 0x80]))
    }
}

@Suite struct ProfileTests {
    @Test func profileContainsAuthorityAndAccounts() throws {
        let authority = try CertificateBuilder.makeAuthority(commonName: "A")
        let data = try ProfileBuilder.build(ProfileRequest(
            username: "alice", displayName: "Alice", hostname: "mac.local", port: 8443,
            authorityDER: authority.certificateDER, authorityFingerprint: authority.fingerprint, serverName: "CalShare"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let payloads = try #require(plist["PayloadContent"] as? [[String: Any]])
        #expect(payloads.compactMap { $0["PayloadType"] as? String } == ["com.apple.security.root", "com.apple.caldav.account", "com.apple.carddav.account"])
        #expect(payloads[1]["CalDAVPrincipalURL"] as? String == "https://mac.local:8443/dav/principals/alice/")
        #expect(payloads[1]["CalDAVPassword"] == nil)
        #expect(payloads[0]["PayloadContent"] as? Data == authority.certificateDER)
    }

    @Test func configurationToleratesMissingKeysAndDamage() throws {
        let directory = Fixtures.temporaryDirectory()
        let store = ConfigurationStore(url: directory.appendingPathComponent("config.json"))
        try Data(#"{"httpsPort": 9443}"#.utf8).write(to: store.url)
        let (config, note) = store.load()
        #expect(config.httpsPort == 9443 && config.httpPort == 8080 && note == nil)
        // Settings from before the .local default are marked for the one-time move.
        #expect(!config.automaticIsLocalName && ServerConfiguration().automaticIsLocalName)
        try Data("{broken".utf8).write(to: store.url)
        let (fallback, recovery) = store.load()
        #expect(fallback == ServerConfiguration())
        #expect(recovery != nil)
        #expect(ServerConfiguration.isValidHostname("mac.tail1234.ts.net"))
        #expect(!ServerConfiguration.isValidHostname("bad host"))
        #expect(!ServerConfiguration.isValidHostname("203.0.113.9"))
        #expect(ServerConfiguration.isValidHostname("1password.example"))
    }
}

@Suite struct DataFolderTests {
    @Test func legacyFolderMergesIntoBaseAndEraseKeepsForeignItems() throws {
        let files = FileManager.default
        let base = Fixtures.temporaryDirectory()
        let legacy = base.appendingPathComponent("CalShare/Backups", isDirectory: true)
        try files.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("db".utf8).write(to: base.appendingPathComponent("CalShare/calshare.sqlite"))
        try Data("old".utf8).write(to: legacy.appendingPathComponent("old.sqlite"))
        // A backup written at the new location before migration ran, and an item that
        // isn't CalShare's.
        try files.createDirectory(at: base.appendingPathComponent("Backups"), withIntermediateDirectories: true)
        try Data("new".utf8).write(to: base.appendingPathComponent("Backups/new.sqlite"))
        try files.createDirectory(at: base.appendingPathComponent("AddressBook"), withIntermediateDirectories: true)

        let paths = CalSharePaths(base: base)
        paths.migrateFromLegacyFolder()
        #expect(files.fileExists(atPath: paths.database.path))
        #expect(files.fileExists(atPath: paths.backups.appendingPathComponent("old.sqlite").path))
        #expect(files.fileExists(atPath: paths.backups.appendingPathComponent("new.sqlite").path))
        #expect(!files.fileExists(atPath: base.appendingPathComponent("CalShare").path))

        for item in paths.ownedItems where files.fileExists(atPath: item.path) { try files.removeItem(at: item) }
        #expect(try files.contentsOfDirectory(atPath: base.path) == ["AddressBook"])
    }
}
