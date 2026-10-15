// MARK: - SQLite.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// A minimal, serialized wrapper over the system SQLite library. Every call runs under one
// lock, so a connection is safe to share across the server's queues; the workload (one
// household's calendars) never needs more concurrency than that.

import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite error \(code): \(message)" }

    /// True for the result codes that mean the file itself is damaged or not a database.
    public var isCorruption: Bool {
        let primary = code & 0xFF
        return primary == SQLITE_CORRUPT || primary == SQLITE_NOTADB
    }
}

public enum SQLValue: Sendable, Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

public struct SQLRow: Sendable {
    let columns: [String: SQLValue]

    public subscript(_ name: String) -> SQLValue { columns[name] ?? .null }

    public func int(_ name: String) -> Int64 {
        if case .int(let value) = self[name] { return value }
        if case .double(let value) = self[name] { return Int64(value) }
        return 0
    }

    public func optionalInt(_ name: String) -> Int64? {
        if case .int(let value) = self[name] { return value }
        return nil
    }

    public func string(_ name: String) -> String {
        switch self[name] {
        case .text(let value): return value
        case .blob(let data): return String(decoding: data, as: UTF8.self)
        case .int(let value): return String(value)
        default: return ""
        }
    }

    public func optionalString(_ name: String) -> String? {
        if case .null = self[name] { return nil }
        return string(name)
    }

    public func data(_ name: String) -> Data {
        switch self[name] {
        case .blob(let data): return data
        case .text(let value): return Data(value.utf8)
        default: return Data()
        }
    }
}

@safe public final class SQLiteConnection: @unchecked Sendable {
    /// Read and written only under `lock`.
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    public let url: URL

