// MARK: - HTTPServer.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// An HTTP/1.1 server on Network.framework: optional TLS (1.3 only) from an in-memory
// identity, persistent connections, request pipelining in order, idle timeouts, and a cap on
// concurrent connections. Each connection runs on its own serial queue.

import Foundation
import Network
import Security

public final class HTTPServer: @unchecked Sendable, Loggable {
    public static let logTag = "[HTTP]"

    public enum State: Sendable, Equatable {
        case stopped
        case starting
        case ready(port: UInt16)
        case failed(String, addressInUse: Bool)
    }

    public let name: String
    public let requestedPort: UInt16
    public let identity: SecIdentity?
    public var limits = HTTPLimits()
    public var idleTimeout: TimeInterval = 120
    public var maxConnections = 128
    /// Connections one address may hold at once, so a single client can't take every slot.
    /// Apple's clients open a handful each.
    public var maxConnectionsPerAddress = 24

    private let handler: @Sendable (HTTPRequest) -> HTTPResponse
    private let queue: DispatchQueue
    private var listener: NWListener?
    private let connections = Locked<[ObjectIdentifier: ConnectionHandler]>([:])
    public let state = Locked<State>(.stopped)
    public let onStateChange = Locked<(@Sendable (State) -> Void)?>(nil)
    /// Reports a response that was cut off before all of it went out. A client that gets a
    /// cut-off body over a cleanly closed connection may take it as complete, so this is
    /// the only place the loss shows.
    public let onSendFailure = Locked<(@Sendable (String) -> Void)?>(nil)

    /// Certificates sent after the server's own: the authority that signed it.
    private let chainCertificates: [SecCertificate]

    public init(name: String, port: UInt16, identity: SecIdentity?, chain: [SecCertificate] = [],
                handler: @escaping @Sendable (HTTPRequest) -> HTTPResponse) {
        self.name = name
        self.requestedPort = port
        self.identity = identity
        self.chainCertificates = chain
        self.handler = handler
        self.queue = DispatchQueue(label: "CalShare.HTTPServer.\(name)")
    }

    public var isSecure: Bool { identity != nil }

    public var connectionCount: Int { connections.withLock { $0.count } }

    private func setState(_ new: State) {
        state.withLock { $0 = new }
        onStateChange.current?(new)
    }

