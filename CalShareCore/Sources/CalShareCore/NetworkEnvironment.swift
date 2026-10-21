// MARK: - NetworkEnvironment.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// What the rest of the world can call this Mac: its Bonjour (.local) name and its current
// interface addresses, plus Bonjour advertisement of the CalDAV and CardDAV services so
// devices on the network can find the server by itself.

import dnssd
import Foundation
import Network
import SystemConfiguration

public struct NetworkSnapshot: Sendable, Equatable {
    /// "Johns-MacBook-Pro" (without .local).
    public var localHostName: String
    /// Human-readable computer name, "John's MacBook Pro".
    public var computerName: String
    public var addresses: [InterfaceAddress]

    public var bonjourHostName: String { localHostName.isEmpty ? "" : "\(localHostName).local" }

    /// Addresses that belong in the certificate and are worth showing: private LAN ranges,
    /// Tailscale's CGNAT range, and global addresses. Link-local IPv6 is excluded.
    public var usableAddresses: [InterfaceAddress] { addresses.filter { $0.isUsable } }

    /// Whether `address` belongs to this Mac (loopback or one of its interfaces).
    public func isLocal(_ address: String) -> Bool {
        address == "127.0.0.1" || address == "::1" || addresses.contains { $0.address == address }
    }

    /// The LAN address devices use, from the private ranges the certificate authority may
    /// vouch for: a public one can't be in the server certificate, so nothing could use it.
    public var primaryLANAddress: String? {
        usableAddresses.first { $0.family == .ipv4 && !$0.isTailscale && NameConstraints.permits(address: $0.address) }?.address
    }

    public var tailscaleAddress: String? { usableAddresses.first { $0.isTailscale && $0.family == .ipv4 }?.address }
}

public struct InterfaceAddress: Sendable, Equatable, Hashable {
    public enum Family: Sendable { case ipv4, ipv6 }
    public var interface: String
    public var address: String
    public var family: Family

    public var isTailscale: Bool {
        guard family == .ipv4 else { return address.lowercased().hasPrefix("fd7a:115c:a1e0") }
        let octets = address.split(separator: ".").compactMap { Int($0) }
        return octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1])
    }

    public var isUsable: Bool {
        switch family {
        case .ipv4: return !address.hasPrefix("127.") && !address.hasPrefix("169.254.")
        case .ipv6:
            let lower = address.lowercased()
            return !(lower == "::1" || lower.hasPrefix("fe80"))
        }
    }
}

public enum NetworkEnvironment {
    public static func snapshot() -> NetworkSnapshot {
        let local = (SCDynamicStoreCopyLocalHostName(nil) as String?) ?? ""
        let computer = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? ""
        return NetworkSnapshot(localHostName: local, computerName: computer, addresses: interfaceAddresses())
    }

    public static func interfaceAddresses() -> [InterfaceAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard unsafe getifaddrs(&head) == 0, let first = unsafe head else { return [] }
        defer { unsafe freeifaddrs(head) }
        var results: [InterfaceAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = unsafe first
        while let entry = unsafe cursor {
            defer { unsafe cursor = entry.pointee.ifa_next }
            let flags = Int32(unsafe entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let addr = unsafe entry.pointee.ifa_addr else { continue }
            let family = unsafe addr.pointee.sa_family
            guard family == sa_family_t(AF_INET) || family == sa_family_t(AF_INET6) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(family == sa_family_t(AF_INET) ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard unsafe getnameinfo(addr, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            var address = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if let percent = address.firstIndex(of: "%") { address = String(address[address.startIndex..<percent]) }
            let name = unsafe String(cString: entry.pointee.ifa_name)
            // Skip virtual interfaces that are never reachable from other devices.
            if name.hasPrefix("awdl") || name.hasPrefix("llw") || name.hasPrefix("anpi") || name.hasPrefix("ap") { continue }
            results.append(InterfaceAddress(interface: name, address: address,
                                            family: family == sa_family_t(AF_INET) ? .ipv4 : .ipv6))
        }
        // Stable order: IPv4 first, then by interface name, so certificate SANs don't churn.
        return results.sorted { lhs, rhs in
            if lhs.family != rhs.family { return lhs.family == .ipv4 }
            if lhs.interface != rhs.interface { return lhs.interface < rhs.interface }
            return lhs.address < rhs.address
        }
    }
}

/// Watches for network changes (new Wi-Fi, address changes, interface up/down) and reports
/// them, debounced, so certificates and advertisements can follow.
public final class NetworkWatcher: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "CalShare.NetworkWatcher")
    private var pending: DispatchWorkItem?
    private let onChange: @Sendable () -> Void

    public init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        monitor.pathUpdateHandler = { [weak self] _ in self?.schedule() }
    }

    public func start() { monitor.start(queue: queue) }
    public func stop() { monitor.cancel() }

    private func schedule() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = item
        queue.asyncAfter(deadline: .now() + 2, execute: item)
    }
}