    private static let transient = unsafe unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL, readOnly: Bool = false) throws {
        self.url = url
        var db: OpaquePointer?
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = unsafe sqlite3_open_v2(url.path, &db, flags, nil)
        guard result == SQLITE_OK, let db = unsafe db else {
            let message = unsafe db.map { unsafe String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let db = unsafe db { unsafe sqlite3_close_v2(db) }
            throw SQLiteError(code: result, message: message)
        }
        unsafe self.handle = db
        unsafe sqlite3_busy_timeout(db, 5000)
        unsafe sqlite3_extended_result_codes(db, 1)
    }

    deinit { close() }

    public func close() {
        lock.withLock {
            if let handle = unsafe handle {
                unsafe sqlite3_close_v2(handle)
                unsafe self.handle = nil
            }
        }
    }

    private func error(_ code: Int32) -> SQLiteError {
        let message = unsafe handle.map { unsafe String(cString: sqlite3_errmsg($0)) } ?? "closed"
        return SQLiteError(code: code, message: message)
    }

    /// Runs one or more statements with no parameters and no results.
    public func execute(_ sql: String) throws {
        try lock.withLock {
            guard let handle = unsafe handle else { throw SQLiteError(code: SQLITE_MISUSE, message: "closed") }
            var errorMessage: UnsafeMutablePointer<CChar>?
            let result = unsafe sqlite3_exec(handle, sql, nil, nil, &errorMessage)
            if result != SQLITE_OK {
                let message = unsafe errorMessage.map { unsafe String(cString: $0) } ?? "exec failed"
                unsafe sqlite3_free(errorMessage)
                throw SQLiteError(code: result, message: message)
            }
        }
    }

    @discardableResult
    public func run(_ sql: String, _ parameters: [SQLValue] = []) throws -> Int {
        try lock.withLock {
            try unsafe withStatement(sql, parameters) { statement in
                let result = unsafe sqlite3_step(statement)
                guard result == SQLITE_DONE || result == SQLITE_ROW else { throw error(result) }
            }
            return Int(unsafe sqlite3_changes(handle))
        }
    }

    public func query(_ sql: String, _ parameters: [SQLValue] = []) throws -> [SQLRow] {
        try lock.withLock {
            try unsafe withStatement(sql, parameters) { statement in
                var rows: [SQLRow] = []
                // Read once per statement rather than once per row.
                let columnCount = unsafe sqlite3_column_count(statement)
                let names = (0..<columnCount).map { unsafe String(cString: sqlite3_column_name(statement, $0)) }
                while true {
                    let result = unsafe sqlite3_step(statement)
                    if result == SQLITE_DONE { break }
                    guard result == SQLITE_ROW else { throw error(result) }
                    var columns: [String: SQLValue] = [:]
                    columns.reserveCapacity(names.count)
                    for (index, name) in names.enumerated() {
                        columns[name] = unsafe value(statement, Int32(index))
                    }
                    rows.append(SQLRow(columns: columns))
                }
                return rows
            }
        }
    }

    public func queryOne(_ sql: String, _ parameters: [SQLValue] = []) throws -> SQLRow? {
        try query(sql, parameters).first
    }

    public var lastInsertRowID: Int64 { lock.withLock { unsafe sqlite3_last_insert_rowid(handle) } }

    /// Read and written only under `lock`.
    private var transactionDepth = 0

    /// Whether the calling code is inside `transaction(_:)`. The lock is recursive, so this
    /// is exact for the thread running the transaction.
    public var isInTransaction: Bool { lock.withLock { transactionDepth > 0 } }

    /// Runs `body` inside an IMMEDIATE transaction; rolls back if it throws. Nested calls
    /// join the outermost transaction, so composed operations stay atomic.
    public func transaction<R>(_ body: () throws -> R) throws -> R {
        try lock.withLock {
            if transactionDepth > 0 {
                transactionDepth += 1
                defer { transactionDepth -= 1 }
                return try body()
            }
            try execute("BEGIN IMMEDIATE")
            transactionDepth = 1
            defer { transactionDepth = 0 }
            do {
                let result = try body()
                try execute("COMMIT")
                return result
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    /// Copies the whole database to `destination` with SQLite's online backup API, which is
    /// consistent even while other writes are in flight.
    public func backup(to destination: URL) throws {
        try lock.withLock {
            guard let handle = unsafe handle else { throw SQLiteError(code: SQLITE_MISUSE, message: "closed") }
            var target: OpaquePointer?
            let openResult = unsafe sqlite3_open(destination.path, &target)
            guard openResult == SQLITE_OK, let target = unsafe target else { throw SQLiteError(code: openResult, message: "backup open failed") }
            defer { unsafe sqlite3_close_v2(target) }
            guard let backup = unsafe sqlite3_backup_init(target, "main", handle, "main") else {
                throw SQLiteError(code: unsafe sqlite3_errcode(target), message: unsafe String(cString: sqlite3_errmsg(target)))
            }
            let stepResult = unsafe sqlite3_backup_step(backup, -1)
            unsafe sqlite3_backup_finish(backup)
            guard stepResult == SQLITE_DONE else { throw SQLiteError(code: stepResult, message: "backup step failed") }
            // A backup is a single self-contained file: no WAL, so it can be opened read-only,
            // copied, or attached to a message as-is.
            unsafe sqlite3_exec(target, "PRAGMA journal_mode=DELETE", nil, nil, nil)
        }
    }

    // MARK: Statement plumbing

    private func withStatement<R>(_ sql: String, _ parameters: [SQLValue],
                                  _ body: (OpaquePointer) throws -> R) throws -> R {
        guard let handle = unsafe handle else { throw SQLiteError(code: SQLITE_MISUSE, message: "closed") }
        var statement: OpaquePointer?
        let prepareResult = unsafe sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement = unsafe statement else { throw error(prepareResult) }
        defer { unsafe sqlite3_finalize(statement) }
        for (offset, parameter) in parameters.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch parameter {
            case .null: result = unsafe sqlite3_bind_null(statement, index)
            case .int(let value): result = unsafe sqlite3_bind_int64(statement, index, value)
            case .double(let value): result = unsafe sqlite3_bind_double(statement, index, value)
            case .text(let value): result = unsafe sqlite3_bind_text(statement, index, value, -1, Self.transient)
            case .blob(let data) where data.isEmpty:
                // An empty buffer has no base address, and binding a nil pointer binds NULL.
                result = unsafe sqlite3_bind_zeroblob(statement, index, 0)
            case .blob(let data):
                result = unsafe data.withUnsafeBytes { buffer in
                    unsafe sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), Self.transient)
                }
            }
            guard result == SQLITE_OK else { throw error(result) }
        }
        return try unsafe body(statement)
    }

    private func value(_ statement: OpaquePointer, _ index: Int32) -> SQLValue {
        switch unsafe sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER: return .int(unsafe sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT: return .double(unsafe sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            guard let text = unsafe sqlite3_column_text(statement, index) else { return .text("") }
            return .text(unsafe String(cString: text))
        case SQLITE_BLOB:
            let count = Int(unsafe sqlite3_column_bytes(statement, index))
            guard count > 0, let bytes = unsafe sqlite3_column_blob(statement, index) else { return .blob(Data()) }
            return .blob(unsafe Data(bytes: bytes, count: count))
        default: return .null
        }
    }
}
