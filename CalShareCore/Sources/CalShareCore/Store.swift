// MARK: - Store.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// The persistent model: accounts, collections (calendars and address books), the resources
// inside them, and a per-collection change log that makes sync-collection exact. Every
// mutation is a single transaction that also bumps the collection's sync token, so a crash
// at any point leaves the database either before or after the change, never between.

import Foundation

public enum CollectionKind: String, Sendable, Codable, CaseIterable {
    case calendar
    case addressBook = "addressbook"
}

public struct User: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var username: String
    public var displayName: String
    public var passwordHash: String
    public var createdAt: Date
}

public struct DAVCollection: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var ownerID: Int64
    public var kind: CollectionKind
    public var uri: String
    public var displayName: String
    public var description: String
    public var color: String
    public var order: Int
    public var timezone: String
    /// For calendars: the component types it accepts (VEVENT, VTODO, ...).
    public var components: [String]
    public var syncToken: Int64
    public var createdAt: Date
}

public struct DAVResource: Sendable, Equatable {
    public var id: Int64
    public var collectionID: Int64
    public var uri: String
    public var data: Data
    public var etag: String
    public var size: Int
    public var component: String
    public var uid: String
    public var firstOccurrence: Date?
    public var lastOccurrence: Date?
    public var modifiedAt: Date
}

public struct ChangeSet: Sendable {
    public var changed: [String]   // URIs added or modified since the token
    public var deleted: [String]
    public var newToken: Int64
}

public struct StoreStatistics: Sendable, Equatable {
    public var users = 0
    public var calendars = 0
    public var addressBooks = 0
    public var events = 0
    public var tasks = 0
    public var contacts = 0
    public var bytes: Int64 = 0
}

public enum StoreError: Error, Equatable, CustomStringConvertible {
    case userExists
    case invalidUsername
    case notFound
    case collectionExists
    case uidConflict(existingURI: String)
    case lastCollection

    public var description: String {
        switch self {
        case .userExists: "An account with that name already exists."
        case .invalidUsername: "Account names use lowercase letters, numbers, dots, dashes, and underscores (1–32 characters)."
        case .notFound: "Not found."
        case .collectionExists: "A collection with that name already exists."
        case .uidConflict(let uri): "Another resource (\(uri)) already uses this UID."
        case .lastCollection: "An account must keep at least one calendar and one address book. Create another before deleting this one."
        }
    }
}

public final class Store: @unchecked Sendable {
    public let db: SQLiteConnection
    public static let schemaVersion = 3
    /// Notified (on an arbitrary queue) after every committed change, for the dashboard.
    public let onChange = Locked<(@Sendable () -> Void)?>(nil)

    public init(url: URL) throws {
        db = try SQLiteConnection(url: url)
        try db.execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;")
        try migrate()
        epoch.withLock { $0 = (try? db.queryOne("SELECT value FROM meta WHERE key = 'sync_epoch'"))??.string("value") ?? "" }
    }

    /// The generation of every sync token and ctag this database hands out. It changes
    /// whenever the database is replaced by an older copy (a restore, or recovery from a
    /// backup): sync tokens are counters, so the restored database would otherwise reissue
    /// numbers clients already hold for different contents, and those clients would keep
    /// items that no longer exist or miss new ones. A new generation makes every earlier
    /// token invalid, so each client does one clean full sync. Empty for databases that
    /// have never been restored, which keeps their existing tokens valid.
    public var syncEpoch: String { epoch.current }
    /// Read by every request's queue, written when the generation is renewed.
    private let epoch = Locked("")

    /// Starts a new token generation; see `syncEpoch`.
    public func renewSyncEpoch() throws {
        let renewed = RandomToken.urlSafe(6)
        try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('sync_epoch', ?)", [.text(renewed)])
        epoch.withLock { $0 = renewed }
    }

    public func close() { db.close() }

    /// Fast structural check; false means the file should be treated as damaged.
    public func quickCheck() -> Bool {
        (try? db.queryOne("PRAGMA quick_check"))?.string("quick_check") == "ok"
    }

