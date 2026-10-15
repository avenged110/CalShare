// MARK: - Auth.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// Password hashing (PBKDF2-HMAC-SHA256), HTTP Basic authentication, a short-lived cache of
// verified credentials (Apple's clients authenticate every request, and PBKDF2 is slow on
// purpose), and per-address lockout after repeated failures.

import CommonCrypto
import CryptoKit
import Foundation

public enum PasswordHasher {
    public static let iterations: UInt32 = 210_000

    public static func hash(_ password: String, iterations: UInt32 = iterations) -> String {
        let salt = RandomToken.bytes(16)
        // Only zero iterations can fail: a programming error, as before.
        guard let derived = derive(password, salt: salt, iterations: iterations) else {
            preconditionFailure("PBKDF2 failed")
        }
        return "pbkdf2-sha256$\(iterations)$\(salt.base64EncodedString())$\(derived.base64EncodedString())"
    }

    public static func verify(_ password: String, against stored: String) -> Bool {
        let parts = stored.split(separator: "$")
        // Zero iterations is refused by CommonCrypto; a stored hash claiming it is damaged.
        guard parts.count == 4, parts[0] == "pbkdf2-sha256", let iterations = UInt32(parts[1]), iterations > 0,
              let salt = Data(base64Encoded: String(parts[2])), let expected = Data(base64Encoded: String(parts[3])),
              let derived = derive(password, salt: salt, iterations: iterations) else {
            return false
        }
        return constantTimeEqual(derived, expected)
    }

    /// The derived key, or nil if CommonCrypto refuses the parameters. CryptoKit has no
    /// PBKDF2, so this is the one place passwords meet a C API. Its inputs are Swift arrays
    /// passed by implicit bridging, which stay alive for the length of the call.
    static func derive(_ password: String, salt: Data, iterations: UInt32) -> Data? {
        var derived = [UInt8](repeating: 0, count: 32)
        let passwordBytes = Array(password.utf8).map { CChar(bitPattern: $0) }
        let saltBytes = Array(salt)
        let status = unsafe CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            passwordBytes, passwordBytes.count,
            saltBytes, saltBytes.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
            &derived, derived.count)
        return status == kCCSuccess ? Data(derived) : nil
    }

    public static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<a.count { difference |= a[a.startIndex + index] ^ b[b.startIndex + index] }
        return difference == 0
    }
}

public struct BasicCredentials: Sendable, Equatable {
    public var username: String
    public var password: String

    public static func parse(_ header: String?) -> BasicCredentials? {
        guard let header else { return nil }
        let parts = header.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "basic",
              let decoded = Data(base64Encoded: String(parts[1]).trimmingCharacters(in: .whitespaces)),
              let text = String(data: decoded, encoding: .utf8),
              let colon = text.firstIndex(of: ":") else { return nil }
        return BasicCredentials(username: String(text[text.startIndex..<colon]),
                                password: String(text[text.index(after: colon)...]))
    }
}

public final class Authenticator: @unchecked Sendable {
    public enum Outcome: Sendable, Equatable {
        case success(User)
        case failure
        case lockedOut(retryAfter: TimeInterval)
    }

    private struct Attempts { var failures: Int; var windowStart: Date; var lockedUntil: Date?; var lockouts: Int }
    private struct CacheEntry { var userID: Int64; var expires: Date; var passwordHash: String }

    private let store: Store
    private let state = Locked<(attempts: [String: Attempts], cache: [Data: CacheEntry])>(([:], [:]))
    private let cacheKey = SymmetricKey(size: .bits256)
    public var maxFailures = 8
    public var failureWindow: TimeInterval = 15 * 60
    public var cacheLifetime: TimeInterval = 10 * 60
    /// Reports lockouts to the activity log.
    public let onLockout = Locked<(@Sendable (String) -> Void)?>(nil)

    public init(store: Store) { self.store = store }

