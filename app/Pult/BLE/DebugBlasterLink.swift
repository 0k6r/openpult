#if DEBUG
import Foundation
import BraviaKit

/// A fake bridge for the simulator (launch argument `-PultDebugBlaster YES`).
@MainActor
final class DebugBlasterLink: BlasterLink {
    var onEvent: ((BlasterLinkEvent) -> Void)?
    let maxWriteLength = 182
    private let bridge = DiscoveredBlaster(id: UUID(uuidString: "0B1A57E2-0000-4000-8000-000000000001")!, name: "OpenPult", rssi: -48)
    private var captures: UInt8 = 0
    private var connected = false
    /// Bumped on disconnect so delayed callbacks of an old attempt are dropped.
    private var generation = 0

    func startScan() {
        onEvent?(.availability(.poweredOn))
        after(0.8) { $0.onEvent?(.discovered($0.bridge)) }
    }

    func stopScan() {}

    func connect(id: UUID) {
        onEvent?(.availability(.poweredOn))
        let attempt = generation
        after(0.6) { link in
            guard link.generation == attempt else { return }
            link.connected = true
            link.onEvent?(.ready)
            link.onEvent?(.battery(87))
            link.onEvent?(.firmware("2.0.0-debug"))
            // Protocol 2, 4500 mV, caps: PLAY + LEARN + UF2, max blob 576.
            link.onEvent?(.status(Data([2, 0, 0x94, 0x11, 8, 0, 12, 0, 0b1011, 0x40, 0x02, 0])))
        }
    }

    func disconnect() {
        connected = false
        generation += 1
    }

    func write(_ data: Data) async throws {
        guard connected else { throw BlasterLinkError.notConnected }
        try? await Task.sleep(for: .milliseconds(30))
        print("DebugBlasterLink write:", data.map { String(format: "%02X", $0) }.joined(separator: " "))
        if data.first == 0x20 {
            // Learning: pretend the user pressed LG Power (NEC 0x04/0x08) on the original remote.
            after(1.5) { link in
                guard link.connected else { return }
                link.captures &+= 1
                link.onEvent?(.capture(Self.necCapture(id: link.captures)))
            }
        }
    }

    private static func necCapture(id: UInt8) -> Data {
        var durations = [9000, 4500]
        for byte: UInt8 in [0x04, 0xFB, 0x08, 0xF7] {
            for bit in 0..<8 { durations += [560, (byte >> bit) & 1 == 1 ? 1690 : 560] }
        }
        durations.append(560)
        var bytes: [UInt8] = [id, 0x80, 0, UInt8(durations.count), 0]
        for var value in durations {
            repeat {
                let low = UInt8(value & 0x7F)
                value >>= 7
                bytes.append(value == 0 ? low : low | 0x80)
            } while value != 0
        }
        return Data(bytes)
    }

    private func after(_ seconds: Double, _ action: @escaping @MainActor (DebugBlasterLink) -> Void) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if let self { action(self) }
        }
    }
}
#endif