    public func checkpoint() { try? db.execute("PRAGMA wal_checkpoint(TRUNCATE)") }

    private func migrate() throws {
        let version = Int(try db.queryOne("PRAGMA user_version")?.int("user_version") ?? 0)
        guard version < Self.schemaVersion else { return }
        try db.transaction {
            if version < 1 {
                try db.execute("""
                CREATE TABLE users (
                    id INTEGER PRIMARY KEY,
                    username TEXT NOT NULL UNIQUE,
                    display_name TEXT NOT NULL DEFAULT '',
                    password_hash TEXT NOT NULL,
                    created_at REAL NOT NULL
                );
                CREATE TABLE collections (
                    id INTEGER PRIMARY KEY,
                    owner_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL,
                    uri TEXT NOT NULL,
                    display_name TEXT NOT NULL DEFAULT '',
                    description TEXT NOT NULL DEFAULT '',
                    color TEXT NOT NULL DEFAULT '',
                    sort_order INTEGER NOT NULL DEFAULT 0,
                    timezone TEXT NOT NULL DEFAULT '',
                    components TEXT NOT NULL DEFAULT '',
                    sync_token INTEGER NOT NULL DEFAULT 1,
                    created_at REAL NOT NULL,
                    UNIQUE(owner_id, kind, uri)
                );
                CREATE TABLE resources (
                    id INTEGER PRIMARY KEY,
                    collection_id INTEGER NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
                    uri TEXT NOT NULL,
                    data BLOB NOT NULL,
                    etag TEXT NOT NULL,
                    size INTEGER NOT NULL,
                    component TEXT NOT NULL DEFAULT '',
                    uid TEXT NOT NULL DEFAULT '',
                    first_occurrence REAL,
                    last_occurrence REAL,
                    modified_at REAL NOT NULL,
                    UNIQUE(collection_id, uri)
                );
                CREATE INDEX resources_uid ON resources(collection_id, uid);
                CREATE TABLE changes (
                    id INTEGER PRIMARY KEY,
                    collection_id INTEGER NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
                    uri TEXT NOT NULL,
                    sync_token INTEGER NOT NULL,
                    deleted INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX changes_token ON changes(collection_id, sync_token);
                CREATE TABLE dead_properties (
                    collection_id INTEGER NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
                    namespace TEXT NOT NULL,
                    name TEXT NOT NULL,
                    xml TEXT NOT NULL,
                    PRIMARY KEY(collection_id, namespace, name)
                );
                """)
            }
            if version < 2 {
                try db.execute("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);")
            }
            if version < 3 {
                // Answers statistics() from the index alone. Without it, counting by
                // component reads every row past its data column, contact photos and all,
                // and the dashboard asks every few seconds.
                try db.execute("CREATE INDEX IF NOT EXISTS resources_component ON resources(component, size);")
            }
            try db.execute("PRAGMA user_version = \(Self.schemaVersion)")
        }
    }

    /// A change made inside `transaction(_:)` is announced once it commits, and not at all
    /// if it rolls back.
    private let notifyAfterCommit = Locked(false)

    private func notify() {
        if db.isInTransaction { notifyAfterCommit.withLock { $0 = true }; return }
        onChange.current?()
    }

    /// Runs `body` as one transaction, announcing its changes only once it commits.
    public func transaction<R>(_ body: () throws -> R) throws -> R {
        let outermost = !db.isInTransaction
        do {
            let result = try db.transaction(body)
            if outermost, notifyAfterCommit.withLock({ pending in defer { pending = false }; return pending }) { onChange.current?() }
            return result
        } catch {
            if outermost { notifyAfterCommit.withLock { $0 = false } }
            throw error
        }
    }

    // MARK: Users

    public static func isValidUsername(_ name: String) -> Bool {
        guard (1...32).contains(name.count) else { return false }
        return name.unicodeScalars.allSatisfy { "abcdefghijklmnopqrstuvwxyz0123456789._-".unicodeScalars.contains($0) }
            && !name.hasPrefix(".")
    }

