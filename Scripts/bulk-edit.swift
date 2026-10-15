#!/usr/bin/env swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// Bulk edits against a running CalShare, over the same CalDAV the devices use, so every
// change bumps sync tokens and reaches every device on its next sync.
//
//   swift Scripts/bulk-edit.swift <host> <account> [--move-to "<calendar name>"] [--apply]
//
// Without --apply it only reports. With --apply it:
//   • removes duplicate VTIMEZONE blocks (same TZID twice in one event), keeping the first;
//   • moves every event whose title matches "s## e##" into the named calendar.
// Each write is conditional on the event's ETag, so nothing edited meanwhile is overwritten.
// The password is read from CALSHARE_PASSWORD or asked for; it's never echoed or logged.
// The CalShare authority is fetched from the setup port (8080) and trusted for this run only.

import Foundation

// MARK: Arguments

var args = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> Bool { if let i = args.firstIndex(of: name) { args.remove(at: i); return true }; return false }
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let value = args[i + 1]; args.removeSubrange(i...(i + 1)); return value
}
let apply = flag("--apply")
let moveTarget = option("--move-to")
let httpsPort = option("--port") ?? "8443"
let setupPort = option("--setup-port") ?? "8080"
let saveDir = option("--save-dir")
guard args.count == 2 else {
    print("usage: swift Scripts/bulk-edit.swift <host> <account> [--move-to \"<calendar name>\"] [--apply] [--port 8443] [--setup-port 8080]")
    exit(2)
}
let host = args[0], account = args[1]
let password: String = ProcessInfo.processInfo.environment["CALSHARE_PASSWORD"]
    ?? String(cString: getpass("CalShare password for \(account): "))
let base = URL(string: "https://\(host):\(httpsPort)")!
let titlePattern = try! NSRegularExpression(pattern: #"\bs\d{2}\s?e\d{2}\b"#, options: [.caseInsensitive])

// MARK: HTTP

final class Trust: NSObject, URLSessionDelegate {
    let anchor: SecCertificate
    init(anchor: SecCertificate) { self.anchor = anchor }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { return completionHandler(.performDefaultHandling, nil) }
        SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        var error: CFError?
        completionHandler(SecTrustEvaluateWithError(trust, &error) ? .useCredential : .cancelAuthenticationChallenge,
                          URLCredential(trust: trust))
    }
}

