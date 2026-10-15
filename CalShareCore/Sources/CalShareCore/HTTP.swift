// MARK: - HTTP.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// HTTP/1.1 messages and an incremental request parser with hard limits on every
// dimension (header size, header count, body size), Content-Length and chunked bodies,
// and Expect: 100-continue.

import Foundation

public struct HTTPHeaders: Sendable, Sequence {
    private var fields: [(name: String, value: String)] = []

    public init(_ fields: [(String, String)] = []) {
        self.fields = fields.map { (name: $0.0, value: $0.1) }
    }

    public subscript(_ name: String) -> String? {
        get { fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value }
        set {
            fields.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            if let newValue { fields.append((name: name, value: newValue)) }
        }
    }

    public mutating func add(_ name: String, _ value: String) { fields.append((name: name, value: value)) }

    public func makeIterator() -> IndexingIterator<[(name: String, value: String)]> { fields.makeIterator() }
}

public struct HTTPRequest: Sendable {
    public var method: String
    public var target: String
    public var version: String
    public var headers: HTTPHeaders
    public var body: Data
    public var remoteAddress: String
    public var isSecure: Bool

    public init(method: String, target: String, version: String = "HTTP/1.1", headers: HTTPHeaders = HTTPHeaders(),
                body: Data = Data(), remoteAddress: String = "", isSecure: Bool = false) {
        self.method = method; self.target = target; self.version = version; self.headers = headers
        self.body = body; self.remoteAddress = remoteAddress; self.isSecure = isSecure
    }

    /// The path portion of the target, accepting absolute-form targets too.
    public var path: String {
        var value = target
        if let schemeRange = value.range(of: "://") {
            let afterScheme = value[schemeRange.upperBound...]
            value = afterScheme.firstIndex(of: "/").map { String(afterScheme[$0...]) } ?? "/"
        }
        if let query = value.firstIndex(of: "?") { value = String(value[value.startIndex..<query]) }
        return value.isEmpty ? "/" : value
    }

    public var keepAlive: Bool {
        let connection = headers["Connection"]?.lowercased() ?? ""
        if version == "HTTP/1.0" { return connection.contains("keep-alive") }
        return !connection.contains("close")
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: HTTPHeaders
    public var body: Data
    /// For HEAD: send the headers of a body without the body itself.
    public var omitBody = false

    public init(status: Int, headers: HTTPHeaders = HTTPHeaders(), body: Data = Data()) {
        self.status = status; self.headers = headers; self.body = body
    }

    public init(status: Int, contentType: String, body: String) {
        self.init(status: status, headers: HTTPHeaders([("Content-Type", contentType)]), body: Data(body.utf8))
    }

    public static func xml(_ status: Int, _ body: String) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "application/xml; charset=utf-8", body: body)
    }

    public static func text(_ status: Int, _ body: String) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/plain; charset=utf-8", body: body + "\n")
    }

    public static func empty(_ status: Int) -> HTTPResponse { HTTPResponse(status: status) }

    public static func reason(_ status: Int) -> String {
        switch status {
        case 100: "Continue"
        case 200: "OK"
        case 201: "Created"
        case 204: "No Content"
        case 207: "Multi-Status"
        case 301: "Moved Permanently"
        case 302: "Found"
        case 304: "Not Modified"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 409: "Conflict"
        case 411: "Length Required"
        case 412: "Precondition Failed"
        case 413: "Content Too Large"
        case 415: "Unsupported Media Type"
        case 424: "Failed Dependency"
        case 429: "Too Many Requests"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 503: "Service Unavailable"
        case 507: "Insufficient Storage"
        default: "Status"
        }
    }

    public func serialized(keepAlive: Bool) -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        var headers = self.headers
        headers["Content-Length"] = String(body.count)
        headers["Date"] = HTTPDate.string(Date())
        headers["Server"] = "CalShare"
        headers["Connection"] = keepAlive ? "keep-alive" : "close"
        for field in headers { head += "\(field.name): \(field.value)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        if !omitBody { data.append(body) }
        return data
    }
}

public struct HTTPLimits: Sendable {
    public var maxHeaderBytes = 64 * 1024
    public var maxHeaderCount = 100
    public var maxBodyBytes = 32 * 1024 * 1024
    public init() {}
}

