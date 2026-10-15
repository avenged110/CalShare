// MARK: - DAVHandler.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// The WebDAV (RFC 4918), CalDAV (RFC 4791), CardDAV (RFC 6352), extended MKCOL (RFC 5689),
// sync-collection (RFC 6578) and current-user-principal (RFC 5397) surface, plus the Apple
// and CalendarServer properties Apple's clients read (calendar color/order, getctag).
//
// URL space:
//   /dav/                                   root
//   /dav/principals/<user>/                 principal
//   /dav/calendars/<user>/<calendar>/<obj>  calendar home, calendars, calendar objects
//   /dav/addressbooks/<user>/<book>/<card>  address book home, books, cards

import CryptoKit
import Foundation

public struct RequestLogEntry: Sendable, Identifiable, Equatable {
    public let id = UUID()
    public var date: Date
    public var method: String
    public var path: String
    public var status: Int
    public var username: String?
    public var client: String
    public var remoteAddress: String
    public var milliseconds: Int
    /// The size of the response body.
    public var bytes = 0
    /// A digest of a large body (see `RepeatDetector`), so the same content sent again can
    /// be told from a listing that changed; empty for small ones.
    public var digest = ""
}

public struct ClientRecord: Sendable, Equatable, Identifiable, Codable {
    /// One record per account, service, and machine, so the same service on two devices
    /// shows as two.
    public var id: String { "\(username)|\(product)|\(platform)|\(remoteAddress)" }
    public var username: String
    /// "iOS 18.6", "macOS 15.6", or the raw product token.
    public var platform: String
    /// The daemon or app making the request: "dataaccessd", "CalendarAgent", ...
    public var product: String
    public var remoteAddress: String
    public var lastSeen: Date
}

public final class DAVHandler: @unchecked Sendable, Loggable {
    public static let logTag = "[DAV]"

    public let store: Store
    public let authenticator: Authenticator
    public var maxResourceSize = 20 * 1024 * 1024
    public let realm = "CalShare"
    /// Called after every request, for the activity log.
    public let onRequest = Locked<(@Sendable (RequestLogEntry) -> Void)?>(nil)
    /// Reports a stored item a search couldn't parse, once per version of it. Such an item is
    /// returned unfiltered rather than left out, so no device silently loses it.
    public let onUnreadableResource = Locked<(@Sendable (String) -> Void)?>(nil)
    private let reportedUnreadable = Locked<Set<String>>([])
    public let clients = Locked<[String: ClientRecord]>([:])

    static let syncTokenPrefix = "http://calshare.app/ns/sync/"

    public init(store: Store, authenticator: Authenticator) {
        self.store = store
        self.authenticator = authenticator
    }

    // MARK: Entry point

    public func handle(_ request: HTTPRequest) -> HTTPResponse {
        let started = Date()
        var authenticatedUser: String?
        var response: HTTPResponse
        do {
            response = try route(request, signedIn: nil, authenticatedUser: &authenticatedUser)
        } catch let error as DAVError {
            response = error.response
        } catch let error as SQLiteError {
            log("Storage error on \(request.method) \(request.path): \(error)", level: .error)
            response = .text(503, "The calendar database is temporarily unavailable.")
        } catch {
            log("Unexpected error on \(request.method) \(request.path): \(error)", level: .error)
            response = .text(500, "Internal error")
        }
        if request.method == "HEAD" { response.omitBody = true }
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        let userAgent = request.headers["User-Agent"] ?? ""
        let entry = RequestLogEntry(date: started, method: request.method, path: request.path, status: response.status,
                                    username: authenticatedUser, client: userAgent, remoteAddress: request.remoteAddress,
                                    milliseconds: elapsed, bytes: response.body.count,
                                    digest: response.body.count >= RepeatDetector.minimumBytes ? SHA256.hash(data: response.body).description : "")
        // Depth and response size show what a client actually asked for and got, which is
        // what tells a full listing of a collection apart from a quick property check.
        let depth = request.headers["Depth"].map { ", Depth \($0)" } ?? ""
        let size = response.body.isEmpty ? "" : ", \(ByteCountFormatter.string(fromByteCount: Int64(response.body.count), countStyle: .file))"
        log("\(request.method) \(request.path) → \(response.status) (\(elapsed) ms\(depth)\(size), \(authenticatedUser ?? "-"), \(userAgent))", level: .debug)
        if let user = authenticatedUser { recordClient(user: user, userAgent: userAgent, address: request.remoteAddress) }
        onRequest.current?(entry)
        return response
    }

    /// Answers a request as `user` without sign-in, for the app's own checks. It isn't
    /// reachable from the network (the servers only call `handle(_:)`), and it leaves no
    /// trace in the request log or the device list.
    func handleInternally(_ request: HTTPRequest, as user: User) -> HTTPResponse {
        var authenticatedUser: String?
        do {
            return try route(request, signedIn: user, authenticatedUser: &authenticatedUser)
        } catch let error as DAVError {
            return error.response
        } catch {
            return .text(500, "\(error)")
        }
    }

    private func recordClient(user: String, userAgent: String, address: String) {
        guard !userAgent.isEmpty else { return }
        let parsed = Self.describeClient(userAgent)
        let record = ClientRecord(username: user, platform: parsed.platform, product: parsed.product,
                                  remoteAddress: address, lastSeen: Date())
        clients.withLock { $0[record.id] = record }
    }

    /// Apple user agents look like "iOS/18.6 (22G86) dataaccessd/1.0" or
    /// "macOS/15.6 (24G84) CalendarAgent/1012".
    static func describeClient(_ userAgent: String) -> (platform: String, product: String) {
        let tokens = userAgent.split(separator: " ")
        guard let first = tokens.first else { return (userAgent, "") }
        let pair = first.split(separator: "/", maxSplits: 1)
        var platform = String(first)
        if pair.count == 2 {
            let name = pair[0].replacingOccurrences(of: "+", with: " ")
            platform = "\(name == "Mac OS X" ? "macOS" : name) \(pair[1])"
        }
        let product = tokens.dropFirst().first { $0.contains("/") && !$0.hasPrefix("(") }
            .map { String($0.split(separator: "/").first ?? "") } ?? ""
        return (platform, product)
    }

    private func route(_ request: HTTPRequest, signedIn: User?, authenticatedUser: inout String?) throws -> HTTPResponse {
        let path = request.path
        let lowered = path.lowercased()
        if lowered == "/.well-known/caldav" || lowered == "/.well-known/carddav"
            || lowered == "/.well-known/caldav/" || lowered == "/.well-known/carddav/" {
            var response = HTTPResponse(status: 301)
            response.headers["Location"] = "/dav/"
            return response
        }
        guard let segments = URLPath.segments(path) else { throw DAVError.status(400, "Bad path") }
        let isRoot = segments.isEmpty
        guard isRoot || segments.first == "dav" else { throw DAVError.status(404, "Not found") }

        if request.method == "OPTIONS" { return options() }
        if isRoot && request.method == "GET" {
            return HTTPResponse(status: 200, contentType: "text/plain; charset=utf-8",
                                body: "CalShare is running. Add this server to Calendar or Contacts as a CalDAV/CardDAV account.\n")
        }

        // Everything else requires a signed-in account.
        let user: User
        if let signedIn {
            user = signedIn
            authenticatedUser = signedIn.username
        } else {
            switch authenticator.authenticate(BasicCredentials.parse(request.headers["Authorization"]), from: request.remoteAddress) {
            case .success(let signedIn):
                user = signedIn
                authenticatedUser = signedIn.username
            case .failure:
                var response = HTTPResponse.text(401, "Authentication required")
                response.headers["WWW-Authenticate"] = "Basic realm=\"\(realm)\", charset=\"UTF-8\""
                return response
            case .lockedOut(let retryAfter):
                var response = HTTPResponse.text(429, "Too many failed sign-in attempts. Try again later.")
                response.headers["Retry-After"] = String(Int(retryAfter.rounded(.up)))
                return response
            }
        }

        let context = Context(request: request, user: user, rootIsSlash: isRoot)
        let node = try resolve(Array(segments.dropFirst()), context: context, isRoot: isRoot)
        switch request.method {
        case "PROPFIND": return try propfind(node, context)
        case "PROPPATCH": return try proppatch(node, context)
        case "GET", "HEAD": return try get(node, context)
        case "PUT": return try put(node, context)
        case "DELETE": return try delete(node, context)
        case "MKCALENDAR": return try mkcol(node, context, defaultKind: .calendar)
        case "MKCOL": return try mkcol(node, context, defaultKind: nil)
        case "REPORT": return try report(node, context)
        case "MOVE": return try move(node, context)
        case "COPY", "LOCK", "UNLOCK", "ACL", "POST":
            throw DAVError.status(405, "\(request.method) is not supported")
        default:
            throw DAVError.status(501, "\(request.method) is not implemented")
        }
    }

