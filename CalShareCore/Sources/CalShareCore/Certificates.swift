// MARK: - Certificates.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// A private certificate authority, generated on this Mac. Devices trust the authority once
// (it ships inside the setup profile); the server certificate it signs can then be reissued
// at will — when it nears expiry, or when the Mac's names or addresses change — without
// anyone having to trust anything again.
//
// Certificates are built directly in DER (X.509 v3, ECDSA P-256 with SHA-256) and meet
// Apple's TLS requirements: subjectAltName present, serverAuth EKU, validity ≤ 398 days for
// the server certificate.

import CryptoKit
import Foundation
import Network
import Security

// MARK: - DER

enum DER {
    static func length(_ count: Int) -> Data {
        if count < 0x80 { return Data([UInt8(count)]) }
        var bytes: [UInt8] = []
        var value = count
        while value > 0 { bytes.insert(UInt8(value & 0xFF), at: 0); value >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    static func tlv(_ tag: UInt8, _ content: Data) -> Data { Data([tag]) + length(content.count) + content }
    static func sequence(_ parts: [Data]) -> Data { tlv(0x30, parts.reduce(Data(), +)) }
    static func set(_ parts: [Data]) -> Data { tlv(0x31, parts.reduce(Data(), +)) }
    static func explicit(_ number: UInt8, _ content: Data) -> Data { tlv(0xA0 | number, content) }
    static func octetString(_ data: Data) -> Data { tlv(0x04, data) }
    static func bitString(_ data: Data) -> Data { tlv(0x03, Data([0]) + data) }
    static func utf8String(_ string: String) -> Data { tlv(0x0C, Data(string.utf8)) }
    static func boolean(_ value: Bool) -> Data { tlv(0x01, Data([value ? 0xFF : 0x00])) }

    static func integer(_ bytes: Data) -> Data {
        var content = Data(bytes.drop { $0 == 0 })
        if content.isEmpty { content = Data([0]) }
        if content[content.startIndex] & 0x80 != 0 { content.insert(0, at: 0) }
        return tlv(0x02, content)
    }

    static func integer(_ value: Int) -> Data {
        var bytes: [UInt8] = []
        var remaining = value
        repeat { bytes.insert(UInt8(remaining & 0xFF), at: 0); remaining >>= 8 } while remaining > 0
        return integer(Data(bytes))
    }

    static func oid(_ dotted: String) -> Data {
        let parts = dotted.split(separator: ".").compactMap { UInt64($0) }
        var content = Data([UInt8(parts[0] * 40 + parts[1])])
        for part in parts.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(part & 0x7F)]
            var value = part >> 7
            while value > 0 { chunk.insert(UInt8(value & 0x7F) | 0x80, at: 0); value >>= 7 }
            content.append(contentsOf: chunk)
        }
        return tlv(0x06, content)
    }

    static func time(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        let year = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: date).year ?? 2026
        if year < 2050 {
            formatter.dateFormat = "yyMMddHHmmss'Z'"
            return tlv(0x17, Data(formatter.string(from: date).utf8))
        }
        formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        return tlv(0x18, Data(formatter.string(from: date).utf8))
    }
}

// MARK: - Certificate building

public struct CertificateMaterial: Sendable {
    public var certificateDER: Data
    public var privateKey: P256.Signing.PrivateKey
    public var notAfter: Date
    public var names: [String]
    public var addresses: [String]

    public var fingerprint: String { Hashing.fingerprint(certificateDER) }
}

public enum CertificateBuilder {
    static let ecPublicKey = "1.2.840.10045.2.1"
    static let prime256v1 = "1.2.840.10045.3.1.7"
    static let ecdsaWithSHA256 = "1.2.840.10045.4.3.2"

    static func name(commonName: String, organization: String) -> Data {
        DER.sequence([
            DER.set([DER.sequence([DER.oid("2.5.4.3"), DER.utf8String(commonName)])]),
            DER.set([DER.sequence([DER.oid("2.5.4.10"), DER.utf8String(organization)])]),
        ])
    }

    static func publicKeyInfo(_ key: P256.Signing.PublicKey) -> Data {
        DER.sequence([
            DER.sequence([DER.oid(ecPublicKey), DER.oid(prime256v1)]),
            DER.bitString(key.x963Representation),
        ])
    }