/// Incremental parser: feed bytes as they arrive, take complete requests out.
public struct HTTPRequestParser {
    public enum Event {
        case request(HTTPRequest)
        case needsContinue          // send "100 Continue" and keep feeding
        case error(Int)             // send this status and close
    }

    private var buffer = Data()
    private var pending: (request: HTTPRequest, mode: BodyMode)?
    private var sentContinue = false
    private let limits: HTTPLimits
    private let remoteAddress: String
    private let isSecure: Bool
    /// Bytes at the front of `buffer` already searched for the end of the head, so a head
    /// that arrives a few bytes at a time is never searched from its start again.
    private var headScanned = 0

    private enum BodyMode { case length(Int), chunked }

    // Chunked bodies are decoded as they arrive and their bytes consumed, so each byte is
    // examined once however the body is split across reads.
    private enum ChunkPhase { case size, data(remaining: Int), dataEnd, trailers }
    private var chunkPhase = ChunkPhase.size
    private var chunkBody = Data()
    private var trailerBytes = 0
    /// Bytes of the line being read already searched for its CRLF (see `headScanned`).
    private var lineScanned = 0

    private static let crlf = Data([13, 10])
    private static let blankLine = Data([13, 10, 13, 10])

    public init(limits: HTTPLimits = HTTPLimits(), remoteAddress: String, isSecure: Bool) {
        self.limits = limits; self.remoteAddress = remoteAddress; self.isSecure = isSecure
    }

    public var hasBufferedData: Bool { !buffer.isEmpty || pending != nil }

    public mutating func feed(_ data: Data) { buffer.append(data) }

