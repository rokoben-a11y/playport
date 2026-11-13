// SPDX-License-Identifier: GPL-3.0-or-later
// RemotePairing's RSD port on this phone (playport #55). Playport 0.5.0 always
// reached the tunnel at 10.7.0.1:49152 (StikJIT 1.9.0's Configuration
// default), but iOS 27 can put RemotePairing on another port; the readiness
// check then ends "unreachable: Timed out connecting to 10.7.0.1:49152" while
// LocalDevVPN shows Connected, and the pairing is discarded.
//
// The phone advertises the service as `_remotepairing._tcp` in `local.`
// (Info.plist NSBonjourServices lists it, so Local Network access covers the
// browse). `resolve` browses for it for up to 5 s and takes the port of the
// instance whose addresses are this phone's own; with none of those, the one
// instance seen, if there is exactly one. Otherwise, or with no answer, the last
// port found in this process, else 49152. A port stored under `jit.rsdPort`
// (UserDefaults; a number or its text) is used as it is, without browsing.
//
// The port goes to the helper over XPC (JITHelping, BuiltInJit.swift), which
// hands it to StikJIT.Configuration(rsdPort:), to the restart (AppRestart.swift,
// relaunch.c) and to LocalDevVPN's route probe.

import Darwin
import Foundation
import os

enum RemotePairingPort {
    /// StikJIT 1.9.0's default, RemotePairing's port before iOS 27.
    static let fallback: UInt16 = 49152
    /// A port set by hand: used as it is, without browsing.
    static let overrideKey = "jit.rsdPort"
    static let serviceType = "_remotepairing._tcp."
    static let domain = "local."

    /// The last port the browse found in this process.
    private static let found = OSAllocatedUnfairLock<UInt16?>(initialState: nil)

    /// `jit.rsdPort` when it holds a port (1 to 65535).
    static var override: UInt16? {
        let v = UserDefaults.standard.integer(forKey: overrideKey)
        return v >= 1 && v <= 65535 ? UInt16(v) : nil
    }

    /// The port to use without waiting: the override, else the last one found, else 49152.
    static var current: UInt16 { override ?? found.withLock { $0 } ?? fallback }

    /// The override; else, unless `fresh`, the last port found; else a browse of up
    /// to `timeout` seconds; else the last port found, else 49152. Blocks the
    /// calling thread while it browses: never call it on the main thread.
    static func resolve(fresh: Bool = true, timeout: TimeInterval = 5, log: (String) -> Void = { _ in }) -> UInt16 {
        if let o = override {
            log("rsd port \(o) (\(overrideKey))")
            return o
        }
        if !fresh, let p = found.withLock({ $0 }) { return p }
        let started = Date()
        if let p = PortBrowse(timeout: timeout).run() {
            found.withLock { $0 = p }
            log("rsd port \(p) (\(serviceType) answered in \(Int(Date().timeIntervalSince(started) * 1000)) ms)")
            return p
        }
        let p = found.withLock { $0 } ?? fallback
        log("rsd port \(p) (no usable \(serviceType) answer in \(Int(timeout)) s)")
        return p
    }
}

/// One browse: its own thread, whose run loop the browser and the resolves are
/// scheduled on; every delegate call arrives on that thread.
private final class PortBrowse: NSObject, NetServiceBrowserDelegate, NetServiceDelegate, @unchecked Sendable {
    private let timeout: TimeInterval
    private var instances: [NetService] = []
    /// Each resolved instance's port, and whether one of its addresses is this phone's.
    private var resolved: [ObjectIdentifier: (port: UInt16, own: Bool)] = [:]
    private var moreComing = true
    private var stopped = false

    init(timeout: TimeInterval) { self.timeout = timeout }

    /// The chosen port, or nil.
    func run() -> UInt16? {
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            search()
            finished.signal()
        }
        thread.name = "playport.rsd-port"
        thread.start()
        finished.wait()
        return choice
    }

    /// An instance on this phone; else the only instance seen.
    private var choice: UInt16? {
        if let own = resolved.values.first(where: { $0.own }) { return own.port }
        return instances.count == 1 && resolved.count == 1 ? resolved.values.first?.port : nil
    }

    private func search() {
        let browser = NetServiceBrowser()
        browser.delegate = self
        browser.searchForServices(ofType: RemotePairingPort.serviceType, inDomain: RemotePairingPort.domain)
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !stopped, Date() < deadline {
            if resolved.values.contains(where: { $0.own }) { break }
            // Every instance announced so far has answered, and no more are coming.
            if !moreComing, !instances.isEmpty, resolved.count == instances.count { break }
            if !RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1)) {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        browser.stop()
        for s in instances { s.stop() }
        browser.delegate = nil
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        self.moreComing = moreComing
        instances.append(service)
        service.delegate = self
        service.resolve(withTimeout: timeout)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        stopped = true
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard sender.port >= 1, sender.port <= 65535 else { return }
        resolved[ObjectIdentifier(sender)] = (UInt16(sender.port), Self.isOwn(sender.addresses))
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        instances.removeAll { $0 === sender }
        resolved[ObjectIdentifier(sender)] = nil
    }

    /// Whether one of `addresses` (sockaddr bytes) is an address of this phone's interfaces.
    static func isOwn(_ addresses: [Data]?) -> Bool {
        guard let addresses, !addresses.isEmpty else { return false }
        let mine = localAddresses()
        return addresses.contains { mine.contains(Self.key($0)) }
    }

    /// An IPv4 or IPv6 address's bytes (no port, no scope), or empty.
    static func key(_ sa: Data) -> Data {
        sa.withUnsafeBytes { raw -> Data in
            guard raw.count >= MemoryLayout<sockaddr>.size, let base = raw.baseAddress else { return Data() }
            let family = base.assumingMemoryBound(to: sockaddr.self).pointee.sa_family
            if family == sa_family_t(AF_INET), raw.count >= MemoryLayout<sockaddr_in>.size {
                var a = base.assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                return Data(bytes: &a, count: MemoryLayout<in_addr>.size)
            }
            if family == sa_family_t(AF_INET6), raw.count >= MemoryLayout<sockaddr_in6>.size {
                var a = base.assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                return Data(bytes: &a, count: MemoryLayout<in6_addr>.size)
            }
            return Data()
        }
    }

    /// Every address of this phone's interfaces, as `key` gives them.
    static func localAddresses() -> Set<Data> {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var out = Set<Data>()
        for ifa in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = ifa.pointee.ifa_addr else { continue }
            let len = addr.pointee.sa_family == sa_family_t(AF_INET6) ? MemoryLayout<sockaddr_in6>.size
                : addr.pointee.sa_family == sa_family_t(AF_INET) ? MemoryLayout<sockaddr_in>.size : 0
            guard len > 0 else { continue }
            let k = key(Data(bytes: addr, count: len))
            if !k.isEmpty { out.insert(k) }
        }
        return out
    }
}