    /// Every method the server answers, in the order the Allow header lists them. COPY is
    /// recognized (and refused cleanly) but not advertised.
    public static let methods = ["OPTIONS", "GET", "HEAD", "PUT", "DELETE", "PROPFIND", "PROPPATCH", "MKCOL", "MKCALENDAR", "REPORT", "MOVE"]
    /// Methods a request log can show: the served ones plus COPY.
    public static let loggedMethods = methods + ["COPY"]
    static let allowedMethods = methods.joined(separator: ", ")

    private func options() -> HTTPResponse {
        var response = HTTPResponse(status: 200)
        response.headers["DAV"] = "1, 3, access-control, calendar-access, addressbook, extended-mkcol, sync-collection"
        response.headers["Allow"] = Self.allowedMethods
        response.headers["Accept-Ranges"] = "none"
        return response
    }

    // MARK: Resolution

    struct Context {
        var request: HTTPRequest
        var user: User
        var rootIsSlash: Bool
        var depth: String { request.headers["Depth"]?.lowercased() ?? "infinity" }
    }

    indirect enum Node {
        case root
        case principals
        case principal(User)
        case homesRoot(CollectionKind)
        case home(User, CollectionKind)
        case collection(User, DAVCollection)
        /// A member of a collection; the resource is nil when it does not exist yet.
        case object(User, DAVCollection, String, DAVResource?)
        /// A path inside a home that names no existing collection (MKCOL/MKCALENDAR target).
        case missingCollection(User, CollectionKind, String)
    }

    private func resolve(_ segments: [String], context: Context, isRoot: Bool) throws -> Node {
        if isRoot || segments.isEmpty { return .root }
        let user = context.user
        func ownUser(_ name: String) throws -> User {
            guard name.lowercased() == user.username else { throw DAVError.status(403, "Access to another account is not allowed") }
            return user
        }
        switch segments[0] {
        case "principals":
            if segments.count == 1 { return .principals }
            guard segments.count == 2 else { throw DAVError.status(404, "Not found") }
            return .principal(try ownUser(segments[1]))
        case "calendars", "addressbooks":
            let kind: CollectionKind = segments[0] == "calendars" ? .calendar : .addressBook
            if segments.count == 1 { return .homesRoot(kind) }
            let owner = try ownUser(segments[1])
            if segments.count == 2 { return .home(owner, kind) }
            guard let collection = try store.collection(ownerID: owner.id, kind: kind, uri: segments[2]) else {
                if segments.count == 3 { return .missingCollection(owner, kind, segments[2]) }
                throw DAVError.status(context.request.method == "PUT" ? 409 : 404, "The collection does not exist")
            }
            if segments.count == 3 { return .collection(owner, collection) }
            guard segments.count == 4 else { throw DAVError.status(404, "Not found") }
            return .object(owner, collection, segments[3], try store.resource(collectionID: collection.id, uri: segments[3]))
        default:
            throw DAVError.status(404, "Not found")
        }
    }

    // MARK: Paths

    static func principalPath(_ user: User) -> String { URLPath.build(["dav", "principals", user.username], collection: true) }

    static func homePath(_ user: User, _ kind: CollectionKind) -> String {
        URLPath.build(["dav", kind == .calendar ? "calendars" : "addressbooks", user.username], collection: true)
    }

    static func collectionPath(_ user: User, _ collection: DAVCollection) -> String {
        URLPath.build(["dav", collection.kind == .calendar ? "calendars" : "addressbooks", user.username, collection.uri],
                      collection: true)
    }

    static func objectPath(_ user: User, _ collection: DAVCollection, _ name: String) -> String {
        collectionPath(user, collection) + URLPath.encode(name)
    }

    private func path(of node: Node, _ context: Context) -> String {
        switch node {
        case .root: return context.rootIsSlash ? "/" : "/dav/"
        case .principals: return "/dav/principals/"
        case .principal(let user): return Self.principalPath(user)
        case .homesRoot(let kind): return kind == .calendar ? "/dav/calendars/" : "/dav/addressbooks/"
        case .home(let user, let kind): return Self.homePath(user, kind)
        case .collection(let user, let collection): return Self.collectionPath(user, collection)
        case .object(let user, let collection, let name, _): return Self.objectPath(user, collection, name)
        case .missingCollection(let user, let kind, let uri): return Self.homePath(user, kind) + URLPath.encode(uri) + "/"
        }
    }

    /// Resolves an href from a request body (relative or absolute URL) to a node.
    private func resolveHref(_ href: String, _ context: Context) -> Node? {
        var probe = HTTPRequest(method: "REPORT", target: href.trimmingCharacters(in: .whitespacesAndNewlines))
        probe.headers = context.request.headers
        guard let segments = URLPath.segments(probe.path), segments.first == "dav" else { return nil }
        return try? resolve(Array(segments.dropFirst()), context: context, isRoot: false)
    }

    // MARK: Properties

    enum PropRequest {
        case all(include: [QName])
        case names
        case props([XMLElementNode])
    }

    private func parsePropRequest(_ element: XMLElementNode?) -> PropRequest {
        guard let element else { return .all(include: []) }
        if let prop = element.child(NS.dav, "prop") { return .props(prop.children) }
        if element.child(NS.dav, "propname") != nil { return .names }
        let include = element.child(NS.dav, "include")?.children.map(\.qname) ?? []
        return .all(include: include)
    }

    /// The property names each node reports for allprop and propname.
    private func propertyNames(_ node: Node) -> [QName] {
        let dav = { QName(NS.dav, $0) }
        var names = [dav("resourcetype"), dav("displayname"), dav("current-user-principal"), dav("current-user-privilege-set"),
                     dav("supported-report-set"), dav("owner")]
        switch node {
        case .principal:
            names += [dav("principal-URL"), dav("principal-collection-set"), QName(NS.caldav, "calendar-home-set"),
                      QName(NS.carddav, "addressbook-home-set"), QName(NS.caldav, "calendar-user-address-set"),
                      QName(NS.caldav, "calendar-user-type"), dav("group-membership"), dav("alternate-URI-set")]
        case .collection(_, let collection):
            names += [dav("sync-token"), QName(NS.calendarServer, "getctag")]
            if collection.kind == .calendar {
                names += [QName(NS.caldav, "calendar-description"), QName(NS.caldav, "supported-calendar-component-set"),
                          QName(NS.caldav, "supported-calendar-data"), QName(NS.caldav, "max-resource-size"),
                          QName(NS.apple, "calendar-color"), QName(NS.apple, "calendar-order")]
                if !collection.timezone.isEmpty { names.append(QName(NS.caldav, "calendar-timezone")) }
            } else {
                names += [QName(NS.carddav, "addressbook-description"), QName(NS.carddav, "supported-address-data"),
                          QName(NS.carddav, "max-resource-size")]
            }
            if let dead = try? store.deadProperties(collectionID: collection.id) {
                names += dead.map { QName($0.namespace, $0.name) }
            }
        case .object(_, _, _, .some):
            names += [dav("getetag"), dav("getcontenttype"), dav("getcontentlength"), dav("getlastmodified")]
        default:
            break
        }
        return names
    }

