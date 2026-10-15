// MARK: - Support.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// Small, dependency-free helpers shared by every layer: hashing, random tokens, HTTP
// dates, XML escaping and URL path handling.

import CryptoKit
import Foundation

public enum Hashing {
    public static func sha256Hex(_ data: Data) -> String { hex(SHA256.hash(data: data)) }

    public static func sha256Hex(_ string: String) -> String { sha256Hex(Data(string.utf8)) }

    public static func sha1(_ data: Data) -> Data { Data(Insecure.SHA1.hash(data: data)) }

    /// Colon-separated uppercase SHA-256 fingerprint, the form Settings shows for a certificate.
    public static func fingerprint(_ data: Data) -> String {
        hex(SHA256.hash(data: data), uppercase: true, separator: ":")
    }

    /// Two hex digits per byte. Built by hand rather than with `String(format:)`, whose
    /// C variadic arguments are unchecked.
    static func hex(_ bytes: some Sequence<UInt8>, uppercase: Bool = false, separator: String = "") -> String {
        let digits = Array(uppercase ? "0123456789ABCDEF" : "0123456789abcdef")
        return bytes.map { String([digits[Int($0 >> 4)], digits[Int($0 & 0x0F)]]) }.joined(separator: separator)
    }
}

public enum RandomToken {
    /// Bytes from the system CSPRNG (`SystemRandomNumberGenerator` is arc4random_buf on
    /// Apple platforms), with no pointer handling and no failure path.
    public static func bytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<max(0, count)).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    /// URL-safe base64 without padding.
    public static func urlSafe(_ count: Int = 24) -> String {
        bytes(count).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// A password that is easy to read aloud and type on a phone: four groups of five
    /// characters from an alphabet without look-alikes (no 0/O, 1/l/I).
    public static func password() -> String {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var groups: [String] = []
        for _ in 0..<4 {
            var group = ""
            for _ in 0..<5 { group.append(alphabet[uniform(alphabet.count)]) }
            groups.append(group)
        }
        return groups.joined(separator: "-")
    }

    /// Unbiased random integer in `0..<upperBound` from the system CSPRNG.
    static func uniform(_ upperBound: Int) -> Int {
        var generator = SystemRandomNumberGenerator()
        return Int.random(in: 0..<upperBound, using: &generator)
    }
}

public enum HTTPDate {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()
    private static let lock = NSLock()

    public static func string(_ date: Date) -> String {
        lock.withLock { formatter.string(from: date) }
    }
}

public enum XMLEscape {
    public static func text(_ string: String) -> String {
        var out = ""
        out.reserveCapacity(string.utf8.count)
        for scalar in string.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            default:
                // Characters XML 1.0 cannot carry at all are dropped rather than emitted.
                if scalar.value < 0x20 || (0xFFFE...0xFFFF).contains(scalar.value) { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}

public enum URLPath {
    /// Splits a raw request path into decoded segments, rejecting traversal and NULs.
    /// Returns nil for paths that are not acceptable at all.
    public static func segments(_ rawPath: String) -> [String]? {
        let pathOnly = rawPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        var result: [String] = []
        for piece in pathOnly.split(separator: "/", omittingEmptySubsequences: true) {
            guard let decoded = String(piece).removingPercentEncoding else { return nil }
            if decoded == "." || decoded == ".." || decoded.contains("/")
                || decoded.contains("\0") { return nil }
            result.append(decoded)
        }
        return result
    }

    /// Percent-encodes a single path segment.
    public static func encode(_ segment: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/;?#")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
    }

    /// Builds an absolute path from segments, with a trailing slash for collections.
    public static func build(_ segments: [String], collection: Bool) -> String {
        let body = segments.map(encode).joined(separator: "/")
        if segments.isEmpty { return "/" }
        return "/" + body + (collection ? "/" : "")
    }
}

/// A simple lock-protected box for state shared across queues.
public final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    public init(_ value: Value) { self.value = value }

    public func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    public var current: Value { withLock { $0 } }
}

public extension Date {
    /// How long ago this was, for things that have already happened: "just now" for the first
    /// minute, then "1 minute ago", "2 minutes ago" and so on. Never "in …": a timestamp a hair
    /// ahead of the clock reads as just now.
    var relative: String {
        let elapsed = Date().timeIntervalSince(self)
        guard elapsed >= 60 else { return "just now" }
        return RelativeDateTimeFormatter().localizedString(fromTimeInterval: -elapsed)
    }
}