    private func user(from row: SQLRow) -> User {
        User(id: row.int("id"), username: row.string("username"), displayName: row.string("display_name"),
             passwordHash: row.string("password_hash"),
             createdAt: Date(timeIntervalSince1970: Double(row.int("created_at"))))
    }

    public func users() throws -> [User] {
        try db.query("SELECT * FROM users ORDER BY username").map(user(from:))
    }

    public func user(named username: String) throws -> User? {
        try db.queryOne("SELECT * FROM users WHERE username = ?", [.text(username.lowercased())]).map(user(from:))
    }

    /// Creates an account along with its default calendar, task list and address book.
    @discardableResult
    public func createUser(username rawName: String, displayName: String, passwordHash: String) throws -> User {
        let username = rawName.lowercased()
        guard Self.isValidUsername(username) else { throw StoreError.invalidUsername }
        let now = Date()
        let user: User = try db.transaction {
            guard try self.user(named: username) == nil else { throw StoreError.userExists }
            try db.run("INSERT INTO users (username, display_name, password_hash, created_at) VALUES (?, ?, ?, ?)",
                       [.text(username), .text(displayName), .text(passwordHash), .double(now.timeIntervalSince1970)])
            let id = db.lastInsertRowID
            try insertCollection(ownerID: id, kind: .calendar, uri: "calendar", displayName: "Calendar",
                                 color: "#1BADF8FF", components: ["VEVENT"], order: 0)
            try insertCollection(ownerID: id, kind: .calendar, uri: "reminders", displayName: "Reminders",
                                 color: "#FF9500FF", components: ["VTODO"], order: 1)
            try insertCollection(ownerID: id, kind: .addressBook, uri: "contacts", displayName: "Contacts",
                                 color: "", components: [], order: 0)
            return User(id: id, username: username, displayName: displayName, passwordHash: passwordHash, createdAt: now)
        }
        notify()
        return user
    }

    public func setPasswordHash(_ hash: String, for userID: Int64) throws {
        try db.run("UPDATE users SET password_hash = ? WHERE id = ?", [.text(hash), .int(userID)])
    }

    public func setDisplayName(_ name: String, for userID: Int64) throws {
        try db.run("UPDATE users SET display_name = ? WHERE id = ?", [.text(name), .int(userID)])
        notify()
    }

    public func deleteUser(_ userID: Int64) throws {
        try db.run("DELETE FROM users WHERE id = ?", [.int(userID)])
        notify()
    }

    // MARK: Collections

    private func collection(from row: SQLRow) -> DAVCollection {
        DAVCollection(
            id: row.int("id"), ownerID: row.int("owner_id"),
            kind: CollectionKind(rawValue: row.string("kind")) ?? .calendar,
            uri: row.string("uri"), displayName: row.string("display_name"),
            description: row.string("description"), color: row.string("color"),
            order: Int(row.int("sort_order")), timezone: row.string("timezone"),
            components: row.string("components").split(separator: ",").map(String.init),
            syncToken: row.int("sync_token"),
            createdAt: Date(timeIntervalSince1970: Double(row.int("created_at"))))
    }

    @discardableResult
    private func insertCollection(ownerID: Int64, kind: CollectionKind, uri: String, displayName: String,
                                  color: String, components: [String], order: Int,
                                  description: String = "", timezone: String = "") throws -> Int64 {
        try db.run("""
            INSERT INTO collections (owner_id, kind, uri, display_name, description, color, sort_order,
                                     timezone, components, sync_token, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?)
            """,
            [.int(ownerID), .text(kind.rawValue), .text(uri), .text(displayName), .text(description),
             .text(color), .int(Int64(order)), .text(timezone), .text(components.joined(separator: ",")),
             .double(Date().timeIntervalSince1970)])
        return db.lastInsertRowID
    }

    public func collections(ownerID: Int64, kind: CollectionKind) throws -> [DAVCollection] {
        try db.query("SELECT * FROM collections WHERE owner_id = ? AND kind = ? ORDER BY sort_order, uri",
                     [.int(ownerID), .text(kind.rawValue)]).map(collection(from:))
    }