    static func extensionField(_ oid: String, critical: Bool, _ value: Data) -> Data {
        DER.sequence([DER.oid(oid)] + (critical ? [DER.boolean(true)] : []) + [DER.octetString(value)])
    }

    static func keyIdentifier(_ key: P256.Signing.PublicKey) -> Data { Hashing.sha1(key.x963Representation) }

    static func serialNumber() -> Data {
        var bytes = RandomToken.bytes(16)
        bytes[bytes.startIndex] &= 0x7F
        bytes[bytes.startIndex] |= 0x01   // never zero, never negative
        return bytes
    }

    static func sign(tbs: Data, with key: P256.Signing.PrivateKey) throws -> Data {
        let signature = try key.signature(for: tbs)
        return DER.sequence([tbs, DER.sequence([DER.oid(ecdsaWithSHA256)]), DER.bitString(signature.derRepresentation)])
    }

    /// A self-signed root, valid for ten years, that may only vouch for `permittedNames`
    /// (each with its subdomains) and the addresses in `NameConstraints.addressRanges`.
    /// macOS enforces the limit on a trusted root, so if the key ever leaked it could
    /// impersonate this Mac's own names, never a bank or any other public site.
    public static func makeAuthority(commonName: String, organization: String = "CalShare",
                                     permittedNames: [String] = NameConstraints.standardNames) throws -> CertificateMaterial {
        let key = P256.Signing.PrivateKey()
        let subject = name(commonName: commonName, organization: organization)
        let notBefore = Date().addingTimeInterval(-3600)
        let notAfter = notBefore.addingTimeInterval(10 * 365 * 86_400)
        let skid = keyIdentifier(key.publicKey)
        let extensions = DER.sequence([
            extensionField("2.5.29.19", critical: true, DER.sequence([DER.boolean(true), DER.integer(0)])),
            // keyCertSign (bit 5) and cRLSign (bit 6): 0b0000_0110 with 1 unused bit.
            extensionField("2.5.29.15", critical: true, DER.tlv(0x03, Data([0x01, 0x06]))),
            extensionField("2.5.29.14", critical: false, DER.octetString(skid)),
            extensionField("2.5.29.30", critical: true, NameConstraints.encode(names: permittedNames)),
        ])
        let tbs = DER.sequence([
            DER.explicit(0, DER.integer(2)),
            DER.integer(serialNumber()),
            DER.sequence([DER.oid(ecdsaWithSHA256)]),
            subject,
            DER.sequence([DER.time(notBefore), DER.time(notAfter)]),
            subject,
            publicKeyInfo(key.publicKey),
            DER.explicit(3, extensions),
        ])
        // `names` records the permitted names, so a later name can be checked against them.
        return CertificateMaterial(certificateDER: try sign(tbs: tbs, with: key), privateKey: key,
                                   notAfter: notAfter, names: permittedNames, addresses: [])
    }

    /// A server certificate for the given DNS names and IP addresses, signed by `authority`.
    public static func makeServerCertificate(names: [String], addresses: [String], authority: CertificateMaterial,
                                             authorityName: String, organization: String = "CalShare",
                                             validity: TimeInterval = 397 * 86_400) throws -> CertificateMaterial {
        let key = P256.Signing.PrivateKey()
        let notBefore = Date().addingTimeInterval(-3600)
        let notAfter = notBefore.addingTimeInterval(validity)
        var altNames: [Data] = names.map { DER.tlv(0x82, Data($0.utf8)) }
        for address in addresses {
            if let bytes = IPAddressBytes.parse(address) { altNames.append(DER.tlv(0x87, bytes)) }
        }
        let extensions = DER.sequence([
            extensionField("2.5.29.19", critical: true, DER.sequence([])),
            // digitalSignature (bit 0): 0b1000_0000 with 7 unused bits.
            extensionField("2.5.29.15", critical: true, DER.tlv(0x03, Data([0x07, 0x80]))),
            extensionField("2.5.29.37", critical: false, DER.sequence([DER.oid("1.3.6.1.5.5.7.3.1")])),
            extensionField("2.5.29.17", critical: false, DER.sequence(altNames)),
            extensionField("2.5.29.14", critical: false, DER.octetString(keyIdentifier(key.publicKey))),
            extensionField("2.5.29.35", critical: false, DER.sequence([DER.tlv(0x80, keyIdentifier(authority.privateKey.publicKey))])),
        ])
        let tbs = DER.sequence([
            DER.explicit(0, DER.integer(2)),
            DER.integer(serialNumber()),
            DER.sequence([DER.oid(ecdsaWithSHA256)]),
            name(commonName: authorityName, organization: organization),
            DER.sequence([DER.time(notBefore), DER.time(notAfter)]),
            name(commonName: names.first ?? addresses.first ?? "CalShare", organization: organization),
            publicKeyInfo(key.publicKey),
            DER.explicit(3, extensions),
        ])
        return CertificateMaterial(certificateDER: try sign(tbs: tbs, with: authority.privateKey), privateKey: key,
                                   notAfter: notAfter, names: names, addresses: addresses)
    }