    private func hrefs(_ paths: [String]) -> String {
        paths.map { "<d:href>\(XMLEscape.text($0))</d:href>" }.joined()
    }

    private static let privilegeSetXML: String = {
        let names = ["read", "write", "write-properties", "write-content", "bind", "unbind", "unlock",
                     "read-acl", "read-current-user-privilege-set"]
        return names.map { "<d:privilege><d:\($0)/></d:privilege>" }.joined()
            + "<d:privilege><cal:read-free-busy/></d:privilege>"
    }()

    /// The value of one property as inner XML, or nil when the node does not have it.
    private func propertyValue(_ name: QName, node: Node, context: Context) -> String? {
        let user = context.user
        // Properties common to every node.
        switch (name.namespace, name.name) {
        case (NS.dav, "current-user-principal"): return hrefs([Self.principalPath(user)])
        case (NS.dav, "principal-collection-set"): return hrefs(["/dav/principals/"])
        case (NS.dav, "current-user-privilege-set"): return Self.privilegeSetXML
        default: break
        }

        switch node {
        case .root, .principals, .homesRoot:
            switch (name.namespace, name.name) {
            case (NS.dav, "resourcetype"): return "<d:collection/>"
            case (NS.dav, "displayname"): return "CalShare"
            case (NS.dav, "supported-report-set"): return reportSet(["expand-property"], dav: true)
            default: return nil
            }

        case .principal(let owner):
            switch (name.namespace, name.name) {
            case (NS.dav, "resourcetype"): return "<d:collection/><d:principal/>"
            case (NS.dav, "displayname"): return XMLEscape.text(owner.displayName.isEmpty ? owner.username : owner.displayName)
            case (NS.dav, "principal-URL"): return hrefs([Self.principalPath(owner)])
            case (NS.dav, "owner"): return hrefs([Self.principalPath(owner)])
            case (NS.caldav, "calendar-home-set"): return hrefs([Self.homePath(owner, .calendar)])
            case (NS.carddav, "addressbook-home-set"): return hrefs([Self.homePath(owner, .addressBook)])
            case (NS.caldav, "calendar-user-address-set"): return hrefs([Self.principalPath(owner)])
            case (NS.caldav, "calendar-user-type"): return "INDIVIDUAL"
            case (NS.dav, "group-membership"), (NS.dav, "group-member-set"), (NS.dav, "alternate-URI-set"),
                 (NS.calendarServer, "calendar-proxy-read-for"), (NS.calendarServer, "calendar-proxy-write-for"):
                return ""
            case (NS.dav, "supported-report-set"): return reportSet(["expand-property", "principal-property-search", "principal-search-property-set"], dav: true)
            default: return nil
            }

        case .home(let owner, _):
            switch (name.namespace, name.name) {
            case (NS.dav, "resourcetype"): return "<d:collection/>"
            case (NS.dav, "displayname"): return XMLEscape.text(owner.displayName.isEmpty ? owner.username : owner.displayName)
            case (NS.dav, "owner"): return hrefs([Self.principalPath(owner)])
            case (NS.dav, "supported-report-set"): return reportSet(["expand-property", "sync-collection"], dav: true)
            default: return nil
            }

        case .collection(let owner, let collection):
            let isCalendar = collection.kind == .calendar
            switch (name.namespace, name.name) {
            case (NS.dav, "resourcetype"): return isCalendar ? "<d:collection/><cal:calendar/>" : "<d:collection/><card:addressbook/>"
            case (NS.dav, "displayname"): return XMLEscape.text(collection.displayName)
            case (NS.dav, "owner"): return hrefs([Self.principalPath(owner)])
            case (NS.dav, "sync-token"): return XMLEscape.text(syncToken(collection))
            case (NS.calendarServer, "getctag"): return ctag(collection)
            case (NS.dav, "supported-report-set"):
                return isCalendar
                    ? reportSet(["sync-collection", "expand-property"], dav: true) + reportSet(["calendar-multiget", "calendar-query"], dav: false, ns: "cal")
                    : reportSet(["sync-collection", "expand-property"], dav: true) + reportSet(["addressbook-multiget", "addressbook-query"], dav: false, ns: "card")
            case (NS.caldav, "calendar-description") where isCalendar: return XMLEscape.text(collection.description)
            case (NS.carddav, "addressbook-description") where !isCalendar: return XMLEscape.text(collection.description)
            case (NS.caldav, "calendar-timezone") where isCalendar:
                return collection.timezone.isEmpty ? nil : XMLEscape.text(collection.timezone)
            case (NS.caldav, "supported-calendar-component-set") where isCalendar:
                return collection.components.map { "<cal:comp name=\"\(XMLEscape.text($0))\"/>" }.joined()
            case (NS.caldav, "supported-calendar-data") where isCalendar:
                return "<cal:calendar-data content-type=\"text/calendar\" version=\"2.0\"/>"
            case (NS.carddav, "supported-address-data") where !isCalendar:
                return "<card:address-data-type content-type=\"text/vcard\" version=\"3.0\"/><card:address-data-type content-type=\"text/vcard\" version=\"4.0\"/>"
            case (NS.caldav, "max-resource-size") where isCalendar, (NS.carddav, "max-resource-size") where !isCalendar:
                return String(maxResourceSize)
            case (NS.apple, "calendar-color") where isCalendar:
                return collection.color.isEmpty ? nil : XMLEscape.text(collection.color)
            case (NS.apple, "calendar-order") where isCalendar: return String(collection.order)
            default:
                return (try? store.deadProperties(collectionID: collection.id))?
                    .first { $0.namespace == name.namespace && $0.name == name.name }?.xml
            }

        case .object(_, let collection, _, let resource):
            guard let resource else { return nil }
            let isCalendar = collection.kind == .calendar
            switch (name.namespace, name.name) {
            case (NS.dav, "resourcetype"): return ""
            case (NS.dav, "getetag"): return XMLEscape.text(resource.etag)
            case (NS.dav, "getcontentlength"): return String(resource.size)
            case (NS.dav, "getlastmodified"): return HTTPDate.string(resource.modifiedAt)
            case (NS.dav, "getcontenttype"):
                return isCalendar ? "text/calendar; charset=utf-8; component=\(resource.component.lowercased())" : "text/vcard; charset=utf-8"
            case (NS.dav, "owner"):
                if case .object(let owner, _, _, _) = node { return hrefs([Self.principalPath(owner)]) }
                return nil
            case (NS.caldav, "calendar-data") where isCalendar, (NS.carddav, "address-data") where !isCalendar:
                return XMLEscape.text(String(decoding: resource.data, as: UTF8.self))
            case (NS.dav, "supported-report-set"): return ""
            default: return nil
            }

        case .missingCollection:
            return nil
        }
    }

    private func reportSet(_ names: [String], dav: Bool, ns: String = "d") -> String {
        names.map { "<d:supported-report><d:report><\(dav ? "d" : ns):\($0)/></d:report></d:supported-report>" }.joined()
    }

    /// `<prefix><id>/<counter>`, or `<prefix><generation>/<id>/<counter>` once the database
    /// has been restored (see Store.syncEpoch).
    func syncToken(_ collection: DAVCollection) -> String {
        let epoch = store.syncEpoch
        return "\(Self.syncTokenPrefix)\(epoch.isEmpty ? "" : epoch + "/")\(collection.id)/\(collection.syncToken)"
    }

    /// The collection's ctag, which is also its ETag; it carries the token generation too.
    func ctag(_ collection: DAVCollection) -> String {
        let epoch = store.syncEpoch
        return "\"\(epoch.isEmpty ? "" : epoch + "-")\(collection.syncToken)\""
    }

