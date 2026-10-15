// MARK: - FaultTests.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// Problems no component owns must still show: the fault ledger, the repeated-download
// detector, and the large-transfer test behind the Sync Reliability card, the Supervisor watchdog, and the log observer.

import Foundation
import Testing
@testable import CalShareCore

@Suite struct FaultLedgerTests {
    @Test func burstNeedsFaultsARestartMightClear() {
        var ledger = FaultLedger()
        let now = Date()
        for _ in 0..<FaultLedger.burstCount { ledger.add(.repeatedDownload, "again", at: now) }
        #expect(!ledger.isBurst(now: now))
        ledger.add(.cutOff, "cut", at: now)
        ledger.add(.serverError, "500", at: now)
        #expect(!ledger.isBurst(now: now))
        ledger.add(.slowRequest, "slow", at: now)
        #expect(ledger.isBurst(now: now))
        // Faults from before the last restart don't count toward the next one.
        #expect(!ledger.isBurst(now: now, since: now))
    }

    @Test func oldFaultsAgeOut() {
        var ledger = FaultLedger()
        let now = Date()
        ledger.add(.cutOff, "old", at: now.addingTimeInterval(-FaultLedger.memory - 1))
        ledger.add(.cutOff, "new", at: now)
        ledger.prune(now: now)
        #expect(ledger.faults.map(\.message) == ["new"])
        #expect(!ledger.isBurst(now: now.addingTimeInterval(FaultLedger.burstWindow + 1)))
    }

    static func entry(_ path: String, bytes: Int, at date: Date, address: String = "10.0.0.2", digest: String = "same") -> RequestLogEntry {
        RequestLogEntry(date: date, method: "PROPFIND", path: path, status: 207, username: "carol", client: "iOS",
                        remoteAddress: address, milliseconds: 40, bytes: bytes, digest: digest)
    }

    @Test func aListingThatChangedEachTimeIsNotARepeat() {
        var detector = RepeatDetector()
        let now = Date()
        for index in 0..<10 {
            let repeated = detector.observe(Self.entry("/dav/calendars/carol/tv/", bytes: RepeatDetector.minimumBytes,
                                                       at: now.addingTimeInterval(Double(index)), digest: "v\(index)"))
            #expect(!repeated)
        }
    }

    @Test func repeatedLargeDownloadsAreNoticedOncePerWindow() {
        var detector = RepeatDetector()
        let now = Date()
        let big = RepeatDetector.minimumBytes
        var hits = 0
        for index in 0..<(RepeatDetector.threshold * 2) {
            if detector.observe(Self.entry("/dav/calendars/carol/tv/", bytes: big, at: now.addingTimeInterval(Double(index) * 60))) { hits += 1 }
        }
        #expect(hits == 1)
        // Small responses (routine polling) and other devices don't count.
        var quiet = RepeatDetector()
        for index in 0..<10 {
            let small = quiet.observe(Self.entry("/dav/", bytes: 2_000, at: now.addingTimeInterval(Double(index))))
            let elsewhere = quiet.observe(Self.entry("/dav/x/", bytes: big, at: now, address: "10.0.0.\(index + 10)"))
            #expect(!small && !elsewhere)
        }
    }
}