    /// An in-memory identity for Network.framework. No keychain is involved, so there are
    /// no access prompts and nothing is left behind.
    public static func identity(for material: CertificateMaterial) -> SecIdentity? {
        guard let certificate = SecCertificateCreateWithData(nil, material.certificateDER as CFData) else { return nil }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 256,
        ]
        // No error out-parameter: the reason is never used, and an unconsumed one leaks.
        guard let key = SecKeyCreateWithData(material.privateKey.x963Representation as CFData,
                                             attributes as CFDictionary, nil) else { return nil }
        return SecIdentityCreate(nil, certificate, key)
    }

    /// Validates a server certificate against the authority, as a client would.
    public static func evaluate(_ server: CertificateMaterial, authority: CertificateMaterial, hostname: String) -> Bool {
        guard let leaf = SecCertificateCreateWithData(nil, server.certificateDER as CFData),
              let root = SecCertificateCreateWithData(nil, authority.certificateDER as CFData) else { return false }
        var trust: SecTrust?
        guard unsafe SecTrustCreateWithCertificates([leaf] as CFArray, SecPolicyCreateSSL(true, hostname as CFString), &trust) == errSecSuccess,
              let trust else { return false }
        SecTrustSetAnchorCertificates(trust, [root] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        return SecTrustEvaluateWithError(trust, nil)
    }
}

extension CertificateBuilder {
    /// Validates a server certificate as Calendar or Contacts on this Mac would: against
    /// the system's anchors and the user's trust settings, with the authority available
    /// only as a chain certificate (the way the server sends it), never as an anchor.
    public static func evaluateWithSystemTrust(_ server: CertificateMaterial, authority: CertificateMaterial, hostname: String) -> Bool {
        guard let leaf = SecCertificateCreateWithData(nil, server.certificateDER as CFData),
              let root = SecCertificateCreateWithData(nil, authority.certificateDER as CFData) else { return false }
        var trust: SecTrust?
        guard unsafe SecTrustCreateWithCertificates([leaf, root] as CFArray, SecPolicyCreateSSL(true, hostname as CFString), &trust) == errSecSuccess,
              let trust else { return false }
        SecTrustSetNetworkFetchAllowed(trust, false)
        return SecTrustEvaluateWithError(trust, nil)
    }
}

// MARK: - Name constraints

/// The names and addresses CalShare's authority may vouch for (RFC 5280 §4.2.1.10).
/// A server certificate carrying anything outside them is rejected as a whole, so the
/// server certificate is limited to what `permits` accepts.
public enum NameConstraints {
    /// Bonjour names and this Mac itself. Custom hostnames are added to these.
    public static let standardNames = ["local", "localhost"]

    /// Loopback, private LAN ranges, Tailscale's CGNAT range, and IPv6 unique local
    /// addresses: everything a device on the home network or a VPN can reach this Mac at.
    /// Public addresses are left out, since they could belong to anyone.
    static let addressRanges: [(address: [UInt8], prefix: Int)] = [
        ([127, 0, 0, 0], 8), ([10, 0, 0, 0], 8), ([172, 16, 0, 0], 12), ([192, 168, 0, 0], 16), ([100, 64, 0, 0], 10),
        ([UInt8](repeating: 0, count: 15) + [1], 128), ([0xFC] + [UInt8](repeating: 0, count: 15), 7),
    ]

