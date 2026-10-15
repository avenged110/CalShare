// MARK: - Enrollment.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// The plain-HTTP side of CalShare. It serves exactly three things: well-known redirects to
// the secure server, the authority certificate, and single-use setup links that hand a
// device its configuration profile. Nothing that touches calendar data is reachable here.

import Foundation

public struct EnrollmentToken: Sendable, Equatable {
    public var token: String
    public var username: String
    public var expires: Date
    /// The address that downloaded the profile, and when; nil until it's used.
    public var usedBy: String?
    public var usedAt: Date?
}

public final class EnrollmentHandler: @unchecked Sendable, Loggable {
    public static let logTag = "[Enroll]"

    public let tokens = Locked<[String: EnrollmentToken]>([:])
    /// Builds the profile for an account, or nil if it cannot be built right now.
    let profileProvider: @Sendable (String) -> Data?
    let authorityProvider: @Sendable () -> Data?
    let secureEndpoint: @Sendable () -> (port: UInt16, hostname: String)
    public let onEnrollment = Locked<(@Sendable (String, String) -> Void)?>(nil)
    /// Counts links used, so a page showing one can replace it once it's spent.
    public let uses = Locked(0)

    /// How long the device that used a link may fetch it again: Safari can request a
    /// download twice, and someone who taps Ignore on the download prompt can retry.
    public static let reuseGrace: TimeInterval = 2 * 60

    public init(profileProvider: @escaping @Sendable (String) -> Data?,
                authorityProvider: @escaping @Sendable () -> Data?,
                secureEndpoint: @escaping @Sendable () -> (port: UInt16, hostname: String)) {
        self.profileProvider = profileProvider
        self.authorityProvider = authorityProvider
        self.secureEndpoint = secureEndpoint
    }

    /// How long a setup link works.
    public static let defaultLifetime: TimeInterval = 15 * 60

    public func issueToken(for username: String, lifetime: TimeInterval = defaultLifetime) -> EnrollmentToken {
        let token = EnrollmentToken(token: RandomToken.urlSafe(18), username: username, expires: Date().addingTimeInterval(lifetime))
        tokens.withLock { tokens in
            let now = Date()
            tokens = tokens.filter { $0.value.expires > now }
            tokens[token.token] = token
        }
        return token
    }

    public func revokeTokens(for username: String) {
        tokens.withLock { $0 = $0.filter { $0.value.username != username } }
    }

    public func handle(_ request: HTTPRequest) -> HTTPResponse {
        guard request.method == "GET" || request.method == "HEAD" || request.method == "PROPFIND" || request.method == "OPTIONS" else {
            return .text(405, "Method not allowed")
        }
        var response = route(request)
        if request.method == "HEAD" { response.omitBody = true }
        log("\(request.method) \(request.path.hasPrefix("/enroll/") ? "/enroll/…" : request.path) → \(response.status) from \(request.remoteAddress)", level: .debug)
        return response
    }

    private func route(_ request: HTTPRequest) -> HTTPResponse {
        let path = request.path
        let endpoint = secureEndpoint()
        let requestedHost = Self.hostWithoutPort(request.headers["Host"]) ?? endpoint.hostname
        let secureBase = "https://\(Self.bracketed(requestedHost)):\(endpoint.port)"

        switch path.lowercased() {
        case "/.well-known/caldav", "/.well-known/carddav", "/.well-known/caldav/", "/.well-known/carddav/", "/dav", "/dav/":
            var response = HTTPResponse(status: 301)
            response.headers["Location"] = "\(secureBase)/dav/"
            return response
        case "/calshare-authority.cer", "/ca.cer":
            guard let der = authorityProvider() else { return .text(503, "Not ready") }
            var response = HTTPResponse(status: 200, body: der)
            response.headers["Content-Type"] = "application/x-x509-ca-cert"
            response.headers["Content-Disposition"] = "attachment; filename=\"CalShare-Authority.cer\""
            return response
        case "/", "/index.html":
            return HTTPResponse(status: 200, contentType: "text/html; charset=utf-8", body: Self.landingPage)
        default:
            break
        }
        if path.hasPrefix("/enroll/") {
            guard request.method == "GET" || request.method == "HEAD" else { return .text(405, "Method not allowed") }
            let token = String(path.dropFirst("/enroll/".count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let address = request.remoteAddress
            guard let entry = tokens.withLock({ $0[token] }), Self.usable(entry, by: address, at: Date()) else {
                return Self.spentPage
            }
            guard let profile = profileProvider(entry.username) else { return .text(503, "The server is not ready yet.") }
            // HEAD only looks; GET spends the link. Claimed under the lock, so two devices
            // racing for one link can't both get the profile.
            if request.method == "GET" {
                let claimed = tokens.withLock { tokens -> Bool in
                    guard var current = tokens[token], Self.usable(current, by: address, at: Date()) else { return false }
                    if current.usedBy == nil {
                        current.usedBy = address
                        current.usedAt = Date()
                        tokens[token] = current
                        uses.withLock { $0 += 1 }
                    }
                    return true
                }
                guard claimed else { return Self.spentPage }
                onEnrollment.current?(entry.username, address)
            }
            var response = HTTPResponse(status: 200, body: profile)
            response.headers["Content-Type"] = "application/x-apple-aspen-config"
            response.headers["Content-Disposition"] = "attachment; filename=\"CalShare-\(entry.username).mobileconfig\""
            response.headers["Cache-Control"] = "no-store"
            return response
        }
        return .text(404, "Not found")
    }

    /// Unexpired, and either unused or used by this address within the grace period.
    static func usable(_ entry: EnrollmentToken, by address: String, at now: Date) -> Bool {
        guard entry.expires > now else { return false }
        guard let usedBy = entry.usedBy, let usedAt = entry.usedAt else { return true }
        return usedBy == address && now.timeIntervalSince(usedAt) < reuseGrace
    }

    static let spentPage = HTTPResponse(status: 404, contentType: "text/html; charset=utf-8", body: page(
        title: "This setup link has expired",
        body: "Each link works once. Open CalShare on your Mac and show a new QR code to continue."))

    static func hostWithoutPort(_ header: String?) -> String? {
        guard var host = header?.trimmingCharacters(in: .whitespaces), !host.isEmpty else { return nil }
        if host.hasPrefix("[") {
            if let close = host.firstIndex(of: "]") { return String(host[host.index(after: host.startIndex)..<close]) }
            return nil
        }
        if let colon = host.lastIndex(of: ":") { host = String(host[host.startIndex..<colon]) }
        return ServerConfiguration.isValidHostname(host) || IPAddressBytes.parse(host) != nil ? host : nil
    }

    static func bracketed(_ host: String) -> String { host.contains(":") ? "[\(host)]" : host }

    static func page(title: String, body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>CalShare</title><style>body{font:17px -apple-system,system-ui,sans-serif;margin:0;padding:48px 24px;\
        color:#1d1d1f;background:#f5f5f7;text-align:center}h1{font-size:24px}p{color:#555;max-width:32em;margin:12px auto}\
        @media(prefers-color-scheme:dark){body{color:#f5f5f7;background:#1d1d1f}p{color:#aaa}}</style></head>
        <body><h1>\(XMLEscape.text(title))</h1><p>\(XMLEscape.text(body))</p></body></html>
        """
    }

    static let landingPage = page(
        title: "CalShare",
        body: "This Mac shares calendars and contacts with your devices. To set up an iPhone or iPad, open CalShare on the Mac and scan its setup QR code with the Camera.")
}
