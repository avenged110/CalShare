// MARK: - Verification.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// Verify Data: reads every calendar and address book the way a device does (the listing a
// first sync starts with, a sync from scratch, and every item's data in batches) through
// the same request handling the network uses, and checks that it all agrees with what's
// stored: the same items everywhere, every item readable, every ETag matching its data.
// Read-only; nothing is changed.

import Foundation

public struct VerificationReport: Sendable, Equatable {
    public struct CollectionResult: Sendable, Equatable, Identifiable {
        public var id: Int64
        public var account: String
        public var name: String
        public var kind: CollectionKind
        public var stored: Int
        public var listed: Int
        public var synced: Int
        public var fetched: Int
        /// Every problem found, in plain words; empty when the collection checks out.
        public var problems: [String]
        /// For calendars, the component types it holds; a reminders list holds only VTODO.
        public var components: [String] = []
        public var isClean: Bool { problems.isEmpty }
        public var isRemindersList: Bool { kind == .calendar && components == ["VTODO"] }
    }

    public var date: Date
    public var seconds: Double
    public var results: [CollectionResult]
    public var isClean: Bool { results.allSatisfy(\.isClean) }
    public var itemCount: Int { results.reduce(0) { $0 + $1.stored } }
    public var problemCount: Int { results.reduce(0) { $0 + $1.problems.count } }
}

enum Verifier {
    /// How many items one fetch asks for, as a device fetches in batches.
    static let batchSize = 250

    static func run(handler: DAVHandler, store: Store) throws -> VerificationReport {
        let started = Date()
        var results: [VerificationReport.CollectionResult] = []
        for user in try store.users() {
            for kind in [CollectionKind.calendar, .addressBook] {
                for collection in try store.collections(ownerID: user.id, kind: kind) {
                    results.append(try check(collection, of: user, handler: handler, store: store))
                }
            }
        }
        return VerificationReport(date: started, seconds: Date().timeIntervalSince(started), results: results)
    }

    private static func check(_ collection: DAVCollection, of user: User, handler: DAVHandler,
                              store: Store) throws -> VerificationReport.CollectionResult {
        let path = DAVHandler.collectionPath(user, collection)
        let isCalendar = collection.kind == .calendar
        var problems: [String] = []
        func request(_ method: String, _ body: String, label: String) -> [String: (etag: String, data: String?)]? {
            let request = HTTPRequest(method: method, target: path,
                                      headers: HTTPHeaders([("Depth", "1"), ("Content-Type", "application/xml; charset=utf-8"),
                                                            ("User-Agent", "CalShare Verify")]),
                                      body: Data(body.utf8), remoteAddress: "127.0.0.1", isSecure: true)
            let response = handler.handleInternally(request, as: user)
            guard response.status == 207 else { problems.append("The \(label) failed (HTTP \(response.status))."); return nil }
            switch MultistatusReader.read(response.body) {
            case .success(let items): return items
            case .failure(let message): problems.append("The \(label) couldn't be read as XML: \(message)."); return nil
            }
        }

        // What's stored, straight from the database.
        let stored = try store.resources(collectionID: collection.id)
        let storedURIs = Set(stored.map(\.uri))
        for resource in stored where Store.etag(for: resource.data) != resource.etag {
            problems.append("\(resource.uri): its ETag doesn't match its data, so devices may not notice its changes.")
        }

        // The listing a first sync starts with.
        let listing = request("PROPFIND", #"<d:propfind xmlns:d="DAV:"><d:prop><d:getetag/></d:prop></d:propfind>"#,
                              label: "listing") ?? [:]
        let listed = names(listing.keys, under: path)
        // A sync from scratch.
        let syncing = request("REPORT", """
            <d:sync-collection xmlns:d="DAV:"><d:sync-token/><d:sync-level>1</d:sync-level><d:prop><d:getetag/></d:prop></d:sync-collection>
            """, label: "sync") ?? [:]
        let synced = names(syncing.keys, under: path)
        // Every item's data, in batches.
        let dataElement = isCalendar ? "c:calendar-data" : "c:address-data"
        let namespace = isCalendar ? "urn:ietf:params:xml:ns:caldav" : "urn:ietf:params:xml:ns:carddav"
        let multiget = isCalendar ? "c:calendar-multiget" : "c:addressbook-multiget"
        var fetched: [String: (etag: String, data: String?)] = [:]
        let hrefs = listing.keys.filter { $0 != path }.sorted()
        for start in stride(from: 0, to: hrefs.count, by: batchSize) {
            let batch = hrefs[start..<min(start + batchSize, hrefs.count)]
            let body = """
                <\(multiget) xmlns:d="DAV:" xmlns:c="\(namespace)"><d:prop><d:getetag/><\(dataElement)/></d:prop>\
                \(batch.map { "<d:href>\(XMLEscape.text($0))</d:href>" }.joined())</\(multiget)>
                """
            guard let items = request("REPORT", body, label: "fetch of items \(start + 1)–\(start + batch.count)") else { break }
            fetched.merge(items) { a, _ in a }
        }

        // Devices may write while this runs. Only items unchanged from start to finish are
        // held to account; an item added, edited, moved, or deleted meanwhile is neither
        // missing nor extra, just in motion.
        let after = Dictionary(try store.resources(collectionID: collection.id).map { ($0.uri, $0.etag) }, uniquingKeysWith: { a, _ in a })
        let before = Dictionary(stored.map { ($0.uri, $0.etag) }, uniquingKeysWith: { a, _ in a })
        let stable = Set(before.keys.filter { after[$0] == before[$0] })
        // An item can come and go entirely between the two looks, so "returned but never
        // stored" holds only if nothing at all was written meanwhile.
        let quiet = try store.collection(id: collection.id)?.syncToken == collection.syncToken
        let known: Set<String>? = quiet ? storedURIs : nil
        let fetchedNames = names(fetched.keys, under: path)
        compare(listed, stable: stable, known: known, "listing", &problems)
        compare(synced, stable: stable, known: known, "sync", &problems)
        compare(fetchedNames, stable: stable, known: known, "fetch", &problems)

        let storedByURI = Dictionary(stored.map { ($0.uri, $0) }, uniquingKeysWith: { a, _ in a })
        for (href, item) in fetched.sorted(by: { $0.key < $1.key }) {
            let uri = String(href.dropFirst(path.count)).removingPercentEncoding ?? String(href.dropFirst(path.count))
            guard stable.contains(uri) else { continue }
            if let resource = storedByURI[uri], item.etag != resource.etag {
                problems.append("\(uri): devices are given a different ETag than the stored one.")
            }
            guard let text = item.data else {
                problems.append("\(uri): came back without its data.")
                continue
            }
            do {
                if isCalendar { _ = try ICalendar.parseCalendar(text) } else { _ = try VCard.parseCard(Data(text.utf8)) }
            } catch {
                problems.append("\(uri): can't be read: \(error)")
            }
        }

        return .init(id: collection.id, account: user.username,
                     name: collection.displayName.isEmpty ? collection.uri : collection.displayName,
                     kind: collection.kind, stored: stored.count, listed: listed.count, synced: synced.count,
                     fetched: fetchedNames.count, problems: problems, components: collection.components)
    }

