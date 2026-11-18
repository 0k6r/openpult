import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum NetworkInfo {
    /// IPv4 address and netmask of the Wi‑Fi interface (`en0`), or of the first
    /// non-loopback `en*` interface as a fallback.
    public static func currentIPv4() -> (address: String, netmask: String)? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var candidates: [(name: String, address: String, netmask: String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0,
                  let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let mask = entry.pointee.ifa_netmask
            else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("en"),
                  let address = numericHost(addr), let netmask = numericHost(mask)
            else { continue }
            candidates.append((name, address, netmask))
        }
        let chosen = candidates.first { $0.name == "en0" } ?? candidates.first
        return chosen.map { ($0.address, $0.netmask) }
    }

    private static func numericHost(_ sockaddrPointer: UnsafeMutablePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let length = socklen_t(sockaddrPointer.pointee.sa_len)
        guard getnameinfo(sockaddrPointer, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else {
            return nil
        }
        return String(cString: buffer)
    }
}

public struct ScanOutcome: Equatable, Sendable {
    public var found: [DiscoveredTV]
    public var localNetworkDenied: Bool
}

public enum SubnetScanner {
    /// Host addresses to probe. Networks wider than /24 are narrowed to the phone's own /24
    /// to keep the scan short; the phone's own address is skipped.
    public static func hosts(address: String, netmask: String) -> [String] {
        guard let ip = parse(address), var mask = parse(netmask) else { return [] }
        let prefix = mask.nonzeroBitCount
        guard prefix <= 30, mask == (prefix == 0 ? 0 : UInt32.max << (32 - prefix)) else { return [] }
        if prefix < 24 { mask = 0xFFFF_FF00 }
        let network = ip & mask
        let broadcast = network | ~mask
        guard broadcast > network + 1 else { return [] }
        return (network + 1..<broadcast).filter { $0 != ip }.map(format)
    }

    /// Probes hosts with bounded concurrency. `probe` returns a TV, `nil` for "not a TV",
    /// or throws (unreachable hosts are the common case).
    public static func scan(
        hosts: [String],
        concurrency: Int = 32,
        probe: @escaping @Sendable (String) async throws -> DiscoveredTV?,
        onFound: @escaping @Sendable (DiscoveredTV) async -> Void = { _ in }
    ) async -> ScanOutcome {
        var found: [DiscoveredTV] = []
        var deniedCount = 0

        await withTaskGroup(of: (DiscoveredTV?, Bool).self) { group in
            var iterator = hosts.makeIterator()
            func addNext() {
                guard !Task.isCancelled, let host = iterator.next() else { return }
                group.addTask {
                    do {
                        return (try await probe(host), false)
                    } catch let error as BraviaError {
                        return (nil, error == .localNetworkDenied)
                    } catch {
                        return (nil, false)
                    }
                }
            }
            for _ in 0..<max(1, concurrency) { addNext() }
            while let (tv, denied) = await group.next() {
                if denied { deniedCount += 1 }
                if let tv {
                    found.append(tv)
                    await onFound(tv)
                }
                addNext()
            }
        }

        found.sort { (parse($0.host) ?? 0) < (parse($1.host) ?? 0) }
        let denied = found.isEmpty && !hosts.isEmpty && deniedCount * 2 >= hosts.count
        return ScanOutcome(found: found, localNetworkDenied: denied)
    }

    static func parse(_ string: String) -> UInt32? {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let octet = UInt8(part) else { return nil }
            value = value << 8 | UInt32(octet)
        }
        return value
    }

    static func format(_ value: UInt32) -> String {
        "\(value >> 24 & 0xFF).\(value >> 16 & 0xFF).\(value >> 8 & 0xFF).\(value & 0xFF)"
    }
}