    public func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            setState(.starting)
            // Network.framework's endpoint reuse also sets SO_REUSEPORT, which would let a
            // second process share the port silently. An exclusive test bind first catches that.
            if requestedPort != 0, !PortFinder.isFree(requestedPort) {
                log("\(name): port \(requestedPort) is already in use", level: .error)
                setState(.failed("Port \(requestedPort) is already in use by another application.", addressInUse: true))
                return
            }
            let parameters: NWParameters
            if let identity {
                let tls = NWProtocolTLS.Options()
                let options = tls.securityProtocolOptions
                // TLS 1.3 only: every device CalShare serves supports it, and it leaves out
                // 1.2's older cipher suites and renegotiation altogether.
                sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
                sec_protocol_options_set_max_tls_protocol_version(options, .TLSv13)
                // The authority goes out with the server certificate, so a client can build
                // the whole chain from the handshake alone and needs only to trust the root.
                let chain = chainCertificates.isEmpty ? nil : sec_identity_create_with_certificates(identity, chainCertificates as CFArray)
                if let secIdentity = chain ?? sec_identity_create(identity) {
                    sec_protocol_options_set_local_identity(options, secIdentity)
                }
                // The one Security call here that takes a C string; the literal is bridged
                // for the length of the call.
                unsafe sec_protocol_options_add_tls_application_protocol(options, "http/1.1")
                parameters = NWParameters(tls: tls, tcp: Self.tcpOptions())
            } else {
                parameters = NWParameters(tls: nil, tcp: Self.tcpOptions())
            }
            parameters.allowLocalEndpointReuse = true
            parameters.includePeerToPeer = false
            do {
                let port = requestedPort == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: requestedPort) ?? .any
                let listener = try NWListener(using: parameters, on: port)
                // newConnectionLimit counts down with every connection ever accepted and never
                // comes back up, so a cap there silently stops the server for good once that
                // many have come and gone. The concurrent cap is enforced in accept() instead.
                listener.newConnectionLimit = NWListener.InfiniteConnectionLimit
                listener.stateUpdateHandler = { [weak self] state in self?.listenerStateChanged(state) }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                self.listener = listener
                listener.start(queue: queue)
            } catch {
                log("\(name): could not create listener on \(requestedPort): \(error)", level: .error)
                setState(.failed(error.localizedDescription, addressInUse: Self.isAddressInUse(error)))
            }
        }
    }

    private static func tcpOptions() -> NWProtocolTCP.Options {
        let tcp = NWProtocolTCP.Options()
        // No TCP keepalive: an idle connection is closed by the idle timer anyway, and
        // a probe to a sleeping iPhone or iPad wakes its Wi-Fi radio just to answer it.
        tcp.enableKeepalive = false
        tcp.noDelay = true
        return tcp
    }

    static func isAddressInUse(_ error: any Error) -> Bool {
        if let nwError = error as? NWError, case .posix(let code) = nwError { return code == .EADDRINUSE }
        return false
    }

    private func listenerStateChanged(_ newState: NWListener.State) {
        switch newState {
        case .ready:
            let port = listener?.port?.rawValue ?? requestedPort
            log("\(name) listening on port \(port)\(isSecure ? " (TLS)" : "")")
            setState(.ready(port: port))
        case .failed(let error):
            log("\(name) listener failed: \(error)", level: .error)
            listener?.cancel()
            listener = nil
            setState(.failed(error.localizedDescription, addressInUse: Self.isAddressInUse(error)))
        case .waiting(let error):
            log("\(name) listener waiting: \(error)", level: .warning)
            if Self.isAddressInUse(error) {
                listener?.cancel()
                listener = nil
                setState(.failed(error.localizedDescription, addressInUse: true))
            }
        case .cancelled:
            break
        default:
            break
        }
    }

    public func stop() {
        // The listener lets go of its port only once it has finished cancelling, a moment
        // after cancel(). A restart on the same port (Restart, a new certificate, a failed
        // self-probe) that started before then found the port taken by "another application",
        // showed an error, and waited out a retry; so this waits for it, briefly.
        let released = DispatchSemaphore(value: 0)
        let cancelling = queue.sync { () -> Bool in
            guard let listener else { return false }
            listener.stateUpdateHandler = { [weak self] state in
                if case .cancelled = state { released.signal() } else { self?.listenerStateChanged(state) }
            }
            listener.cancel()
            self.listener = nil
            return true
        }
        if cancelling { _ = released.wait(timeout: .now() + 2) }
        let open = connections.withLock { current -> [ConnectionHandler] in
            let values = Array(current.values)
            current.removeAll()
            return values
        }
        for connection in open { connection.close() }
        setState(.stopped)
    }

    private func accept(_ connection: NWConnection) {
        if connectionCount >= maxConnections {
            log("\(name): \(maxConnections) connections open; refusing another", level: .warning)
            connection.cancel()
            return
        }
        let address = ConnectionHandler.address(of: connection.endpoint)
        let handlerObject = ConnectionHandler(connection: connection, server: self, handler: handler,
                                              limits: limits, idleTimeout: idleTimeout, isSecure: isSecure)
        let id = ObjectIdentifier(handlerObject)
        let admitted = connections.withLock { open -> Bool in
            guard open.values.lazy.filter({ $0.remoteAddress == address }).count < maxConnectionsPerAddress else { return false }
            open[id] = handlerObject
            return true
        }
        guard admitted else {
            log("\(name): \(address) already has \(maxConnectionsPerAddress) connections open; refusing another", level: .warning)
            connection.cancel()
            return
        }
        handlerObject.onClose = { [weak self] in _ = self?.connections.withLock { $0.removeValue(forKey: id) } }
        handlerObject.start()
    }
}

/// One client connection: receive → parse → handle → send, strictly in order.
final class ConnectionHandler: @unchecked Sendable, Loggable {
    static let logTag = "[HTTP]"

    private let connection: NWConnection
    private let handler: @Sendable (HTTPRequest) -> HTTPResponse
    private var parser: HTTPRequestParser
    private let queue = DispatchQueue(label: "CalShare.Connection")
    private let idleTimeout: TimeInterval
    private var idleTimer: DispatchWorkItem?
    private var closed = false
    /// Set when the server closes the connection on purpose (stopping or restarting), so a
    /// response cut short by that isn't reported as a fault.
    private var closingDeliberately = false
    /// What's still to be written, in order: response pieces, and a close after a response
    /// that ends the connection. Only one piece is with the connection at a time.
    private enum Outgoing { case start(ResponseInfo), data(Data), close }
    private var outgoing: [Outgoing] = []
    private var sending = false
    /// The response now going out, for reporting one that's cut off.
    private struct ResponseInfo { var summary: String; var size: Int; var sent = 0 }
    private var current: ResponseInfo?
    /// The size of each piece a response is written in. A large response handed over whole
    /// stalled partway on real networks until the idle timer closed the connection, and the
    /// client took the cut-off body as complete; written piece by piece, every piece that
    /// goes out counts as activity.
    static let sendChunkSize = 64 * 1024
    let remoteAddress: String
    var onClose: (@Sendable () -> Void)?
    weak var server: HTTPServer?

    init(connection: NWConnection, server: HTTPServer, handler: @escaping @Sendable (HTTPRequest) -> HTTPResponse,
         limits: HTTPLimits, idleTimeout: TimeInterval, isSecure: Bool) {
        self.connection = connection
        self.server = server
        self.handler = handler
        self.idleTimeout = idleTimeout
        self.remoteAddress = Self.address(of: connection.endpoint)
        self.parser = HTTPRequestParser(limits: limits, remoteAddress: remoteAddress, isSecure: isSecure)
    }