    /// Item names (the last path segment, decoded) of the hrefs directly under `path`.
    private static func names(_ hrefs: some Sequence<String>, under path: String) -> Set<String> {
        Set(hrefs.filter { $0.hasPrefix(path) && $0 != path }.map {
            let name = String($0.dropFirst(path.count))
            return name.removingPercentEncoding ?? name
        })
    }

    /// Missing: stable items the read didn't return. Extra: items returned that weren't
    /// stored, checked only when `known` is given (nothing was written during the check).
    private static func compare(_ seen: Set<String>, stable: Set<String>, known: Set<String>?, _ label: String,
                                _ problems: inout [String]) {
        let missing = stable.subtracting(seen), extra = known.map { seen.subtracting($0) } ?? []
        if !missing.isEmpty {
            problems.append("The \(label) left out \(missing.count) of \(stable.count) items (e.g. \(missing.sorted().prefix(3).joined(separator: ", "))).")
        }
        if !extra.isEmpty {
            problems.append("The \(label) included \(extra.count) items that aren't stored (e.g. \(extra.sorted().prefix(3).joined(separator: ", "))).")
        }
    }
}

/// Reads a multistatus with Foundation's XMLParser, the parser Apple's clients use, so a
/// response they'd give up on fails here too.
enum MultistatusReader {
    enum Outcome { case success([String: (etag: String, data: String?)]), failure(String) }

    static func read(_ body: Data) -> Outcome {
        final class Collector: NSObject, XMLParserDelegate {
            var items: [String: (etag: String, data: String?)] = [:]
            var href = "", etag = "", data: String?, text = ""
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                        attributes: [String: String] = [:]) { text = "" }
            func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
            func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
                switch name {
                case "href" where href.isEmpty: href = text.trimmingCharacters(in: .whitespacesAndNewlines)
                case "getetag": etag = text
                case "calendar-data", "address-data": data = text
                case "response":
                    items[href] = (etag, data)
                    href = ""; etag = ""; data = nil
                default: break
                }
            }
        }
        let collector = Collector()
        let parser = XMLParser(data: body)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        // XMLParser holds its delegate unowned(unsafe); see XMLRequestParser.
        return withExtendedLifetime(collector) {
            unsafe parser.delegate = collector
            guard parser.parse() else { return .failure(parser.parserError?.localizedDescription ?? "unknown error") }
            return .success(collector.items)
        }
    }
}
