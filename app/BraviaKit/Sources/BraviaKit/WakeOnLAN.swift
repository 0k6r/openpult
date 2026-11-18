import Foundation
import Network

/// Wake-on-LAN via unicast UDP to the TV's last known IP.
/// Broadcast would need the multicast entitlement, which a free developer team cannot get.
public enum WakeOnLAN {
    /// `FF×6` followed by the MAC address repeated 16 times.
    public static func magicPacket(mac: String) -> Data? {
        let hex = mac.filter { $0.isHexDigit }
        let separators = mac.filter { !$0.isHexDigit }
        guard hex.count == 12, separators.allSatisfy({ $0 == ":" || $0 == "-" || $0 == "." }) else {
            return nil
        }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: bytes) }
        return packet
    }

    public static func send(mac: String, host: String) async {
        guard let packet = magicPacket(mac: mac) else { return }
        let address = hostWithoutPort(host)
        for port: UInt16 in [9, 7] {
            await sendUDP(packet, host: address, port: port)
        }
    }

    static func hostWithoutPort(_ host: String) -> String {
        if let colon = host.lastIndex(of: ":"), host.firstIndex(of: ":") == colon {
            return String(host[..<colon])
        }
        return host
    }

    private static func sendUDP(_ data: Data, host: String, port: UInt16) async {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .udp)
        let once = Once()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let finish = {
                once.run {
                    connection.cancel()
                    continuation.resume()
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: data, completion: .contentProcessed { _ in finish() })
                case .failed, .cancelled:
                    finish()
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { finish() }
        }
    }
}

/// Runs a closure at most once across threads.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        let shouldRun = !done
        done = true
        lock.unlock()
        if shouldRun { body() }
    }
}
