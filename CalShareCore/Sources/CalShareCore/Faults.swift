// MARK: - Faults.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// Problems noticed while serving that no component owns (the Sync Reliability card): a response cut off on the way out,
// a request that failed in a way nothing anticipated, one that took far too long, a device
// that keeps downloading the same large listing. Each is evidence that a device may not have
// what CalShare thinks it has. A truncated listing once left a calendar missing from every
// device while each card read "Healthy"; these are kept for a day so that a problem CalShare
// can't explain still shows, and a burst of them prompts a restart.

import Foundation

struct FaultLedger {
    enum Kind: String, Sendable {
        /// A response didn't all go out.
        case cutOff
        /// A request failed with a 5xx: something the handler didn't anticipate.
        case serverError
        /// A request took far longer than any should.
        case slowRequest
        /// A device downloaded the same large response again and again.
        case repeatedDownload
        /// The periodic large-transfer test didn't arrive intact.
        case deliveryTest
        /// A stored item couldn't be parsed.
        case unreadableData
        /// An error-level message logged where nothing else reports it.
        case loggedError

        /// Whether restarting the server could plausibly clear it. A device's own behavior
        /// and a damaged item aren't, so they never cause a restart.
        var restartMayHelp: Bool {
            switch self {
            case .cutOff, .serverError, .slowRequest, .deliveryTest: true
            // Nothing says what a logged error was, so nothing says a restart would help.
            case .repeatedDownload, .unreadableData, .loggedError: false
            }
        }
    }

    struct Fault: Sendable, Equatable {
        var date: Date
        var kind: Kind
        var message: String
    }

    /// How long a fault stays on the dashboard unless dismissed.
    static let memory: TimeInterval = 86_400
    /// A burst that prompts a restart: this many within `burstWindow`.
    static let burstCount = 3
    static let burstWindow: TimeInterval = 15 * 60
    /// The most kept; the oldest go first.
    static let capacity = 100

    private(set) var faults: [Fault] = []

    mutating func add(_ kind: Kind, _ message: String, at date: Date = Date()) {
        faults.append(Fault(date: date, kind: kind, message: message))
        if faults.count > Self.capacity { faults.removeFirst(faults.count - Self.capacity) }
    }

    mutating func prune(now: Date = Date()) {
        faults.removeAll { now.timeIntervalSince($0.date) > Self.memory }
    }

    mutating func clear() { faults.removeAll() }

    /// Whether faults a restart might clear have come in a burst since `since`.
    func isBurst(now: Date = Date(), since: Date? = nil) -> Bool {
        let start = max(now.addingTimeInterval(-Self.burstWindow), since ?? .distantPast)
        return faults.lazy.filter { $0.kind.restartMayHelp && $0.date > start }.count >= Self.burstCount
    }
}

/// Notices a device downloading the same large response over and over. A client that
/// can't use what it got (one that read a cut-off listing as unreadable, say) asks again,
/// and every one of those requests succeeds, so nothing else shows it. Only identical
/// content counts: a Mac listing a big calendar again because it changed is doing its job.
struct RepeatDetector {
    static let minimumBytes = 256 * 1024
    static let window: TimeInterval = 30 * 60
    static let threshold = 4

    private var seen: [String: [Date]] = [:]
    private var reported: [String: Date] = [:]

    /// Returns true once each window when one device's request crosses the threshold.
    mutating func observe(_ entry: RequestLogEntry) -> Bool {
        guard entry.bytes >= Self.minimumBytes, (200..<300).contains(entry.status) else { return false }
        let key = "\(entry.remoteAddress) \(entry.method) \(entry.path) \(entry.digest)"
        let now = entry.date
        var dates = (seen[key] ?? []).filter { now.timeIntervalSince($0) < Self.window }
        dates.append(now)
        seen[key] = dates
        // Old keys go, so a long-running server doesn't keep every path it ever served.
        if seen.count > 500 { seen = seen.filter { !$0.value.allSatisfy { now.timeIntervalSince($0) >= Self.window } } }
        guard dates.count >= Self.threshold else { return false }
        if let last = reported[key], now.timeIntervalSince(last) < Self.window { return false }
        reported[key] = now
        return true
    }
}