    /// Returns the next event, or nil if more bytes are needed.
    public mutating func next() -> Event? {
        // Nothing legitimate buffers more than one maximal request; a client that keeps
        // sending (an endless chunk-size line, say) is cut off rather than allowed to
        // grow this buffer without bound.
        if buffer.count > limits.maxBodyBytes + limits.maxHeaderBytes + 64 * 1024 { return .error(413) }
        if pending == nil {
            // Skip stray CRLFs between requests (RFC 9112 §2.2).
            while buffer.starts(with: [13, 10]) { buffer.removeFirst(2); headScanned = 0 }
            // The last three bytes searched may begin a blank line that is still arriving.
            let searchStart = buffer.startIndex + max(0, headScanned - 3)
            guard let headerEnd = buffer[searchStart...].firstRange(of: Self.blankLine) else {
                headScanned = buffer.count
                return buffer.count > limits.maxHeaderBytes ? .error(431) : nil
            }
            headScanned = 0
            guard buffer.distance(from: buffer.startIndex, to: headerEnd.lowerBound) <= limits.maxHeaderBytes else { return .error(431) }
            let headData = buffer[buffer.startIndex..<headerEnd.lowerBound]
            buffer = Data(buffer[headerEnd.upperBound...])
            guard let head = String(data: headData, encoding: .utf8) ?? String(data: headData, encoding: .isoLatin1) else {
                return .error(400)
            }
            var lines = head.components(separatedBy: "\r\n")
            let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
            guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return .error(400) }
            guard lines.count <= limits.maxHeaderCount else { return .error(431) }
            var headers = HTTPHeaders()
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { return .error(400) }
                let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !name.contains(" ") else { return .error(400) }
                headers.add(name, line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            }
            let request = HTTPRequest(method: String(requestLine[0]).uppercased(), target: String(requestLine[1]),
                                      version: String(requestLine[2]), headers: headers,
                                      remoteAddress: remoteAddress, isSecure: isSecure)
            let mode: BodyMode
            if let encoding = headers["Transfer-Encoding"]?.lowercased() {
                // Only chunked on its own: a body under another coding (gzip, chunked) would
                // otherwise be stored still compressed. RFC 9112 §6.1 answers it with 501.
                guard encoding.trimmingCharacters(in: .whitespaces) == "chunked" else { return .error(501) }
                guard headers["Content-Length"] == nil else { return .error(400) }
                mode = .chunked
            } else if let lengthText = headers["Content-Length"] {
                guard let length = Int(lengthText.trimmingCharacters(in: .whitespaces)), length >= 0 else { return .error(400) }
                guard length <= limits.maxBodyBytes else { return .error(413) }
                mode = .length(length)
            } else {
                mode = .length(0)
            }
            pending = (request, mode)
            sentContinue = false
            chunkPhase = .size
            chunkBody = Data()
            trailerBytes = 0
            lineScanned = 0
        }
        guard let current = pending else { return nil }
        var request = current.request
        let mode = current.mode
        switch mode {
        case .length(let length):
            if buffer.count < length {
                if !sentContinue, request.headers["Expect"]?.lowercased() == "100-continue" {
                    sentContinue = true
                    return .needsContinue
                }
                return nil
            }
            request.body = Data(buffer.prefix(length))
            buffer = Data(buffer.dropFirst(length))
        case .chunked:
            switch decodeChunked() {
            case .incomplete:
                if !sentContinue, request.headers["Expect"]?.lowercased() == "100-continue" {
                    sentContinue = true
                    return .needsContinue
                }
                return nil
            case .invalid: return .error(400)
            case .tooLarge: return .error(413)
            case .complete(let body):
                request.body = body
            }
        }
        pending = nil
        return .request(request)
    }

    private enum ChunkResult { case incomplete, invalid, tooLarge, complete(Data) }

    /// Decodes as much of a chunked body as the buffer holds and drops the bytes it used.
    private mutating func decodeChunked() -> ChunkResult {
        var index = buffer.startIndex
        // Consumed bytes go in one step, and only when there are any: a line still arriving
        // a byte at a time is neither copied nor searched again.
        defer { if index != buffer.startIndex { buffer = Data(buffer[index...]) } }
        while true {
            switch chunkPhase {
            case .size, .trailers:
                guard let lineEnd = lineEnd(from: index) else {
                    // A size line, or one trailer, longer than a whole head is not one.
                    return buffer.distance(from: index, to: buffer.endIndex) > limits.maxHeaderBytes ? .invalid : .incomplete
                }
                let line = buffer[index..<lineEnd]
                index = lineEnd + 2
                if case .trailers = chunkPhase {
                    // Trailers are skipped up to the blank line, within a head's budget.
                    if line.isEmpty {
                        let body = chunkBody
                        chunkBody = Data()
                        chunkPhase = .size
                        return .complete(body)
                    }
                    trailerBytes += line.count + 2
                    if trailerBytes > limits.maxHeaderBytes { return .tooLarge }
                    continue
                }
                let sizeLine = String(decoding: line, as: UTF8.self)
                let sizeText = sizeLine.split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
                guard let size = Int(sizeText, radix: 16), size >= 0 else { return .invalid }
                if size == 0 {
                    chunkPhase = .trailers
                    continue
                }
                // Compared without adding, so a size near Int.max can't overflow.
                guard size <= limits.maxBodyBytes - chunkBody.count else { return .tooLarge }
                chunkPhase = .data(remaining: size)
            case .data(let remaining):
                let available = buffer.distance(from: index, to: buffer.endIndex)
                guard available > 0 else { return .incomplete }
                let taken = min(remaining, available)
                chunkBody.append(buffer[index..<(index + taken)])
                index += taken
                chunkPhase = taken == remaining ? .dataEnd : .data(remaining: remaining - taken)
            case .dataEnd:
                guard buffer.distance(from: index, to: buffer.endIndex) >= 2 else { return .incomplete }
                guard buffer[index] == 13, buffer[index + 1] == 10 else { return .invalid }
                index += 2
                chunkPhase = .size
            }
        }
    }

    /// Where the CRLF ending the line that starts at `start` begins, or nil while the line
    /// is still arriving.
    private mutating func lineEnd(from start: Data.Index) -> Data.Index? {
        // The last byte searched may be a CR whose LF is still arriving.
        let searchStart = start + max(0, lineScanned - 1)
        guard let end = buffer[searchStart...].firstRange(of: Self.crlf) else {
            lineScanned = buffer.distance(from: start, to: buffer.endIndex)
            return nil
        }
        lineScanned = 0
        return end.lowerBound
    }
}