    public func collection(ownerID: Int64, kind: CollectionKind, uri: String) throws -> DAVCollection? {
        try db.queryOne("SELECT * FROM collections WHERE owner_id = ? AND kind = ? AND uri = ?",
                        [.int(ownerID), .text(kind.rawValue), .text(uri)]).map(collection(from:))
    }

    public func collection(id: Int64) throws -> DAVCollection? {
        try db.queryOne("SELECT * FROM collections WHERE id = ?", [.int(id)]).map(collection(from:))
    }

    @discardableResult
    public func createCollection(ownerID: Int64, kind: CollectionKind, uri: String, displayName: String,
                                 description: String = "", color: String = "", order: Int = 0,
                                 timezone: String = "", components: [String] = []) throws -> DAVCollection {
        let result: DAVCollection = try db.transaction {
            guard try collection(ownerID: ownerID, kind: kind, uri: uri) == nil else { throw StoreError.collectionExists }
            let id = try insertCollection(ownerID: ownerID, kind: kind, uri: uri, displayName: displayName,
                                          color: color, components: components, order: order,
                                          description: description, timezone: timezone)
            guard let created = try collection(id: id) else { throw StoreError.notFound }
            return created
        }
        notify()
        return result
    }

    public struct CollectionUpdate: Sendable {
        public var displayName: String?
        public var description: String?
        public var color: String?
        public var order: Int?
        public var timezone: String?
        public var components: [String]?
        public init(displayName: String? = nil, description: String? = nil, color: String? = nil,
                    order: Int? = nil, timezone: String? = nil, components: [String]? = nil) {
            self.displayName = displayName; self.description = description; self.color = color
            self.order = order; self.timezone = timezone; self.components = components
        }
    }

    /// Updates collection properties. Property changes do not bump the sync token: tokens
    /// track member changes, and clients re-read collection properties with PROPFIND.
    public func updateCollection(_ id: Int64, _ update: CollectionUpdate) throws {
        try db.transaction {
            if let value = update.displayName { try db.run("UPDATE collections SET display_name = ? WHERE id = ?", [.text(value), .int(id)]) }
            if let value = update.description { try db.run("UPDATE collections SET description = ? WHERE id = ?", [.text(value), .int(id)]) }
            if let value = update.color { try db.run("UPDATE collections SET color = ? WHERE id = ?", [.text(value), .int(id)]) }
            if let value = update.order { try db.run("UPDATE collections SET sort_order = ? WHERE id = ?", [.int(Int64(value)), .int(id)]) }
            if let value = update.timezone { try db.run("UPDATE collections SET timezone = ? WHERE id = ?", [.text(value), .int(id)]) }
            if let value = update.components { try db.run("UPDATE collections SET components = ? WHERE id = ?", [.text(value.joined(separator: ",")), .int(id)]) }
        }
        notify()
    }

    public func deleteCollection(_ id: Int64) throws {
        try db.run("DELETE FROM collections WHERE id = ?", [.int(id)])
        notify()
    }

    /// Deletes a collection unless it is the account's last calendar for events or its last
    /// address book. Checked in the same transaction as the delete, so it always reflects
    /// the collections that exist at that moment. Reminders lists aren't held back:
    /// Reminders creates a new one by itself when it needs one.
    public func deleteCollectionKeepingRequired(_ id: Int64) throws {
        try db.transaction {
            guard let collection = try collection(id: id) else { throw StoreError.notFound }
            let others = try collections(ownerID: collection.ownerID, kind: collection.kind).filter { $0.id != id }
            switch collection.kind {
            case .addressBook:
                if others.isEmpty { throw StoreError.lastCollection }
            case .calendar:
                if collection.components.contains("VEVENT"), !others.contains(where: { $0.components.contains("VEVENT") }) {
                    throw StoreError.lastCollection
                }
            }
            try db.run("DELETE FROM collections WHERE id = ?", [.int(id)])
        }
        notify()
    }

    // MARK: Dead properties