    static func address(of endpoint: NWEndpoint) -> String {
        if case .hostPort(let host, _) = endpoint {
            var text = "\(host)"
            if let percent = text.firstIndex(of: "%") { text = String(text[text.startIndex..<percent]) }
            if text.hasPrefix("::ffff:") { text.removeFirst(7) }
            return text
        }
        return "\(endpoint)"
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.resetIdleTimer()
                self.receive()
            case .waiting:
                // An accepted connection never recovers from waiting; holding it only
                // takes a slot.
                self.connection.cancel()
            case .failed(let error):
                // Reported here: once finished, the connection is let go, and its pending
                // send's completion finds nothing to report to.
                if self.current != nil { self.reportCutOff(because: "the connection failed (\(error))") }
                self.finish()
            case .cancelled:
                if self.current != nil { self.reportCutOff(because: "the connection closed") }
                self.finish()
            default: break
            }
        }
        // A client that never finishes the TLS handshake (one that rejected the
        // certificate but left the socket open, say) is dropped quickly. Armed before the
        // connection starts, while nothing else can touch the timer: once started, its state
        // handler resets the timer on `queue`.
        resetIdleTimer(after: Self.handshakeTimeout)
        connection.start(queue: queue)
    }

    static let handshakeTimeout: TimeInterval = 15

    func close() {
        queue.async { [self] in
            closingDeliberately = true
            connection.cancel()
            finish()
        }
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        idleTimer?.cancel()
        onClose?()
    }

    private func resetIdleTimer(after interval: TimeInterval? = nil) {
        idleTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.sending || self.current != nil { self.reportCutOff(because: "nothing went out for \(Int(self.idleTimeout)) s") }
            self.connection.cancel()
        }
        idleTimer = item
        queue.asyncAfter(deadline: .now() + (interval ?? idleTimeout), execute: item)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.resetIdleTimer()
                self.parser.feed(data)
                if !self.drain() { return }
            }
            if error != nil {
                self.connection.cancel()
                return
            }
            if isComplete {
                // The client is done sending, not necessarily done reading: whatever is
                // still going out finishes first, then the connection closes.
                self.outgoing.append(.close)
                self.sendNext()
                return
            }
            self.receive()
        }
    }

    /// Processes every complete request in the buffer. Returns false once the connection
    /// is being closed.
    private func drain() -> Bool {
        while let event = parser.next() {
            switch event {
            case .needsContinue:
                enqueue(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), summary: nil, thenClose: false)
            case .error(let status):
                let response = HTTPResponse.text(status, HTTPResponse.reason(status))
                enqueue(response.serialized(keepAlive: false), summary: nil, thenClose: true)
                return false
            case .request(let request):
                let response = handler(request)
                let keepAlive = request.keepAlive && response.status != 400
                let client = request.headers["User-Agent"].map { ", \($0)" } ?? ""
                enqueue(response.serialized(keepAlive: keepAlive),
                        summary: "\(request.method) \(request.path) (\(remoteAddress)\(client))", thenClose: !keepAlive)
                if !keepAlive { return false }
            }
        }
        return true
    }

    /// Queues a response in pieces, and a close after it if it ends the connection.
    private func enqueue(_ data: Data, summary: String?, thenClose: Bool) {
        if let summary { outgoing.append(.start(ResponseInfo(summary: summary, size: data.count))) }
        var start = data.startIndex
        while start < data.endIndex {
            let end = data.index(start, offsetBy: Self.sendChunkSize, limitedBy: data.endIndex) ?? data.endIndex
            outgoing.append(.data(data[start..<end]))  // a slice: shares the response's storage
            start = end
        }
        if thenClose { outgoing.append(.close) }
        sendNext()
    }

    /// Hands the next piece to the connection once the last one is processed. Each processed
    /// piece resets the idle timer: a connection still sending isn't idle.
    private func sendNext() {
        guard !sending, !closed, !outgoing.isEmpty else { return }
        switch outgoing.removeFirst() {
        case .start(let info):
            current = info
            sendNext()
        case .close:
            outgoing.removeAll()
            connection.cancel()
        case .data(let piece):
            sending = true
            connection.send(content: piece, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.sending = false
                if let error {
                    self.reportCutOff(because: "\(error)")
                    self.outgoing.removeAll()
                    self.connection.cancel()
                    return
                }
                if var info = self.current {
                    info.sent += piece.count
                    self.current = info.sent >= info.size ? nil : info
                }
                self.resetIdleTimer()
                self.sendNext()
            })
        }
    }

    /// Logs a response that didn't all go out. One that's large or was cut off midway is a
    /// warning the server passes on; a small one is routine (a client that hung up right
    /// after asking, like the app's own health check) and stays in the debug log.
    private func reportCutOff(because reason: String) {
        guard let info = current else { log("Send failed: \(reason)", level: .debug); return }
        current = nil
        let sizes = ByteCountFormatter.string(fromByteCount: Int64(info.sent), countStyle: .file) + " of "
            + ByteCountFormatter.string(fromByteCount: Int64(info.size), countStyle: .file)
        let message = "A response to \(info.summary) was cut off after \(sizes): \(reason)"
        if !closingDeliberately && (info.size > Self.sendChunkSize || info.sent > 0) {
            log(message, level: .warning)
            server?.onSendFailure.current?(message)
        } else {
            log(message, level: .debug)
        }
    }
}