    /// The counter in a sync token this database issued for `collection`, or nil if the
    /// token belongs to another collection or another generation.
    func tokenCounter(_ token: String, for collection: DAVCollection) -> Int64? {
        guard token.hasPrefix(Self.syncTokenPrefix) else { return nil }
        let parts = token.dropFirst(Self.syncTokenPrefix.count).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let epoch = store.syncEpoch
        let expected = epoch.isEmpty ? 2 : 3
        guard parts.count == expected, epoch.isEmpty || parts[0] == epoch,
              Int64(parts[expected - 2]) == collection.id else { return nil }
        return Int64(parts[expected - 1])
    }

    /// Writes one <d:response> for a node, grouping found and missing properties.
    private func writeResponse(_ writer: inout XMLWriter, node: Node, request: PropRequest, context: Context) {
        writer.open(QName(NS.dav, "response"))
        writer.href(path(of: node, context))
        var found: [(QName, String)] = []
        var missing: [QName] = []
        switch request {
        case .names:
            writer.open(QName(NS.dav, "propstat"))
            writer.open(QName(NS.dav, "prop"))
            for name in propertyNames(node) { writer.empty(name) }
            writer.close(QName(NS.dav, "prop"))
            writer.element(QName(NS.dav, "status"), text: "HTTP/1.1 200 OK")
            writer.close(QName(NS.dav, "propstat"))
            writer.close(QName(NS.dav, "response"))
            return
        case .all(let include):
            for name in propertyNames(node) + include {
                if let value = propertyValue(name, node: node, context: context) { found.append((name, value)) }
            }
        case .props(let elements):
            for element in elements {
                if let value = propertyValue(element.qname, node: node, context: context) {
                    found.append((element.qname, value))
                } else {
                    missing.append(element.qname)
                }
            }
        }
        for (statusLine, group) in [("HTTP/1.1 200 OK", found.map { ($0.0, Optional($0.1)) }),
                                    ("HTTP/1.1 404 Not Found", missing.map { ($0, String?.none) })] where !group.isEmpty {
            writer.open(QName(NS.dav, "propstat"))
            writer.open(QName(NS.dav, "prop"))
            for (name, value) in group {
                if let value, !value.isEmpty { writer.element(name, rawXML: value) } else { writer.empty(name) }
            }
            writer.close(QName(NS.dav, "prop"))
            writer.element(QName(NS.dav, "status"), text: statusLine)
            writer.close(QName(NS.dav, "propstat"))
        }
        writer.close(QName(NS.dav, "response"))
    }

    private func writeStatusResponse(_ writer: inout XMLWriter, href: String, status: Int) {
        writer.open(QName(NS.dav, "response"))
        writer.href(href)
        writer.element(QName(NS.dav, "status"), text: "HTTP/1.1 \(status) \(HTTPResponse.reason(status))")
        writer.close(QName(NS.dav, "response"))
    }

    private func multistatus(_ body: (inout XMLWriter) -> Void) -> HTTPResponse {
        var writer = XMLWriter()
        writer.openRoot(QName(NS.dav, "multistatus"))
        body(&writer)
        writer.close(QName(NS.dav, "multistatus"))
        return .xml(207, writer.output)
    }

    private func parseBody(_ request: HTTPRequest) throws -> XMLElementNode? {
        guard !request.body.isEmpty,
              !request.body.allSatisfy({ $0 == 32 || $0 == 10 || $0 == 13 || $0 == 9 }) else { return nil }
        do { return try XMLRequestParser.parse(request.body) } catch {
            throw DAVError.status(400, "The request body is not valid XML")
        }
    }

    // MARK: PROPFIND

    /// Whether answering `request` reads an item's contents, rather than only its metadata.
    private func needsContents(_ request: PropRequest) -> Bool {
        let contents = [QName(NS.caldav, "calendar-data"), QName(NS.carddav, "address-data")]
        switch request {
        case .names: return false
        case .all(let include): return include.contains { contents.contains($0) }
        case .props(let elements): return elements.contains { contents.contains($0.qname) }
        }
    }

    /// A collection's items, read without their contents unless `withContents`.
    private func members(of collection: DAVCollection, withContents: Bool) throws -> [DAVResource] {
        withContents ? try store.resources(collectionID: collection.id) : try store.resourcesWithoutData(collectionID: collection.id)
    }

    private func children(of node: Node, withContents: Bool) throws -> [Node] {
        switch node {
        case .root: return [.principals, .homesRoot(.calendar), .homesRoot(.addressBook)]
        case .principals: return []
        case .principal, .homesRoot, .object, .missingCollection: return []
        case .home(let user, let kind):
            var collections = try store.collections(ownerID: user.id, kind: kind)
            if kind == .addressBook && collections.isEmpty {
                // Self-heal: Contacts on iOS needs an address book to exist. Recreate the default.
                log("Account \(user.username) had no address book; recreating the default", level: .warning)
                collections = [try store.createCollection(ownerID: user.id, kind: .addressBook, uri: "contacts", displayName: "Contacts")]
            }
            return collections.map { .collection(user, $0) }
        case .collection(let user, let collection):
            return try members(of: collection, withContents: withContents).map { .object(user, collection, $0.uri, $0) }
        }
    }

    private func propfind(_ node: Node, _ context: Context) throws -> HTTPResponse {
        if case .missingCollection = node { throw DAVError.status(404, "Not found") }
        if case .object(_, _, _, nil) = node { throw DAVError.status(404, "Not found") }
        let body = try parseBody(context.request)
        if let body, body.qname != QName(NS.dav, "propfind") { throw DAVError.status(400, "Expected DAV:propfind") }
        let request = parsePropRequest(body)
        let depth = context.depth
        if depth != "0" && depth != "1" {
            // Depth: infinity is refused, as RFC 4918 §9.1 permits.
            return .xml(403, preconditionErrorBody(QName(NS.dav, "propfind-finite-depth")))
        }
        // A failure to list is an error, not an empty listing: a client could take an empty
        // collection as everything in it having been deleted.
        let members = depth == "1" ? try children(of: node, withContents: needsContents(request)) : []
        return multistatus { writer in
            writeResponse(&writer, node: node, request: request, context: context)
            for member in members { writeResponse(&writer, node: member, request: request, context: context) }
        }
    }

    // MARK: PROPPATCH

    private enum PropertyOperation { case set(XMLElementNode), remove(QName) }

    private func proppatch(_ node: Node, _ context: Context) throws -> HTTPResponse {
        guard let body = try parseBody(context.request), body.qname == QName(NS.dav, "propertyupdate") else {
            throw DAVError.status(400, "Expected DAV:propertyupdate")
        }
        var operations: [PropertyOperation] = []
        for instruction in body.children {
            let props = instruction.child(NS.dav, "prop")?.children ?? []
            if instruction.qname == QName(NS.dav, "set") { operations += props.map { .set($0) } }
            if instruction.qname == QName(NS.dav, "remove") { operations += props.map { .remove($0.qname) } }
        }
        var results: [(QName, Int)] = []
        switch node {
        case .collection(_, let collection):
            results = try applyProperties(operations, to: collection)
        case .principal, .home:
            // Clients store preferences such as default alarms on the home; they are accepted
            // but not persisted, which every client tolerates.
            results = operations.map { op in
                switch op { case .set(let element): (element.qname, 200); case .remove(let name): (name, 200) }
            }
        case .object(_, _, _, .some):
            results = operations.map { op in
                switch op { case .set(let element): (element.qname, 403); case .remove(let name): (name, 403) }
            }
        default:
            throw DAVError.status(404, "Not found")
        }
        return multistatus { writer in
            writer.open(QName(NS.dav, "response"))
            writer.href(path(of: node, context))
            for status in Set(results.map(\.1)).sorted() {
                writer.open(QName(NS.dav, "propstat"))
                writer.open(QName(NS.dav, "prop"))
                for (name, code) in results where code == status { writer.empty(name) }
                writer.close(QName(NS.dav, "prop"))
                writer.element(QName(NS.dav, "status"), text: "HTTP/1.1 \(status) \(HTTPResponse.reason(status))")
                writer.close(QName(NS.dav, "propstat"))
            }
            writer.close(QName(NS.dav, "response"))
        }
    }

