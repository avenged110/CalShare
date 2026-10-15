// MARK: - Configuration.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// The few settings a user can change, persisted as JSON with atomic writes. An unreadable
// file is set aside (never deleted) and replaced with defaults, so a damaged settings file
// can never keep the server from starting.

import Foundation

public struct ServerConfiguration: Codable, Equatable, Sendable {
    /// Fixed: the name in Bonjour, on devices and in profiles is always CalShare.
    public var serverName: String { "CalShare" }
    public var httpsPort: UInt16 = 8443
    public var httpPort: UInt16 = 8080
    /// Extra names for the certificate and profiles: a Tailscale MagicDNS name, a
    /// dynamic-DNS name, or a name from the router's DNS.
    public var customHostnames: [String] = []
    /// The name devices are told to use. nil means the Mac's .local name (its IP address
    /// when it has none), which follows the Mac when the router gives it a new address.
    public var preferredHostname: String?
    /// The Mac's local network IP address when last seen, so a change (even one made while
    /// CalShare wasn't running) is noticed and shown.
    public var lastLANAddress: String?
    /// False in settings from versions whose automatic identity was the IP address; those
    /// are moved to that address explicitly once, so their devices keep working.
    public var automaticIsLocalName = true
    public var bonjourEnabled = true
    public var keepAwake = false
    public var setupCompleted = false
    /// Whether this Mac has been given a setup profile (it syncs as a client of itself).
    public var thisMacEnrolled = false
    public var hourlyBackupsToKeep = 24
    public var dailyBackupsToKeep = 14

    public init() {}

    // Decoding tolerates missing keys, so adding a setting never invalidates an older file.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ServerConfiguration()
        httpsPort = try container.decodeIfPresent(UInt16.self, forKey: .httpsPort) ?? defaults.httpsPort
        httpPort = try container.decodeIfPresent(UInt16.self, forKey: .httpPort) ?? defaults.httpPort
        customHostnames = try container.decodeIfPresent([String].self, forKey: .customHostnames) ?? []
        preferredHostname = try container.decodeIfPresent(String.self, forKey: .preferredHostname)
        lastLANAddress = try container.decodeIfPresent(String.self, forKey: .lastLANAddress)
        automaticIsLocalName = try container.decodeIfPresent(Bool.self, forKey: .automaticIsLocalName) ?? false
        bonjourEnabled = try container.decodeIfPresent(Bool.self, forKey: .bonjourEnabled) ?? defaults.bonjourEnabled
        keepAwake = try container.decodeIfPresent(Bool.self, forKey: .keepAwake) ?? defaults.keepAwake
        setupCompleted = try container.decodeIfPresent(Bool.self, forKey: .setupCompleted) ?? false
        thisMacEnrolled = try container.decodeIfPresent(Bool.self, forKey: .thisMacEnrolled) ?? false
        hourlyBackupsToKeep = try container.decodeIfPresent(Int.self, forKey: .hourlyBackupsToKeep) ?? defaults.hourlyBackupsToKeep
        dailyBackupsToKeep = try container.decodeIfPresent(Int.self, forKey: .dailyBackupsToKeep) ?? defaults.dailyBackupsToKeep
    }

    public static func isValidHostname(_ name: String) -> Bool {
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard !name.isEmpty, name.count <= 253, !labels.isEmpty else { return false }
        // An all-numeric last label is an IP address, not a hostname (RFC 3696 §2): it would
        // go into the certificate as a name, which no device matches against an address.
        guard let last = labels.last, !last.allSatisfy(\.isNumber) else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" }
        }
    }
}

public struct ConfigurationStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    /// Loads the configuration; the second value describes any recovery that happened.
    public func load() -> (ServerConfiguration, String?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (ServerConfiguration(), nil) }
        do {
            let data = try Data(contentsOf: url)
            return (try JSONDecoder().decode(ServerConfiguration.self, from: data), nil)
        } catch {
            let aside = url.deletingPathExtension().appendingPathExtension("damaged-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: aside)
            return (ServerConfiguration(), "Settings could not be read and were reset to defaults (the old file was kept as \(aside.lastPathComponent)).")
        }
    }

    public func save(_ configuration: ServerConfiguration) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: url, options: [.atomic])
    }
}