    public func deadProperties(collectionID: Int64) throws -> [(namespace: String, name: String, xml: String)] {
        try db.query("SELECT namespace, name, xml FROM dead_properties WHERE collection_id = ?", [.int(collectionID)])
            .map { ($0.string("namespace"), $0.string("name"), $0.string("xml")) }
    }

    public func setDeadProperty(collectionID: Int64, namespace: String, name: String, xml: String?) throws {
        if let xml {
            try db.run("INSERT OR REPLACE INTO dead_properties (collection_id, namespace, name, xml) VALUES (?, ?, ?, ?)",
                       [.int(collectionID), .text(namespace), .text(name), .text(xml)])
        } else {
            try db.run("DELETE FROM dead_properties WHERE collection_id = ? AND namespace = ? AND name = ?",
                       [.int(collectionID), .text(namespace), .text(name)])
        }
    }

    // MARK: Resources

    private func resource(from row: SQLRow) -> DAVResource {
        DAVResource(
            id: row.int("id"), collectionID: row.int("collection_id"), uri: row.string("uri"),
            data: row.data("data"), etag: row.string("etag"), size: Int(row.int("size")),
            component: row.string("component"), uid: row.string("uid"),
            firstOccurrence: row.optionalDate("first_occurrence"),
            lastOccurrence: row.optionalDate("last_occurrence"),
            modifiedAt: row.date("modified_at"))
    }

    public func resources(collectionID: Int64) throws -> [DAVResource] {
        try db.query("SELECT * FROM resources WHERE collection_id = ? ORDER BY uri", [.int(collectionID)]).map(resource(from:))
    }

    /// Every resource in a collection without its contents (`data` is empty), for listings
    /// that report only metadata such as ETags.
    public func resourcesWithoutData(collectionID: Int64) throws -> [DAVResource] {
        try db.query("""
            SELECT id, collection_id, uri, etag, size, component, uid, first_occurrence, last_occurrence, modified_at
            FROM resources WHERE collection_id = ? ORDER BY uri
            """, [.int(collectionID)]).map(resource(from:))
    }

    public func resource(collectionID: Int64, uri: String) throws -> DAVResource? {
        try db.queryOne("SELECT * FROM resources WHERE collection_id = ? AND uri = ?",
                        [.int(collectionID), .text(uri)]).map(resource(from:))
    }

    /// Resources whose indexed span overlaps [start, end); nil bounds are open.
    public func resources(collectionID: Int64, component: String?, overlapping start: Date?, _ end: Date?) throws -> [DAVResource] {
        var sql = "SELECT * FROM resources WHERE collection_id = ?"
        var parameters: [SQLValue] = [.int(collectionID)]
        if let component { sql += " AND component = ?"; parameters.append(.text(component)) }
        if let end { sql += " AND (first_occurrence IS NULL OR first_occurrence < ?)"; parameters.append(.double(end.timeIntervalSince1970)) }
        if let start {
            sql += " AND (last_occurrence IS NULL OR last_occurrence > ? OR (last_occurrence = first_occurrence AND first_occurrence >= ?))"
            parameters.append(.double(start.timeIntervalSince1970))
            parameters.append(.double(start.timeIntervalSince1970))
        }
        return try db.query(sql + " ORDER BY uri", parameters).map(resource(from:))
    }

    public struct ResourceInput: Sendable {
        public var data: Data
        public var component: String
        public var uid: String
        public var firstOccurrence: Date?
        public var lastOccurrence: Date?
        public init(data: Data, component: String, uid: String, firstOccurrence: Date? = nil, lastOccurrence: Date? = nil) {
            self.data = data; self.component = component; self.uid = uid
            self.firstOccurrence = firstOccurrence; self.lastOccurrence = lastOccurrence
        }
    }

    public enum Precondition: Sendable {
        case none
        case mustNotExist
        case ifMatch(Set<String>)    // quoted ETags, or "*"
    }

    public enum PutResult: Sendable, Equatable {
        case created(etag: String)
        case updated(etag: String)
        case preconditionFailed
    }

    public static func etag(for data: Data) -> String { "\"" + Hashing.sha256Hex(data).prefix(32) + "\"" }