    private static let protectedProperties: Set<QName> = [
        QName(NS.dav, "resourcetype"), QName(NS.dav, "getetag"), QName(NS.dav, "getcontentlength"),
        QName(NS.dav, "getcontenttype"), QName(NS.dav, "getlastmodified"), QName(NS.dav, "sync-token"),
        QName(NS.dav, "current-user-privilege-set"), QName(NS.dav, "owner"), QName(NS.dav, "supported-report-set"),
        QName(NS.calendarServer, "getctag"), QName(NS.caldav, "supported-calendar-data"),
        QName(NS.caldav, "max-resource-size"), QName(NS.carddav, "supported-address-data"),
        QName(NS.carddav, "max-resource-size"), QName(NS.caldav, "supported-calendar-component-set"),
    ]

    /// Applies set/remove operations atomically (RFC 4918 §9.2): if any fails, none apply.
    private func applyProperties(_ operations: [PropertyOperation], to collection: DAVCollection,
                                 allowComponentSet: Bool = false) throws -> [(QName, Int)] {
        var update = Store.CollectionUpdate()
        var dead: [(QName, String?)] = []
        var results: [(QName, Int)] = []
        let isCalendar = collection.kind == .calendar
        for operation in operations {
            let name: QName
            let element: XMLElementNode?
            switch operation {
            case .set(let node): name = node.qname; element = node
            case .remove(let qname): name = qname; element = nil
            }
            if name == QName(NS.caldav, "supported-calendar-component-set"), allowComponentSet, isCalendar, let element {
                let components = element.children(NS.caldav, "comp").compactMap { $0.attributes["name"]?.uppercased() }
                    .filter { ICalendar.objectComponents.contains($0) }
                if components.isEmpty { results.append((name, 403)) } else { update.components = components; results.append((name, 200)) }
                continue
            }
            if Self.protectedProperties.contains(name) { results.append((name, 403)); continue }
            let text = element?.trimmedText ?? ""
            switch (name.namespace, name.name) {
            case (NS.dav, "displayname"): update.displayName = text
            case (NS.caldav, "calendar-description") where isCalendar: update.description = text
            case (NS.carddav, "addressbook-description") where !isCalendar: update.description = text
            case (NS.caldav, "calendar-timezone") where isCalendar: update.timezone = element?.text ?? ""
            case (NS.apple, "calendar-color") where isCalendar: update.color = text
            case (NS.apple, "calendar-order") where isCalendar: update.order = Int(text) ?? 0
            default: dead.append((name, element.map(\.innerXML)))
            }
            results.append((name, 200))
        }
        if results.contains(where: { $0.1 != 200 }) {
            return results.map { ($0.0, $0.1 == 200 ? 424 : $0.1) }
        }
        try store.transaction {
            try store.updateCollection(collection.id, update)
            for (name, xml) in dead {
                try store.setDeadProperty(collectionID: collection.id, namespace: name.namespace, name: name.name, xml: xml)
            }
        }
        return results
    }

    // MARK: MKCOL / MKCALENDAR

    private func mkcol(_ node: Node, _ context: Context, defaultKind: CollectionKind?) throws -> HTTPResponse {
        let user: User, homeKind: CollectionKind, uri: String
        switch node {
        case .missingCollection(let owner, let kind, let name): user = owner; homeKind = kind; uri = name
        case .collection, .home, .root, .principal, .principals, .homesRoot:
            throw DAVError.status(405, "A resource already exists at this location")
        case .object:
            throw DAVError.status(403, "Collections can only be created in a calendar or address book home")
        }
        let body = try parseBody(context.request)
        let setProps = body?.child(NS.dav, "set")?.child(NS.dav, "prop")?.children ?? []
        var kind = defaultKind
        if let resourceType = setProps.first(where: { $0.qname == QName(NS.dav, "resourcetype") }) {
            if resourceType.child(NS.caldav, "calendar") != nil { kind = .calendar }
            else if resourceType.child(NS.carddav, "addressbook") != nil { kind = .addressBook }
            else { throw DAVError.precondition(403, QName(NS.dav, "valid-resourcetype"), "Only calendars and address books can be created") }
        }
        guard let kind else {
            throw DAVError.precondition(403, QName(NS.dav, "valid-resourcetype"), "Plain collections are not supported")
        }
        guard kind == homeKind else {
            throw DAVError.status(403, kind == .calendar ? "Calendars belong in the calendar home" : "Address books belong in the address book home")
        }
        // Created and given its properties in one transaction, so a failure at any point
        // leaves no half-made collection behind.
        struct Refused: Error { let results: [(QName, Int)] }
        let operations = setProps.filter { $0.qname != QName(NS.dav, "resourcetype") }.map { PropertyOperation.set($0) }
        do {
            try store.transaction {
                let collection = try store.createCollection(ownerID: user.id, kind: kind, uri: uri, displayName: uri,
                                                            components: kind == .calendar ? ["VEVENT", "VTODO"] : [])
                let results = try applyProperties(operations, to: collection, allowComponentSet: true)
                if results.contains(where: { $0.1 != 200 }) { throw Refused(results: results) }
            }
        } catch let refused as Refused {
            let results = refused.results
            return multistatus { writer in
                writer.open(QName(NS.dav, "response"))
                writer.href(path(of: node, context))
                writer.open(QName(NS.dav, "propstat"))
                writer.open(QName(NS.dav, "prop"))
                for (name, _) in results { writer.empty(name) }
                writer.close(QName(NS.dav, "prop"))
                writer.element(QName(NS.dav, "status"), text: "HTTP/1.1 403 Forbidden")
                writer.close(QName(NS.dav, "propstat"))
                writer.close(QName(NS.dav, "response"))
            }
        }
        log("\(user.username) created \(kind.rawValue) \(uri)")
        var response = HTTPResponse(status: 201)
        response.headers["Cache-Control"] = "no-cache"
        return response
    }

    // MARK: GET / HEAD

    private func get(_ node: Node, _ context: Context) throws -> HTTPResponse {
        switch node {
        case .object(_, let collection, _, let resource?):
            if let ifNoneMatch = context.request.headers["If-None-Match"], Self.etags(ifNoneMatch).contains(resource.etag) {
                var response = HTTPResponse(status: 304)
                response.headers["ETag"] = resource.etag
                return response
            }
            var response = HTTPResponse(status: 200, body: resource.data)
            response.headers["Content-Type"] = collection.kind == .calendar ? "text/calendar; charset=utf-8" : "text/vcard; charset=utf-8"
            response.headers["ETag"] = resource.etag
            response.headers["Last-Modified"] = HTTPDate.string(resource.modifiedAt)
            return response
        case .collection(_, let collection):
            // A whole-collection GET exports it, which also lets other apps subscribe read-only.
            let resources = try store.resources(collectionID: collection.id)
            let body = collection.kind == .calendar
                ? ICalendar.merge(resources.map(\.data), name: collection.displayName)
                : VCard.merge(resources.map(\.data))
            var response = HTTPResponse(status: 200, contentType: collection.kind == .calendar ? "text/calendar; charset=utf-8" : "text/vcard; charset=utf-8", body: body)
            response.headers["ETag"] = ctag(collection)
            return response
        case .root, .principals, .principal, .homesRoot, .home:
            return .text(200, "This is a CalDAV/CardDAV collection. Use a calendar or contacts application to access it.")
        default:
            throw DAVError.status(404, "Not found")
        }
    }