func fetch(_ request: URLRequest, session: URLSession = .shared) -> (Int, Data) {
    let done = DispatchSemaphore(value: 0)
    var result: (Int, Data) = (0, Data())
    session.dataTask(with: request) { data, response, error in
        if let error { print("  request failed: \(error.localizedDescription)") }
        result = ((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data())
        done.signal()
    }.resume()
    done.wait()
    return result
}

guard let caURL = URL(string: "http://\(host):\(setupPort)/ca.cer"),
      case (200, let caData) = fetch(URLRequest(url: caURL)),
      let anchor = SecCertificateCreateWithData(nil, caData as CFData) else {
    print("Couldn't fetch the CalShare authority from http://\(host):\(setupPort)/ca.cer"); exit(1)
}
let session = URLSession(configuration: .ephemeral, delegate: Trust(anchor: anchor), delegateQueue: nil)
let authorization = "Basic " + Data("\(account):\(password)".utf8).base64EncodedString()

func dav(_ method: String, _ path: String, body: String? = nil, headers: [String: String] = [:]) -> (Int, Data) {
    var request = URLRequest(url: URL(string: path, relativeTo: base)!)
    request.httpMethod = method
    request.setValue(authorization, forHTTPHeaderField: "Authorization")
    if let body { request.httpBody = Data(body.utf8); request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type") }
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    request.timeoutInterval = 300
    return fetch(request, session: session)
}

// MARK: Multistatus parsing

struct Response { var href = ""; var props: [String: String] = [:]; var isCalendar = false }

final class MultistatusParser: NSObject, XMLParserDelegate {
    var responses: [Response] = []
    private var current: Response?
    private var text = ""
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "response" { current = Response() }
        if name == "calendar", namespaceURI == "urn:ietf:params:xml:ns:caldav" { current?.isCalendar = true }
        text = ""
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "response", let done = current { responses.append(done); current = nil; return }
        if name == "href", current?.href.isEmpty == true { current?.href = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        else if ["displayname", "getetag", "calendar-data"].contains(name) { current?.props[name] = text }
    }
    static func parse(_ data: Data) -> [Response] {
        let delegate = MultistatusParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        if !parser.parse() { print("  XML parse stopped: \(parser.parserError?.localizedDescription ?? "unknown error")") }
        return delegate.responses
    }
}

enum XMLText {
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

// MARK: iCalendar helpers

/// Unfolded "SUMMARY" of the first VEVENT, or nil.
func summary(of ics: String) -> String? {
    let unfolded = ics.replacingOccurrences(of: "\r\n ", with: "").replacingOccurrences(of: "\r\n\t", with: "")
        .replacingOccurrences(of: "\n ", with: "").replacingOccurrences(of: "\n\t", with: "")
    for line in unfolded.components(separatedBy: .newlines) where line.uppercased().hasPrefix("SUMMARY") {
        guard let colon = line.firstIndex(of: ":") else { continue }
        return String(line[line.index(after: colon)...])
    }
    return nil
}

/// The event with every VTIMEZONE after the first for the same TZID removed, and how many
/// were dropped. Everything else is left byte for byte.
func dedupeTimeZones(_ ics: String) -> (String, Int) {
    let newline = ics.contains("\r\n") ? "\r\n" : "\n"
    var lines = ics.components(separatedBy: newline)
    var seen = Set<String>(), removed = 0, i = 0
    while i < lines.count {
        guard lines[i].uppercased() == "BEGIN:VTIMEZONE",
              let end = lines[i...].firstIndex(where: { $0.uppercased() == "END:VTIMEZONE" }) else { i += 1; continue }
        let tzid = lines[i...end].first { $0.uppercased().hasPrefix("TZID:") }.map { String($0.dropFirst(5)) } ?? ""
        if seen.insert(tzid).inserted { i = end + 1 } else { lines.removeSubrange(i...end); removed += 1 }
    }
    return (lines.joined(separator: newline), removed)
}

// MARK: Discovery

let home = "/dav/calendars/\(account)/"
let (homeStatus, homeData) = dav("PROPFIND", home, body: """
    <d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:resourcetype/></d:prop></d:propfind>
    """, headers: ["Depth": "1"])
guard homeStatus == 207 else { print("Listing calendars failed (HTTP \(homeStatus)). Check the host, account and password."); exit(1) }
let calendars = MultistatusParser.parse(homeData).filter(\.isCalendar)
print("Calendars: " + calendars.map { "\($0.props["displayname"] ?? "?")" }.joined(separator: ", "))

var moveTargetHref: String?
if let moveTarget {
    moveTargetHref = calendars.first { $0.props["displayname"] == moveTarget }?.href
    if moveTargetHref == nil { print("No calendar named “\(moveTarget)”. Create it first (e.g. in Calendar on the Mac), then run again."); exit(1) }
}

// MARK: Plan

struct Fix { var href: String; var etag: String; var data: String; var removed: Int; var title: String }
struct Move { var href: String; var etag: String; var title: String; var from: String }
var fixes: [Fix] = [], moves: [Move] = []

for calendar in calendars {
    let name = calendar.props["displayname"] ?? calendar.href
    // Listed with PROPFIND, then fetched with calendar-multiget in batches: unlike
    // calendar-query, neither skips events the server's own parser can't read.
    let (listStatus, listData) = dav("PROPFIND", calendar.href, body: """
        <d:propfind xmlns:d="DAV:"><d:prop><d:getetag/></d:prop></d:propfind>
        """, headers: ["Depth": "1"])
    guard listStatus == 207 else { print("  \(name): listing failed (HTTP \(listStatus))"); continue }
    if let saveDir {
        // The listing exactly as received, to check against what the server says it sent.
        try? FileManager.default.createDirectory(atPath: saveDir, withIntermediateDirectories: true)
        try? listData.write(to: URL(fileURLWithPath: saveDir).appendingPathComponent("\(name)-listing.xml"))
    }
    print("  \(name): listing received, \(listData.count) bytes")
    let hrefs = MultistatusParser.parse(listData).map(\.href).filter { $0 != calendar.href && !$0.hasSuffix("/") }
    var events: [Response] = []
    for start in stride(from: 0, to: hrefs.count, by: 200) {
        let batch = hrefs[start..<min(start + 200, hrefs.count)]
        let (status, data) = dav("REPORT", calendar.href, body: """
            <c:calendar-multiget xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
            <d:prop><d:getetag/><c:calendar-data/></d:prop>
            \(batch.map { "<d:href>\(XMLText.escape($0))</d:href>" }.joined())
            </c:calendar-multiget>
            """, headers: ["Depth": "1"])
        guard status == 207 else { print("  \(name): fetching events failed (HTTP \(status))"); break }
        events += MultistatusParser.parse(data).filter { $0.props["calendar-data"] != nil }
    }
    if let saveDir {
        let folder = URL(fileURLWithPath: saveDir).appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for event in events {
            let file = event.href.split(separator: "/").last.map(String.init) ?? UUID().uuidString + ".ics"
            // The raw stored bytes, by GET: XML parsing would normalize line endings and
            // replace invalid bytes, hiding exactly what a parser might trip on.
            let (status, raw) = dav("GET", event.href)
            if status == 200 { try? raw.write(to: folder.appendingPathComponent(file)) }
        }
    }
    if events.count != hrefs.count { print("  \(name): listed \(hrefs.count) but read \(events.count)") }
    print("  \(name): \(events.count) items")
    for event in events {
        let ics = event.props["calendar-data"]!, etag = event.props["getetag"] ?? ""
        let title = summary(of: ics) ?? "(no title)"
        let (fixed, removed) = dedupeTimeZones(ics)
        // XML parsing turns CRLF into LF; iCalendar wants CRLF back.
        let crlf = fixed.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        if removed > 0 { fixes.append(Fix(href: event.href, etag: etag, data: crlf, removed: removed, title: title)) }
        if let moveTargetHref, calendar.href != moveTargetHref,
           titlePattern.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil {
            moves.append(Move(href: event.href, etag: etag, title: title, from: name))
        }
    }
}

// MARK: Report

let reportURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("calshare-bulk-edit-plan.txt")
var report = "Duplicate time zones (\(fixes.count) events):\n"
report += fixes.map { "  \($0.title)  [\($0.removed) removed]  \($0.href)" }.joined(separator: "\n")
report += "\n\nMoves to “\(moveTarget ?? "-")” (\(moves.count) events):\n"
report += moves.map { "  \($0.title)  (from \($0.from))  \($0.href)" }.joined(separator: "\n")
try? report.write(to: reportURL, atomically: true, encoding: .utf8)
print("\n\(fixes.count) events have duplicate time zones; \(moves.count) events match “s## e##”.")
print("Full list: \(reportURL.path)")
for move in moves.prefix(10) { print("  move: \(move.title)  (from \(move.from))") }

guard apply else { print("\nDry run only. Nothing was changed. Add --apply to make these changes."); exit(0) }

// MARK: Apply

var failures = 0
for fix in fixes {
    let (status, _) = dav("PUT", fix.href, body: fix.data, headers: ["If-Match": fix.etag, "Content-Type": "text/calendar; charset=utf-8"])
    if !(200..<300).contains(status) { failures += 1; print("  fix failed (HTTP \(status)): \(fix.title)") }
}
// Moves go after fixes, so an event that's both is moved with its fixed contents. The ETag
// changed with the fix, so moves don't send If-Match; MOVE never overwrites (Overwrite: F).
for move in moves {
    let destination = URL(string: moveTargetHref!, relativeTo: base)!.absoluteString + (move.href.split(separator: "/").last.map(String.init) ?? "")
    let (status, _) = dav("MOVE", move.href, headers: ["Destination": destination, "Overwrite": "F"])
    if !(200..<300).contains(status) { failures += 1; print("  move failed (HTTP \(status)): \(move.title)") }
}
print("\nDone: \(fixes.count) fixes and \(moves.count) moves attempted, \(failures) failed.")