@Suite(.serialized) struct DeliveryTestTests {
    @Test func deliveryCardReportsIntactTransfer() async throws {
        let directory = Fixtures.temporaryDirectory()
        let supervisor = try IntegrationTests.makeSupervisor(at: directory)
        supervisor.start()
        defer { supervisor.stop() }
        let ports = try await IntegrationTests.waitForPorts(supervisor)

        // The endpoint answers only the Supervisor's own test.
        let session = try IntegrationTests.session(for: supervisor)
        let (_, response) = try await session.data(from: URL(string: "https://127.0.0.1:\(ports.https)\(SelfProbe.deliveryPath)")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 404)

        var card: ComponentHealth?
        for _ in 0..<150 {
            card = supervisor.snapshot().health.first { $0.id == "delivery" }
            if card?.state == .ok { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(card?.state == .ok && card?.summary == "Responses arrive in full")

        let failure = SelfProbe.delivery(host: "127.0.0.1", port: ports.https,
                                         authorityDER: try #require(supervisor.authorityCertificate), token: "wrong")
        #expect(failure == "status 404")
    }
}

@Suite(.serialized) struct WatchdogAndObserverTests {
    @Test func watchdogReportsAStallAndTheRecovery() async throws {
        let directory = Fixtures.temporaryDirectory()
        var configuration = ServerConfiguration()
        configuration.httpsPort = 0
        configuration.httpPort = 0
        try ConfigurationStore(url: CalSharePaths(base: directory).configuration).save(configuration)
        var options = Supervisor.Options()
        options.advertiseBonjour = false
        options.watchNetwork = false
        options.manageProcessActivity = false
        options.stallThreshold = 0.6
        let supervisor = Supervisor(paths: CalSharePaths(base: directory), options: options)
        let reports = Locked<[Date?]>([])
        supervisor.onStall.withLock { $0 = { since in reports.withLock { $0.append(since) } } }
        supervisor.start()
        defer { supervisor.stop() }
        _ = try await IntegrationTests.waitForPorts(supervisor)

        // A queue that keeps up is never reported.
        try await Task.sleep(for: .seconds(1.5))
        #expect(reports.current.isEmpty && supervisor.stalledSince == nil)

        supervisor.occupyQueue(for: 2.5)
        try await Task.sleep(for: .seconds(1.6))
        // Reported while stuck, without waiting on the stuck queue.
        #expect(supervisor.stalledSince != nil)
        #expect(reports.current.count == 1 && reports.current.first! != nil)

        try await Task.sleep(for: .seconds(2))
        #expect(supervisor.stalledSince == nil)
        #expect(reports.current.count == 2 && reports.current.last! == nil)
        #expect(supervisor.snapshot().events.contains { $0.message.contains("stopped responding internally") })
    }

    @Test func loggedErrorsBecomeFaultsUnlessReportedElsewhere() async throws {
        let directory = Fixtures.temporaryDirectory()
        let supervisor = try IntegrationTests.makeSupervisor(at: directory)
        supervisor.start()
        defer { supervisor.stop() }
        _ = try await IntegrationTests.waitForPorts(supervisor)

        supervisor.loggedError("listener failed", category: HTTPServer.logTag)
        supervisor.loggedError("the widget broke", category: "[Widget]")
        supervisor.loggedError("the widget broke", category: "[Widget]")  // a repeat within a minute
        let card = supervisor.snapshot().health.first { $0.id == "delivery" }
        #expect(card?.state == .warning && card?.summary == "1 problem in the last day")
        #expect(card?.detail?.contains("[Widget] the widget broke") == true)
    }

    @Test func observerSeesErrorsWhileLoggingIsOffAndCannotLoop() {
        let seen = Locked<[String]>([])
        let observer = LogObserver(minimumLevel: .error) { message, _, category, _ in
            // Other suites run alongside this one; only this test's own messages count.
            guard category == "[Thing]" || category == "[Test]" else { return }
            seen.withLock { $0.append(message) }
            // Logged from inside the observer: written as usual, never observed again.
            Logger.log("echo of \(message)", level: .error, cName: "[Test]")
        }
        let previous = Logger.currentConfiguration
        Logger.bootstrap(.init(fileName: "FaultTests.log", isEnabled: { false }, echoToConsole: false, observer: observer))
        defer { Logger.bootstrap(previous) }

        struct Thing: Loggable {}
        Thing.log("routine", level: .info)
        Thing.log("broken", level: .error)
        Logger.log("direct", level: .error, cName: "[Test]")
        #expect(seen.current == ["broken", "direct"])
    }
}