    static func etags(_ header: String) -> Set<String> {
        Set(header.split(separator: ",").map { tag in
            var value = tag.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("W/") { value.removeFirst(2) }
            return value
        })
    }

    // MARK: PUT

    private func put(_ node: Node, _ context: Context) throws -> HTTPResponse {
        guard case .object(_, let collection, let name, let existing) = node else {
            if case .missingCollection = node { throw DAVError.status(409, "PUT needs an existing calendar or address book") }
            throw DAVError.status(405, "Cannot PUT to a collection")
        }
        let request = context.request
        let data = request.body
        if data.count > maxResourceSize {
            throw DAVError.precondition(403, QName(collection.kind == .calendar ? NS.caldav : NS.carddav, "max-resource-size"),
                                        "The resource is larger than \(maxResourceSize / 1_048_576) MB")
        }
        var precondition = Store.Precondition.none
        if let ifNoneMatch = request.headers["If-None-Match"] {
            if ifNoneMatch.trimmingCharacters(in: .whitespaces) == "*" { precondition = .mustNotExist }
            else if let existing, Self.etags(ifNoneMatch).contains(existing.etag) { throw DAVError.status(412, "Precondition failed") }
        }
        if let ifMatch = request.headers["If-Match"] { precondition = .ifMatch(Self.etags(ifMatch)) }

        let input: Store.ResourceInput
        switch collection.kind {
        case .calendar:
            let info: CalendarObjectInfo
            do { info = try ICalendar.validate(data) } catch {
                throw DAVError.precondition(403, QName(NS.caldav, "valid-calendar-data"), error.description)
            }
            guard collection.components.contains(info.component) else {
                throw DAVError.precondition(403, QName(NS.caldav, "supported-calendar-component"),
                                            "This calendar does not accept \(info.component) components")
            }
            input = Store.ResourceInput(data: data, component: info.component, uid: info.uid,
                                        firstOccurrence: info.firstOccurrence, lastOccurrence: info.lastOccurrence)
        case .addressBook:
            let info: ContactInfo
            do { info = try VCard.validate(data, fallbackUID: name) } catch {
                throw DAVError.precondition(403, QName(NS.carddav, "valid-address-data"), error.description)
            }
            input = Store.ResourceInput(data: data, component: "VCARD", uid: info.uid)
        }

        let result: Store.PutResult
        do {
            result = try store.putResource(collectionID: collection.id, uri: name, input: input, precondition: precondition)
        } catch StoreError.uidConflict(let existingURI) {
            let ns = collection.kind == .calendar ? "cal" : "card"
            var writer = XMLWriter()
            writer.openRoot(QName(NS.dav, "error"))
            writer.raw("<\(ns):no-uid-conflict><d:href>\(XMLEscape.text(path(of: .collection(context.user, collection), context) + URLPath.encode(existingURI)))</d:href></\(ns):no-uid-conflict>")
            writer.close(QName(NS.dav, "error"))
            return .xml(409, writer.output)
        }
        var response: HTTPResponse
        switch result {
        case .created(let etag):
            response = HTTPResponse(status: 201)
            response.headers["ETag"] = etag
        case .updated(let etag):
            response = HTTPResponse(status: 204)
            response.headers["ETag"] = etag
        case .preconditionFailed:
            throw DAVError.status(412, "Precondition failed")
        }
        return response
    }

    // MARK: DELETE

    private func delete(_ node: Node, _ context: Context) throws -> HTTPResponse {
        let ifMatch = context.request.headers["If-Match"].map(Self.etags)
        switch node {
        case .object(_, let collection, let name, _):
            switch try store.deleteResource(collectionID: collection.id, uri: name, ifMatch: ifMatch) {
            case .deleted: return .empty(204)
            case .notFound: throw DAVError.status(404, "Not found")
            case .preconditionFailed: throw DAVError.status(412, "Precondition failed")
            }
        case .collection(let user, let collection):
            if let ifMatch, !ifMatch.contains("*"), !ifMatch.contains(ctag(collection)) {
                throw DAVError.status(412, "Precondition failed")
            }
            do {
                try store.deleteCollectionKeepingRequired(collection.id)
            } catch StoreError.lastCollection {
                throw DAVError.status(403, StoreError.lastCollection.description)
            }
            log("\(user.username) deleted \(collection.kind.rawValue) \(collection.uri)")
            return .empty(204)
        case .missingCollection:
            throw DAVError.status(404, "Not found")
        default:
            throw DAVError.status(403, "This resource cannot be deleted")
        }
    }

    // MARK: MOVE

    private func move(_ node: Node, _ context: Context) throws -> HTTPResponse {
        guard case .object(_, let source, let name, let resource?) = node else {
            if case .object(_, _, _, nil) = node { throw DAVError.status(404, "Not found") }
            throw DAVError.status(403, "Only calendar objects and contacts can be moved")
        }
        guard let destination = context.request.headers["Destination"], let target = resolveHref(destination, context),
              case .object(_, let targetCollection, let targetName, let existing) = target else {
            throw DAVError.status(400, "Bad or unsupported Destination")
        }
        guard targetCollection.kind == source.kind else { throw DAVError.status(403, "Cannot move between calendars and address books") }
        // RFC 4918 §9.9.4: source and destination may not be the same resource.
        if targetCollection.id == source.id && targetName == name { throw DAVError.status(403, "Source and destination are the same") }
        let overwrite = (context.request.headers["Overwrite"] ?? "T").uppercased() != "F"
        if existing != nil && !overwrite { throw DAVError.status(412, "Destination exists") }
        if source.kind == .calendar, !targetCollection.components.contains(resource.component) {
            throw DAVError.precondition(403, QName(NS.caldav, "supported-calendar-component"), "The destination does not accept this component")
        }
        do {
            switch try store.moveResource(from: source.id, uri: name, to: targetCollection.id, newURI: targetName, overwrite: overwrite) {
            case .some(true): return .empty(201)
            case .some(false): return .empty(204)
            case nil: throw DAVError.status(404, "Not found")
            }
        } catch StoreError.uidConflict {
            throw DAVError.precondition(409, QName(source.kind == .calendar ? NS.caldav : NS.carddav, "no-uid-conflict"), "UID already exists in the destination")
        }
    }

    // MARK: REPORT

    private func report(_ node: Node, _ context: Context) throws -> HTTPResponse {
        guard let body = try parseBody(context.request) else { throw DAVError.status(400, "REPORT needs a body") }
        switch (body.qname.namespace, body.qname.name) {
        case (NS.caldav, "calendar-multiget"), (NS.carddav, "addressbook-multiget"):
            return try multiget(node, body, context)
        case (NS.caldav, "calendar-query"):
            return try calendarQuery(node, body, context)
        case (NS.carddav, "addressbook-query"):
            return try addressBookQuery(node, body, context)
        case (NS.dav, "sync-collection"):
            return try syncCollection(node, body, context)
        case (NS.dav, "expand-property"):
            return try expandProperty(node, body, context)
        case (NS.dav, "principal-property-search"):
            return multistatus { _ in }
        case (NS.dav, "principal-search-property-set"):
            var writer = XMLWriter()
            writer.openRoot(QName(NS.dav, "principal-search-property-set"))
            writer.raw("<d:principal-search-property><d:prop><d:displayname/></d:prop><d:description xml:lang=\"en\">Display name</d:description></d:principal-search-property>")
            writer.close(QName(NS.dav, "principal-search-property-set"))
            return .xml(200, writer.output)
        default:
            throw DAVError.precondition(403, QName(NS.dav, "supported-report"), "Unsupported report \(body.qname)")
        }
    }

    private func multiget(_ node: Node, _ body: XMLElementNode, _ context: Context) throws -> HTTPResponse {
        let request = parsePropRequest(body)
        let hrefs = body.children(NS.dav, "href").map(\.trimmedText)
        return multistatus { writer in
            for href in hrefs {
                if let target = resolveHref(href, context), case .object(_, _, _, .some) = target {
                    writeResponse(&writer, node: target, request: request, context: context)
                } else {
                    writeStatusResponse(&writer, href: href, status: 404)
                }
            }
        }
    }