    /// The permitted names for an authority that covers `customHostnames` as well.
    public static func names(customHostnames: [String]) -> [String] {
        var seen = Set<String>()
        return (standardNames + customHostnames.map { $0.lowercased() }).filter { seen.insert($0).inserted }
    }

    /// Whether `name` is one of `permitted` or below one, as a verifier matches dNSName.
    public static func permits(name: String, within permitted: [String]) -> Bool {
        let name = name.lowercased()
        return permitted.contains { name == $0 || name.hasSuffix(".\($0)") }
    }

    /// Whether `address` lies in one of the permitted ranges.
    public static func permits(address: String) -> Bool {
        guard let bytes = IPAddressBytes.parse(address).map(Array.init) else { return false }
        return addressRanges.contains { range in
            guard range.address.count == bytes.count else { return false }
            var remaining = range.prefix
            for index in bytes.indices where remaining > 0 {
                let bits = min(8, remaining)
                let mask = UInt8(truncatingIfNeeded: 0xFF << (8 - bits))
                if bytes[index] & mask != range.address[index] & mask { return false }
                remaining -= bits
            }
            return true
        }
    }

    /// NameConstraints ::= SEQUENCE { permittedSubtrees [0] GeneralSubtrees }, each subtree
    /// a dNSName [2] or an iPAddress [7] of address followed by mask.
    static func encode(names: [String]) -> Data {
        var subtrees = names.map { DER.sequence([DER.tlv(0x82, Data($0.utf8))]) }
        for range in addressRanges {
            var mask = [UInt8](repeating: 0, count: range.address.count)
            for bit in 0..<range.prefix { mask[bit / 8] |= 0x80 >> UInt8(bit % 8) }
            subtrees.append(DER.sequence([DER.tlv(0x87, Data(range.address + mask))]))
        }
        return DER.sequence([DER.tlv(0xA0, subtrees.reduce(Data(), +))])
    }
}

/// Strict numeric addresses only. inet_pton rather than Network's IPv4Address, which also
/// takes shorthand such as "127.1" and "0x7f.0.0.1" that no certificate or Host header
/// should carry. IPv4 bytes are read from the structure's field; IPv6 bytes, once inet_pton
/// has accepted the text, from Network's IPv6Address, which reads the same 16 bytes without
/// the C union.
enum IPAddressBytes {
    static func parse(_ text: String) -> Data? {
        var v4 = in_addr()
        if unsafe inet_pton(AF_INET, text, &v4) == 1 {
            // s_addr holds the address in network order.
            let value = UInt32(bigEndian: v4.s_addr)
            return Data([UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
        }
        var v6 = in6_addr()
        if unsafe inet_pton(AF_INET6, text, &v6) == 1, let address = IPv6Address(text) {
            return address.rawValue
        }
        return nil
    }
}

// MARK: - Persistence

/// Stores the authority and server certificate in the app's (sandboxed, user-only) data
/// folder, keys PEM-free as raw x9.63, with 0600 permissions.
public struct CertificateStore: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    struct Record: Codable {
        var certificate: Data
        var key: Data
        var notAfter: Date
        var names: [String]
        var addresses: [String]
    }

    public func load(_ name: String) -> CertificateMaterial? {
        let url = directory.appendingPathComponent("\(name).json")
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              let key = try? P256.Signing.PrivateKey(x963Representation: record.key),
              SecCertificateCreateWithData(nil, record.certificate as CFData) != nil else { return nil }
        return CertificateMaterial(certificateDER: record.certificate, privateKey: key, notAfter: record.notAfter,
                                   names: record.names, addresses: record.addresses)
    }

    public func save(_ material: CertificateMaterial, as name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let record = Record(certificate: material.certificateDER, key: material.privateKey.x963Representation,
                            notAfter: material.notAfter, names: material.names, addresses: material.addresses)
        let url = directory.appendingPathComponent("\(name).json")
        try JSONEncoder().encode(record).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func remove(_ name: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(name).json"))
    }
}
