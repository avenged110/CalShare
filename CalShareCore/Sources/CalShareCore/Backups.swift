// MARK: - Backups.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// Rolling database backups taken with SQLite's online backup API (consistent while the
// server keeps running), each verified after writing, pruned to a fixed number of hourly
// and daily copies. Also plain-format export of every calendar (.ics) and address book
// (.vcf), which any calendar or contacts app can read without CalShare.

import Foundation

public struct BackupRecord: Sendable, Equatable, Identifiable, Hashable {
    public var id: URL { url }
    public var url: URL
    public var date: Date
    public var size: Int64
    public var kind: String   // "auto", "manual", "pre-restore", "pre-repair"
}

public final class BackupManager: @unchecked Sendable, Loggable {
    public static let logTag = "[Backup]"
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    public func list() -> [BackupRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.compactMap { url -> BackupRecord? in
            // CalShare-<kind>-<yyyyMMdd-HHmmss>.sqlite
            let name = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "sqlite", name.hasPrefix("CalShare-") else { return nil }
            let body = name.dropFirst("CalShare-".count)
            guard body.count > 16, let date = Self.stampFormatter.date(from: String(body.suffix(15))) else { return nil }
            let kind = String(body.dropLast(16))
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            return BackupRecord(url: url, date: date, size: size, kind: kind)
        }.sorted { $0.date > $1.date }
    }

    public var latest: BackupRecord? { list().first }

    /// Writes and verifies a backup. Throws if the copy cannot be verified.
    @discardableResult
    public func create(from store: Store, kind: String) throws -> BackupRecord {
        var date = Date()
        var url = directory.appendingPathComponent("CalShare-\(kind)-\(Self.stampFormatter.string(from: date)).sqlite")
        while FileManager.default.fileExists(atPath: url.path) {
            date = date.addingTimeInterval(1)
            url = directory.appendingPathComponent("CalShare-\(kind)-\(Self.stampFormatter.string(from: date)).sqlite")
        }
        let partial = url.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)
        try store.db.backup(to: partial)
        let verified = Self.verify(partial)
        // Opening the copy to verify it leaves SQLite's shared-memory file beside it.
        Self.removeSidecars(of: partial)
        guard verified else {
            try? FileManager.default.removeItem(at: partial)
            throw SQLiteError(code: 11, message: "The backup failed verification")
        }
        try FileManager.default.moveItem(at: partial, to: url)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        log("Created \(kind) backup \(url.lastPathComponent)")
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        return BackupRecord(url: url, date: date, size: size, kind: kind)
    }

    /// True if the file opens as a CalShare database and passes an integrity check.
    public static func verify(_ url: URL) -> Bool {
        guard let connection = try? SQLiteConnection(url: url, readOnly: true) else { return false }
        defer { connection.close() }
        guard (try? connection.queryOne("PRAGMA integrity_check"))?.string("integrity_check") == "ok" else { return false }
        return (try? connection.queryOne("SELECT COUNT(*) AS n FROM users")) != nil
    }

    /// Keeps the newest `hourly` automatic backups from the last day, one per day for
    /// `daily` days, and the ten newest of each other kind.
    public func prune(hourly: Int, daily: Int) {
        let records = list()
        var keep = Set<URL>()
        let automatic = records.filter { $0.kind == "auto" }
        let dayAgo = Date().addingTimeInterval(-86_400)
        keep.formUnion(automatic.filter { $0.date > dayAgo }.prefix(max(hourly, 1)).map(\.url))
        var days = Set<String>()
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyyMMdd"
        for record in automatic where days.count < daily {
            if days.insert(dayFormatter.string(from: record.date)).inserted { keep.insert(record.url) }
        }
        for kind in Set(records.map(\.kind)) where kind != "auto" {
            keep.formUnion(records.filter { $0.kind == kind }.prefix(10).map(\.url))
        }
        if let newest = records.first { keep.insert(newest.url) }
        // Sidecars that earlier versions left behind after verifying.
        let strays = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for stray in strays where stray.lastPathComponent.hasSuffix(".partial-shm") || stray.lastPathComponent.hasSuffix(".partial-wal") {
            try? FileManager.default.removeItem(at: stray)
        }
        for record in records where !keep.contains(record.url) {
            try? FileManager.default.removeItem(at: record.url)
            Self.removeSidecars(of: record.url)
            log("Pruned \(record.url.lastPathComponent)", level: .debug)
        }
    }

    public func delete(_ record: BackupRecord) {
        try? FileManager.default.removeItem(at: record.url)
        Self.removeSidecars(of: record.url)
    }

    static func removeSidecars(of url: URL) {
        for suffix in ["-shm", "-wal"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }
}

public enum Exporter {
    /// Writes every collection of every account into `folder/<account>/`. Returns the
    /// number of files written.
    @discardableResult
    public static func export(store: Store, to folder: URL) throws -> Int {
        var count = 0
        for user in try store.users() {
            let userFolder = folder.appendingPathComponent(sanitize(user.username), isDirectory: true)
            try FileManager.default.createDirectory(at: userFolder, withIntermediateDirectories: true)
            for kind in CollectionKind.allCases {
                for collection in try store.collections(ownerID: user.id, kind: kind) {
                    let resources = try store.resources(collectionID: collection.id)
                    let base = sanitize(collection.displayName.isEmpty ? collection.uri : collection.displayName)
                    let text: String
                    let fileExtension: String
                    if kind == .calendar {
                        text = ICalendar.merge(resources.map(\.data), name: collection.displayName)
                        fileExtension = "ics"
                    } else {
                        text = VCard.merge(resources.map(\.data))
                        fileExtension = "vcf"
                    }
                    var url = userFolder.appendingPathComponent("\(base).\(fileExtension)")
                    var suffix = 2
                    while FileManager.default.fileExists(atPath: url.path) {
                        url = userFolder.appendingPathComponent("\(base) \(suffix).\(fileExtension)")
                        suffix += 1
                    }
                    try Data(text.utf8).write(to: url, options: .atomic)
                    count += 1
                }
            }
        }
        return count
    }

    static func sanitize(_ name: String) -> String {
        let cleaned = name.map { "/:\\\0".contains($0) ? "-" : $0 }
        let result = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty || result.hasPrefix(".") ? "Untitled" : result
    }
}