    // calendar-query (RFC 4791 §7.8)

    struct TextMatch {
        var text: String
        var negate: Bool
        var matchType: VCard.MatchType
    }

    struct ParamFilter {
        var name: String
        var isNotDefined: Bool
        var textMatch: TextMatch?
    }

    struct PropFilter {
        var name: String
        var isNotDefined: Bool
        var textMatches: [TextMatch]
        var paramFilters: [ParamFilter]
        var timeRange: (Date?, Date?)?
        var testAll: Bool
    }

    struct CompFilter {
        var name: String
        var isNotDefined: Bool
        var timeRange: (Date?, Date?)?
        var propFilters: [PropFilter]
        var compFilters: [CompFilter]
    }

    private func parseTextMatch(_ element: XMLElementNode?) -> TextMatch? {
        guard let element else { return nil }
        let negate = (element.attributes["negate-condition"] ?? "no").lowercased() == "yes"
        let matchType = VCard.MatchType(rawValue: element.attributes["match-type"] ?? "contains") ?? .contains
        return TextMatch(text: element.text, negate: negate, matchType: matchType)
    }

    private func parseTimeRange(_ element: XMLElementNode?) -> (Date?, Date?)? {
        guard let element else { return nil }
        return (element.attributes["start"].flatMap(TimeZoneResolver.utcDate),
                element.attributes["end"].flatMap(TimeZoneResolver.utcDate))
    }

    private func parsePropFilter(_ element: XMLElementNode, ns: String) -> PropFilter {
        PropFilter(
            name: (element.attributes["name"] ?? "").uppercased(),
            isNotDefined: element.child(ns, "is-not-defined") != nil,
            textMatches: element.children(ns, "text-match").compactMap(parseTextMatch),
            paramFilters: element.children(ns, "param-filter").map { param in
                ParamFilter(name: (param.attributes["name"] ?? "").uppercased(),
                            isNotDefined: param.child(ns, "is-not-defined") != nil,
                            textMatch: parseTextMatch(param.child(ns, "text-match")))
            },
            timeRange: parseTimeRange(element.child(ns, "time-range")),
            testAll: (element.attributes["test"] ?? "anyof").lowercased() == "allof")
    }

    private func parseCompFilter(_ element: XMLElementNode) -> CompFilter {
        CompFilter(
            name: (element.attributes["name"] ?? "").uppercased(),
            isNotDefined: element.child(NS.caldav, "is-not-defined") != nil,
            timeRange: parseTimeRange(element.child(NS.caldav, "time-range")),
            propFilters: element.children(NS.caldav, "prop-filter").map { parsePropFilter($0, ns: NS.caldav) },
            compFilters: element.children(NS.caldav, "comp-filter").map(parseCompFilter))
    }

    private func textMatches(_ value: String, _ match: TextMatch) -> Bool {
        let result = VCard.textMatches(ContentLineParser.unescapeText(value), match.text, match.matchType)
        return match.negate ? !result : result
    }

    private func propertyMatches(_ properties: [ContentProperty], _ filter: PropFilter) -> Bool {
        if filter.isNotDefined { return properties.isEmpty }
        guard !properties.isEmpty else { return false }
        if filter.textMatches.isEmpty && filter.paramFilters.isEmpty { return true }
        return properties.contains { property in
            var tests: [Bool] = filter.textMatches.map { textMatches(property.value, $0) }
            tests += filter.paramFilters.map { param in
                let values = property.parameters[param.name] ?? []
                if param.isNotDefined { return values.isEmpty }
                guard !values.isEmpty else { return false }
                guard let match = param.textMatch else { return true }
                return values.contains { textMatches($0, match) }
            }
            return filter.testAll ? tests.allSatisfy { $0 } : tests.contains(true)
        }
    }

    private func componentMatches(_ component: ContentComponent, _ filter: CompFilter) -> Bool {
        // Time ranges on the object component are answered by the index; nested ones (VALARM)
        // are accepted, which errs toward returning the resource.
        for propFilter in filter.propFilters {
            var allOf = propFilter
            allOf.testAll = true
            guard propertyMatches(component.properties(propFilter.name), allOf) else { return false }
        }
        for child in filter.compFilters {
            let candidates = component.children.filter { $0.name == child.name }
            if child.isNotDefined { if !candidates.isEmpty { return false }; continue }
            guard candidates.contains(where: { componentMatches($0, child) }) else { return false }
        }
        return true
    }

    private func calendarQuery(_ node: Node, _ body: XMLElementNode, _ context: Context) throws -> HTTPResponse {
        let request = parsePropRequest(body)
        guard let filterElement = body.child(NS.caldav, "filter"),
              let rootElement = filterElement.child(NS.caldav, "comp-filter") else {
            throw DAVError.precondition(403, QName(NS.caldav, "valid-filter"), "calendar-query needs a filter")
        }
        let root = parseCompFilter(rootElement)
        guard root.name == "VCALENDAR" else { return multistatus { _ in } }
        let objectFilter = root.compFilters.count == 1 ? root.compFilters.first : nil

        let candidates: [(User, DAVCollection, DAVResource)]
        switch node {
        case .collection(let user, let collection) where collection.kind == .calendar:
            let component = objectFilter.flatMap { $0.isNotDefined ? nil : $0.name }
            let range = objectFilter?.timeRange
            candidates = try store.resources(collectionID: collection.id, component: component,
                                             overlapping: range?.0, range?.1).map { (user, collection, $0) }
        case .object(let user, let collection, _, let resource?):
            candidates = [(user, collection, resource)]
        default:
            throw DAVError.status(403, "calendar-query must target a calendar")
        }
        return multistatus { writer in
            for (user, collection, resource) in candidates {
                // Every object-level time range, checked against the indexed span: the store
                // query applies one only when it is the sole filter, and a single object
                // isn't queried at all.
                guard root.compFilters.allSatisfy({ filter in
                    filter.isNotDefined || !ICalendar.objectComponents.contains(filter.name) || filter.timeRange.map { Self.overlaps(resource, $0.0, $0.1) } ?? true
                }) else { continue }
                let calendar: ContentComponent
                do {
                    guard let text = String(data: resource.data, encoding: .utf8) else { throw UnreadableResource.notUTF8 }
                    calendar = try ICalendar.parseCalendar(text)
                } catch {
                    reportUnreadable(collection, resource, error)
                    writeResponse(&writer, node: .object(user, collection, resource.uri, resource), request: request, context: context)
                    continue
                }
                guard componentMatches(calendar, root) else { continue }
                writeResponse(&writer, node: .object(user, collection, resource.uri, resource), request: request, context: context)
            }
        }
    }

    /// Whether a resource's indexed span overlaps [start, end); the same test as
    /// `Store.resources(collectionID:component:overlapping:_:)`.
    static func overlaps(_ resource: DAVResource, _ start: Date?, _ end: Date?) -> Bool {
        if let end, let first = resource.firstOccurrence, first >= end { return false }
        if let start, let last = resource.lastOccurrence {
            let instantAtOrAfterStart = resource.firstOccurrence.map { last == $0 && $0 >= start } ?? false
            if !(last > start || instantAtOrAfterStart) { return false }
        }
        return true
    }