    public func putResource(collectionID: Int64, uri: String, input: ResourceInput,
                            precondition: Precondition = .none) throws -> PutResult {
        let etag = Self.etag(for: input.data)
        let result: PutResult = try db.transaction {
            let existing = try db.queryOne("SELECT id, etag FROM resources WHERE collection_id = ? AND uri = ?",
                                           [.int(collectionID), .text(uri)])
            switch precondition {
            case .none: break
            case .mustNotExist: if existing != nil { return .preconditionFailed }
            case .ifMatch(let tags):
                guard let existing else { return .preconditionFailed }
                if !tags.contains("*") && !tags.contains(existing.string("etag")) { return .preconditionFailed }
            }
            if !input.uid.isEmpty,
               let clash = try db.queryOne("SELECT uri FROM resources WHERE collection_id = ? AND uid = ? AND uri != ?",
                                           [.int(collectionID), .text(input.uid), .text(uri)]) {
                throw StoreError.uidConflict(existingURI: clash.string("uri"))
            }
            let first: SQLValue = input.firstOccurrence.map { .double($0.timeIntervalSince1970) } ?? .null
            let last: SQLValue = input.lastOccurrence.map { .double($0.timeIntervalSince1970) } ?? .null
            let now = Date().timeIntervalSince1970
            if existing != nil {
                try db.run("""
                    UPDATE resources SET data = ?, etag = ?, size = ?, component = ?, uid = ?,
                    first_occurrence = ?, last_occurrence = ?, modified_at = ? WHERE collection_id = ? AND uri = ?
                    """, [.blob(input.data), .text(etag), .int(Int64(input.data.count)), .text(input.component),
                          .text(input.uid), first, last, .double(now), .int(collectionID), .text(uri)])
            } else {
                try db.run("""
                    INSERT INTO resources (collection_id, uri, data, etag, size, component, uid,
                                           first_occurrence, last_occurrence, modified_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [.int(collectionID), .text(uri), .blob(input.data), .text(etag), .int(Int64(input.data.count)),
                          .text(input.component), .text(input.uid), first, last, .double(now)])
            }
            try recordChange(collectionID: collectionID, uri: uri, deleted: false)
            return existing == nil ? .created(etag: etag) : .updated(etag: etag)
        }
        if case .preconditionFailed = result {} else { notify() }
        return result
    }

    public enum DeleteResult: Sendable, Equatable { case deleted, notFound, preconditionFailed }

    public func deleteResource(collectionID: Int64, uri: String, ifMatch: Set<String>? = nil) throws -> DeleteResult {
        let result: DeleteResult = try db.transaction {
            guard let existing = try db.queryOne("SELECT etag FROM resources WHERE collection_id = ? AND uri = ?",
                                                 [.int(collectionID), .text(uri)]) else { return .notFound }
            if let ifMatch, !ifMatch.contains("*"), !ifMatch.contains(existing.string("etag")) { return .preconditionFailed }
            try db.run("DELETE FROM resources WHERE collection_id = ? AND uri = ?", [.int(collectionID), .text(uri)])
            try recordChange(collectionID: collectionID, uri: uri, deleted: true)
            return .deleted
        }
        if result == .deleted { notify() }
        return result
    }

    /// Moves a resource between (or within) collections of the same kind.
    public func moveResource(from source: Int64, uri: String, to target: Int64, newURI: String, overwrite: Bool) throws -> Bool? {
        var moved = false
        let result: Bool? = try db.transaction {
            guard let resource = try resource(collectionID: source, uri: uri) else { return nil }
            // Moving onto itself would delete the resource below; it is a no-op instead.
            if source == target && uri == newURI { return false }
            let existing = try self.resource(collectionID: target, uri: newURI)
            if existing != nil && !overwrite { return false }
            if !resource.uid.isEmpty,
               let clash = try db.queryOne("SELECT uri FROM resources WHERE collection_id = ? AND uid = ? AND uri != ?",
                                           [.int(target), .text(resource.uid), .text(newURI)]),
               !(source == target && clash.string("uri") == uri) {
                throw StoreError.uidConflict(existingURI: clash.string("uri"))
            }
            try db.run("DELETE FROM resources WHERE collection_id = ? AND uri = ?", [.int(target), .text(newURI)])
            try db.run("UPDATE resources SET collection_id = ?, uri = ? WHERE id = ?", [.int(target), .text(newURI), .int(resource.id)])
            try recordChange(collectionID: source, uri: uri, deleted: true)
            try recordChange(collectionID: target, uri: newURI, deleted: false)
            moved = true
            return existing == nil
        }
        if moved { notify() }
        return result
    }

    private func recordChange(collectionID: Int64, uri: String, deleted: Bool) throws {
        try db.run("UPDATE collections SET sync_token = sync_token + 1 WHERE id = ?", [.int(collectionID)])
        guard let token = try db.queryOne("SELECT sync_token FROM collections WHERE id = ?", [.int(collectionID)])?.int("sync_token") else {
            throw StoreError.notFound
        }
        // Only the latest change per URI matters for sync; drop older rows to keep the log small.
        try db.run("DELETE FROM changes WHERE collection_id = ? AND uri = ?", [.int(collectionID), .text(uri)])
        try db.run("INSERT INTO changes (collection_id, uri, sync_token, deleted) VALUES (?, ?, ?, ?)",
                   [.int(collectionID), .text(uri), .int(token), .int(deleted ? 1 : 0)])
    }

    /// Changes after `token`; nil if the token is not valid for this collection.
    public func changes(collectionID: Int64, since token: Int64) throws -> ChangeSet? {
        guard let collection = try collection(id: collectionID), token >= 0, token <= collection.syncToken else { return nil }
        let rows = try db.query("SELECT uri, deleted FROM changes WHERE collection_id = ? AND sync_token > ? ORDER BY sync_token",
                                [.int(collectionID), .int(token)])
        var changed: [String] = []
        var deleted: [String] = []
        for row in rows {
            if row.int("deleted") != 0 { deleted.append(row.string("uri")) } else { changed.append(row.string("uri")) }
        }
        return ChangeSet(changed: changed, deleted: deleted, newToken: collection.syncToken)
    }

    // MARK: Statistics

    public func statistics() -> StoreStatistics {
        var stats = StoreStatistics()
        stats.users = Int((try? db.queryOne("SELECT COUNT(*) AS n FROM users"))?.int("n") ?? 0)
        stats.calendars = Int((try? db.queryOne("SELECT COUNT(*) AS n FROM collections WHERE kind = 'calendar'"))?.int("n") ?? 0)
        stats.addressBooks = Int((try? db.queryOne("SELECT COUNT(*) AS n FROM collections WHERE kind = 'addressbook'"))?.int("n") ?? 0)
        stats.events = Int((try? db.queryOne("SELECT COUNT(*) AS n FROM resources WHERE component = 'VEVENT'"))?.int("n") ?? 0)
        stats.tasks = Int((try? db.queryOne("SELECT COUNT(*) AS n FROM resources WHERE component = 'VTODO'"))?.int("n") ?? 0)
        stats.contacts = Int((try? db.queryOne("SELECT COUNT(*) AS n FROM resources WHERE component = 'VCARD'"))?.int("n") ?? 0)
        stats.bytes = (try? db.queryOne("SELECT COALESCE(SUM(size), 0) AS n FROM resources"))?.int("n") ?? 0
        return stats
    }

    public func resourceCount(collectionID: Int64) -> Int {
        Int((try? db.queryOne("SELECT COUNT(*) AS n FROM resources WHERE collection_id = ?", [.int(collectionID)]))?.int("n") ?? 0)
    }
}

extension SQLRow {
    func date(_ name: String) -> Date {
        if case .double(let value) = self[name] { return Date(timeIntervalSince1970: value) }
        return Date(timeIntervalSince1970: Double(int(name)))
    }

    func optionalDate(_ name: String) -> Date? {
        if case .null = self[name] { return nil }
        return date(name)
    }
}
