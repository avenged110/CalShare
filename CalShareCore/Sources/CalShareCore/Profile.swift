// MARK: - Profile.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// Apple configuration profiles (.mobileconfig) that set up a device in one step: trust the
// CalShare authority, then add the CalDAV and CardDAV accounts. The password is left out
// by default, so the device asks for it during installation and the profile itself holds
// no secret.

import Foundation

public struct ProfileRequest: Sendable {
    public var username: String
    public var displayName: String
    public var hostname: String
    public var port: UInt16
    public var authorityDER: Data
    public var authorityFingerprint: String
    public var serverName: String
    public var password: String?
    /// Whether the profile carries the authority certificate.
    public var includeAuthority: Bool

    public init(username: String, displayName: String, hostname: String, port: UInt16, authorityDER: Data,
                authorityFingerprint: String, serverName: String, password: String? = nil, includeAuthority: Bool = true) {
        self.username = username; self.displayName = displayName; self.hostname = hostname; self.port = port
        self.authorityDER = authorityDER; self.authorityFingerprint = authorityFingerprint
        self.serverName = serverName; self.password = password; self.includeAuthority = includeAuthority
    }
}

public enum ProfileBuilder {
    /// Stable identifiers mean installing a newer profile replaces the old one.
    static func identifier(_ request: ProfileRequest, _ suffix: String) -> String {
        "app.calshare.profile.\(request.username).\(suffix)"
    }

    public static func build(_ request: ProfileRequest) throws -> Data {
        let principal = "https://\(request.hostname):\(request.port)/dav/principals/\(URLPath.encode(request.username))/"
        let accountName = request.serverName == "CalShare" ? "CalShare" : "\(request.serverName) (CalShare)"
        var caldav: [String: Any] = [
            "PayloadType": "com.apple.caldav.account",
            "PayloadVersion": 1,
            "PayloadIdentifier": identifier(request, "caldav"),
            "PayloadUUID": UUID().uuidString,
            "PayloadDisplayName": "\(accountName) Calendars",
            "CalDAVAccountDescription": accountName,
            "CalDAVHostName": request.hostname,
            "CalDAVPort": Int(request.port),
            "CalDAVPrincipalURL": principal,
            "CalDAVUseSSL": true,
            "CalDAVUsername": request.username,
        ]
        var carddav: [String: Any] = [
            "PayloadType": "com.apple.carddav.account",
            "PayloadVersion": 1,
            "PayloadIdentifier": identifier(request, "carddav"),
            "PayloadUUID": UUID().uuidString,
            "PayloadDisplayName": "\(accountName) Contacts",
            "CardDAVAccountDescription": accountName,
            "CardDAVHostName": request.hostname,
            "CardDAVPort": Int(request.port),
            "CardDAVPrincipalURL": principal,
            "CardDAVUseSSL": true,
            "CardDAVUsername": request.username,
        ]
        if let password = request.password {
            caldav["CalDAVPassword"] = password
            carddav["CardDAVPassword"] = password
        }
        let authority: [String: Any] = [
            "PayloadType": "com.apple.security.root",
            "PayloadVersion": 1,
            "PayloadIdentifier": identifier(request, "authority"),
            "PayloadUUID": UUID().uuidString,
            "PayloadDisplayName": "CalShare Local Authority",
            "PayloadCertificateFileName": "CalShare-Authority.cer",
            "PayloadContent": request.authorityDER,
        ]
        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": identifier(request, "root"),
            "PayloadUUID": UUID().uuidString,
            "PayloadDisplayName": "\(accountName) — \(request.username)",
            "PayloadOrganization": "CalShare",
            "PayloadDescription": """
                Adds your calendars, reminders, and contacts from \(request.serverName) (\(request.hostname)) \
                for the account “\(request.username)”\(request.includeAuthority ? ", and trusts the private certificate authority that secures the connection" : ""). \
                Authority fingerprint (SHA-256): \(request.authorityFingerprint)
                """,
            "PayloadRemovalDisallowed": false,
            "PayloadContent": request.includeAuthority ? [authority, caldav, carddav] : [caldav, carddav],
        ]
        return try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
    }
}