/// Registers _caldavs._tcp and _carddavs._tcp (RFC 6764 §3) with a path TXT record.
///
/// The registrations deliver their replies on `queue`, and every registration and
/// deallocation happens on that queue too: once a reference is deallocated there, no reply
/// for it can still be running or arrive later. The C callback gets this object unretained,
/// which that guarantee (and `deinit`, which deallocates whatever is left) keeps valid.
@safe public final class BonjourAdvertiser: @unchecked Sendable, Loggable {
    public static let logTag = "[Bonjour]"

    /// Touched only on `queue`.
    private var references: [DNSServiceRef] = unsafe []
    private struct Advertisement: Equatable { var name: String; var port: UInt16; var path: String }
    /// What `references` advertises. Touched only on `queue`.
    private var current: Advertisement?
    private let queue = DispatchQueue(label: "CalShare.Bonjour")
    private let queueKey = DispatchSpecificKey<Void>()
    public let status = Locked<(registered: Int, error: String?)>((0, nil))
    public let onStatusChange = Locked<(@Sendable () -> Void)?>(nil)

    public init() {
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit {
        // The last reference can be dropped inside a reply, which already runs on `queue`.
        if DispatchQueue.getSpecific(key: queueKey) != nil { deallocateAll() } else { queue.sync { deallocateAll() } }
    }

    public func advertise(name: String, port: UInt16, path: String = "/dav/") {
        // Re-registering sends goodbye, probe, and announcement packets to every device on
        // the network, waking each one's Wi-Fi radio. mDNSResponder already follows
        // interface and address changes for a live registration, so an unchanged one stays.
        let wanted = Advertisement(name: name, port: port, path: path)
        let unchanged = queue.sync { current == wanted && !unsafe references.isEmpty }
        if unchanged, status.current.error == nil { return }
        stop()
        queue.sync { current = wanted }
        let txt = Self.txtRecord(["path": path])
        let failures: [String] = queue.sync {
            var failures: [String] = []
            for type in ["_caldavs._tcp", "_carddavs._tcp"] {
                var reference: DNSServiceRef?
                let context = unsafe Unmanaged.passUnretained(self).toOpaque()
                let result = unsafe txt.withUnsafeBytes { buffer in
                    unsafe DNSServiceRegister(&reference, 0, 0, name, type, nil, nil, port.bigEndian,
                                              UInt16(buffer.count), buffer.baseAddress, Self.callback, context)
                }
                if result == kDNSServiceErr_NoError, let reference = unsafe reference {
                    unsafe DNSServiceSetDispatchQueue(reference, queue)
                    unsafe references.append(reference)
                } else {
                    log("Could not register \(type): error \(result)", level: .error)
                    failures.append("Bonjour registration failed (error \(result)).")
                }
            }
            return failures
        }
        if let failure = failures.last {
            status.withLock { $0.error = failure }
            onStatusChange.current?()
        }
    }

    public func stop() {
        queue.sync { deallocateAll(); current = nil }
        status.withLock { $0 = (0, nil) }
    }

    /// Must run on `queue`.
    private func deallocateAll() {
        for unsafe reference in unsafe references { unsafe DNSServiceRefDeallocate(reference) }
        unsafe references.removeAll()
    }

    fileprivate func registered(_ errorCode: DNSServiceErrorType, name: String) {
        if errorCode == kDNSServiceErr_NoError {
            status.withLock { $0.registered += 1; $0.error = nil }
            log("Advertised \(name)")
        } else {
            status.withLock { $0.error = "Bonjour reported error \(errorCode)." }
            log("Registration error \(errorCode)", level: .warning)
        }
        onStatusChange.current?()
    }

    private static let callback: DNSServiceRegisterReply = { _, _, errorCode, name, type, _, context in
        guard let context = unsafe context else { return }
        let advertiser = unsafe Unmanaged<BonjourAdvertiser>.fromOpaque(context).takeUnretainedValue()
        let label = unsafe "\(name.map { unsafe String(cString: $0) } ?? "") \(type.map { unsafe String(cString: $0) } ?? "")"
        advertiser.registered(errorCode, name: label)
    }

    static func txtRecord(_ values: [String: String]) -> Data {
        var data = Data()
        for (key, value) in values {
            let entry = Data("\(key)=\(value)".utf8)
            data.append(UInt8(min(entry.count, 255)))
            data.append(entry.prefix(255))
        }
        return data
    }
}