    /// A well-formed hash of a random password, verified against when the account doesn't exist.
    private static let decoyHash = PasswordHasher.hash(RandomToken.urlSafe())

    /// What failures are counted against: the address itself for IPv4, and its /64 for
    /// IPv6, since one network is handed a whole /64 and could otherwise move to a fresh
    /// address every few guesses.
    static func lockoutKey(_ address: String) -> String {
        guard address.contains(":"), let bytes = IPAddressBytes.parse(address), bytes.count == 16 else { return address }
        let groups = stride(from: 0, to: 8, by: 2).map { String(UInt16(bytes[bytes.startIndex + $0]) << 8 | UInt16(bytes[bytes.startIndex + $0 + 1]), radix: 16) }
        return groups.joined(separator: ":") + "::/64"
    }

    public func authenticate(_ credentials: BasicCredentials?, from remoteAddress: String) -> Outcome {
        let address = Self.lockoutKey(remoteAddress)
        let now = Date()
        if let locked = state.withLock({ $0.attempts[address]?.lockedUntil }), locked > now {
            return .lockedOut(retryAfter: locked.timeIntervalSince(now))
        }
        guard let credentials, !credentials.username.isEmpty else { return .failure }
        let username = credentials.username.lowercased()

        // Cached verification: keyed by an HMAC of the credentials, so plaintext never sits
        // in memory longer than the request, and invalidated when the stored hash changes.
        let key = Data(HMAC<SHA256>.authenticationCode(for: Data("\(username):\(credentials.password)".utf8), using: cacheKey))
        if let entry = state.withLock({ $0.cache[key] }), entry.expires > now,
           let user = try? store.user(named: username), user.id == entry.userID, user.passwordHash == entry.passwordHash {
            return .success(user)
        }

        let user = try? store.user(named: username)
        // An unknown account costs the same PBKDF2 run as a wrong password, so response
        // times don't tell which account names exist.
        if PasswordHasher.verify(credentials.password, against: user?.passwordHash ?? Self.decoyHash), let user {
            state.withLock {
                $0.attempts[address] = nil
                if $0.cache.count > 256 { $0.cache.removeAll() }
                $0.cache[key] = CacheEntry(userID: user.id, expires: now.addingTimeInterval(cacheLifetime), passwordHash: user.passwordHash)
            }
            return .success(user)
        }
        recordFailure(address: address, now: now)
        return .failure
    }

    private func recordFailure(address: String, now: Date) {
        var lockedFor: TimeInterval?
        state.withLock { state in
            var attempts = state.attempts[address] ?? Attempts(failures: 0, windowStart: now, lockedUntil: nil, lockouts: 0)
            if now.timeIntervalSince(attempts.windowStart) > failureWindow {
                attempts.failures = 0
                attempts.windowStart = now
            }
            attempts.failures += 1
            if attempts.failures >= maxFailures {
                // 1, 2, 4 ... minutes, capped at an hour.
                let duration = min(60 * pow(2, Double(attempts.lockouts)), 3_600)
                attempts.lockedUntil = now.addingTimeInterval(duration)
                attempts.lockouts += 1
                attempts.failures = 0
                lockedFor = duration
            }
            state.attempts[address] = attempts
            if state.attempts.count > 4_096 { state.attempts = state.attempts.filter { $0.value.lockedUntil.map { $0 > now } ?? false } }
        }
        if let lockedFor {
            onLockout.current?("Blocked \(address) for \(Int(lockedFor / 60)) min after repeated failed sign-ins")
        }
    }

    public func clearLockouts() { state.withLock { $0.attempts.removeAll() } }

    public func invalidateCache() { state.withLock { $0.cache.removeAll() } }

    public var lockedOutAddresses: [String] {
        let now = Date()
        return state.withLock { $0.attempts.filter { ($0.value.lockedUntil ?? .distantPast) > now }.map(\.key) }.sorted()
    }
}