    private func addressBookQuery(_ node: Node, _ body: XMLElementNode, _ context: Context) throws -> HTTPResponse {
        let request = parsePropRequest(body)
        let filterElement = body.child(NS.carddav, "filter")
        let testAll = (filterElement?.attributes["test"] ?? "anyof").lowercased() == "allof"
        let filters = filterElement?.children(NS.carddav, "prop-filter").map { parsePropFilter($0, ns: NS.carddav) } ?? []
        // A negative count would trap in prefix(_:); it is read as zero.
        let limit = body.child(NS.carddav, "limit")?.child(NS.carddav, "nresults").flatMap { Int($0.trimmedText) }.map { max(0, $0) }
        let candidates: [(User, DAVCollection, DAVResource)]
        switch node {
        case .collection(let user, let collection) where collection.kind == .addressBook:
            candidates = try store.resources(collectionID: collection.id).map { (user, collection, $0) }
        case .object(let user, let collection, _, let resource?):
            candidates = [(user, collection, resource)]
        default:
            throw DAVError.status(403, "addressbook-query must target an address book")
        }
        var matched: [(User, DAVCollection, DAVResource)] = []
        for candidate in candidates {
            if filters.isEmpty { matched.append(candidate); continue }
            let card: ContentComponent
            do { card = try VCard.parseCard(candidate.2.data) } catch {
                reportUnreadable(candidate.1, candidate.2, error)
                matched.append(candidate)
                continue
            }
            let results = filters.map { propertyMatches(card.properties($0.name), $0) }
            if testAll ? results.allSatisfy({ $0 }) : results.contains(true) { matched.append(candidate) }
        }
        let truncated = limit.map { matched.count > $0 } ?? false
        if let limit { matched = Array(matched.prefix(limit)) }
        return multistatus { writer in
            for (user, collection, resource) in matched {
                writeResponse(&writer, node: .object(user, collection, resource.uri, resource), request: request, context: context)
            }
            if truncated {
                writer.open(QName(NS.dav, "response"))
                writer.href(path(of: node, context))
                writer.element(QName(NS.dav, "status"), text: "HTTP/1.1 507 Insufficient Storage")
                writer.raw("<d:error><d:number-of-matches-within-limits/></d:error>")
                writer.close(QName(NS.dav, "response"))
            }
        }
    }

    // sync-collection (RFC 6578)

    private func syncCollection(_ node: Node, _ body: XMLElementNode, _ context: Context) throws -> HTTPResponse {
        guard case .collection(let user, let collection) = node else {
            throw DAVError.precondition(403, QName(NS.dav, "supported-report"), "sync-collection must target a calendar or address book")
        }
        if let level = body.child(NS.dav, "sync-level")?.trimmedText, level != "1" {
            throw DAVError.precondition(403, QName(NS.dav, "supported-report"), "Only sync-level 1 is supported")
        }
        let request = parsePropRequest(body)
        let tokenText = body.child(NS.dav, "sync-token")?.trimmedText ?? ""
        var changed: [String]
        var deleted: [String] = []
        let newToken: Int64
        var resources: [String: DAVResource] = [:]
        if tokenText.isEmpty {
            let all = try members(of: collection, withContents: needsContents(request))
            changed = all.map(\.uri)
            resources = Dictionary(all.map { ($0.uri, $0) }, uniquingKeysWith: { a, _ in a })
            newToken = collection.syncToken
        } else {
            guard let since = tokenCounter(tokenText, for: collection),
                  let changes = try store.changes(collectionID: collection.id, since: since) else {
                throw DAVError.precondition(403, QName(NS.dav, "valid-sync-token"), nil)
            }
            changed = changes.changed
            deleted = changes.deleted
            newToken = changes.newToken
            // Only what changed is read: an incremental sync of one edited event shouldn't
            // load every event and contact photo in the collection.
            for uri in Set(changed + deleted) {
                if let resource = try store.resource(collectionID: collection.id, uri: uri) { resources[uri] = resource }
            }
        }
        var updatedCollection = collection
        updatedCollection.syncToken = newToken
        return multistatus { writer in
            for uri in changed {
                if let resource = resources[uri] {
                    writeResponse(&writer, node: .object(user, collection, uri, resource), request: request, context: context)
                } else {
                    writeStatusResponse(&writer, href: Self.objectPath(user, collection, uri), status: 404)
                }
            }
            for uri in deleted where resources[uri] == nil {
                writeStatusResponse(&writer, href: Self.objectPath(user, collection, uri), status: 404)
            }
            writer.element(QName(NS.dav, "sync-token"), text: syncToken(updatedCollection))
        }
    }

    // expand-property (RFC 3253 §3.8), as Apple's clients use it on principals: the
    // requested properties are returned, and href-valued ones are expanded one level.
    private func expandProperty(_ node: Node, _ body: XMLElementNode, _ context: Context) throws -> HTTPResponse {
        let requested = body.children(NS.dav, "property")
        return multistatus { writer in
            writer.open(QName(NS.dav, "response"))
            writer.href(path(of: node, context))
            var found: [(QName, String)] = []
            var missing: [QName] = []
            for property in requested {
                let name = QName(property.attributes["namespace"] ?? NS.dav, property.attributes["name"] ?? "")
                // Written back as an element name, so it must be one.
                guard name.hasWritableName else { continue }
                guard let value = propertyValue(name, node: node, context: context) else { missing.append(name); continue }
                let nested = property.children(NS.dav, "property")
                if nested.isEmpty {
                    found.append((name, value))
                    continue
                }
                // Expand each href into a nested response carrying the nested properties.
                let hrefs = (try? XMLRequestParser.parse(Data("<r xmlns:d=\"DAV:\">\(value)</r>".utf8)))?.children(NS.dav, "href").map(\.trimmedText) ?? []
                var inner = XMLWriter()
                for href in hrefs {
                    guard let target = resolveHref(href, context) else { continue }
                    let props = nested.map { QName($0.attributes["namespace"] ?? NS.dav, $0.attributes["name"] ?? "") }
                        .filter(\.hasWritableName)
                    let fakeProps = props.map { qname -> XMLElementNode in XMLElementNode(qname: qname) }
                    writeResponse(&inner, node: target, request: .props(fakeProps), context: context)
                }
                found.append((name, inner.output.replacingOccurrences(of: "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n", with: "")))
            }
            if !found.isEmpty {
                writer.open(QName(NS.dav, "propstat"))
                writer.open(QName(NS.dav, "prop"))
                for (name, value) in found { if value.isEmpty { writer.empty(name) } else { writer.element(name, rawXML: value) } }
                writer.close(QName(NS.dav, "prop"))
                writer.element(QName(NS.dav, "status"), text: "HTTP/1.1 200 OK")
                writer.close(QName(NS.dav, "propstat"))
            }
            if !missing.isEmpty {
                writer.open(QName(NS.dav, "propstat"))
                writer.open(QName(NS.dav, "prop"))
                for name in missing { writer.empty(name) }
                writer.close(QName(NS.dav, "prop"))
                writer.element(QName(NS.dav, "status"), text: "HTTP/1.1 404 Not Found")
                writer.close(QName(NS.dav, "propstat"))
            }
            writer.close(QName(NS.dav, "response"))
        }
    }
}

enum UnreadableResource: Error, CustomStringConvertible {
    case notUTF8
    var description: String { "it isn't valid UTF-8 text" }
}

extension DAVHandler {
    fileprivate func reportUnreadable(_ collection: DAVCollection, _ resource: DAVResource, _ error: any Error) {
        let key = "\(collection.id)/\(resource.uri)/\(resource.etag)"
        guard reportedUnreadable.withLock({ $0.insert(key).inserted }) else { return }
        let name = collection.displayName.isEmpty ? collection.uri : collection.displayName
        let message = "An item in “\(name)” (\(resource.uri)) couldn't be read, so searches return it unfiltered: \(error)"
        log(message, level: .warning)
        onUnreadableResource.current?(message)
    }
}

// MARK: - Errors

enum DAVError: Error {
    case status(Int, String)
    case precondition(Int, QName, String?)

    var response: HTTPResponse {
        switch self {
        case .status(let code, let message): return .text(code, message)
        case .precondition(let code, let condition, let description):
            return .xml(code, preconditionErrorBody(condition, description: description))
        }
    }
}
