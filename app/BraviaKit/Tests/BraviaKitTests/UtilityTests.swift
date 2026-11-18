import XCTest
@testable import BraviaKit

final class KeymapTests: XCTestCase {
    func testParsesRemoteControllerInfo() {
        let result: [Any] = [
            ["bundled": true, "type": "IR_REMOTE_BUNDLE_TYPE_AEP_N"],
            [
                ["name": "TvPower", "value": "AAAAAQAAAAEAAAAVAw=="],
                ["name": "Return", "value": "AAAAAgAAAJcAAAAjAw=="],
                ["name": "Bogus", "value": "<xml/>"],
                ["name": "", "value": "AAAA"],
            ],
        ]
        let codes = IRCCKeymap.parse(remoteControllerInfo: result)
        XCTAssertEqual(codes, ["TvPower": "AAAAAQAAAAEAAAAVAw==", "Return": "AAAAAgAAAJcAAAAjAw=="])
    }

    func testPrefersTVCodesAndFallsBack() {
        let keymap = IRCCKeymap(tvCodes: ["Return": "AAAAAgAAAJcAAAAjAw==", "Home": "CUSTOMCODE=="])
        XCTAssertEqual(keymap.code(for: .home), "CUSTOMCODE==")
        XCTAssertEqual(keymap.code(for: .back), "AAAAAgAAAJcAAAAjAw==")
        XCTAssertEqual(keymap.code(for: .confirm), "AAAAAQAAAAEAAABlAw==")
    }

    func testAlternativeNamesAreUsedInPriorityOrder() {
        let keymap = IRCCKeymap(tvCodes: ["Power": "PROPOWER==", "Back": "PROBACK=="])
        XCTAssertEqual(keymap.code(for: .power), "PROPOWER==")
        XCTAssertEqual(keymap.code(for: .back), "PROBACK==")
        let consumer = IRCCKeymap(tvCodes: ["TvPower": "TVPOWER==", "Power": "PROPOWER=="])
        XCTAssertEqual(consumer.code(for: .power), "TVPOWER==")
    }

    func testAllFallbackCodesAreValidAndOfficialOnesMatchSonyTable() {
        for key in RemoteKey.allCases {
            XCTAssertTrue(IRCC.isValidCode(key.fallbackCode), "\(key)")
            XCTAssertNotNil(Data(base64Encoded: key.fallbackCode), "\(key)")
        }
        // Spot-check against pro-bravia.sony.net IRCC-IP table.
        XCTAssertEqual(RemoteKey.power.fallbackCode, "AAAAAQAAAAEAAAAVAw==")
        XCTAssertEqual(RemoteKey.volumeUp.fallbackCode, "AAAAAQAAAAEAAAASAw==")
        XCTAssertEqual(RemoteKey.hdmi4.fallbackCode, "AAAAAgAAABoAAABdAw==")
        XCTAssertEqual(RemoteKey.num0.fallbackCode, "AAAAAQAAAAEAAAAJAw==")
    }

    func testDigitAndHDMIHelpers() {
        XCTAssertEqual(RemoteKey.digit(7), .num7)
        XCTAssertNil(RemoteKey.digit(10))
        XCTAssertEqual(RemoteKey.hdmi(port: 3), .hdmi3)
        XCTAssertNil(RemoteKey.hdmi(port: 5))
    }
}

final class DiscoveryTests: XCTestCase {
    func testHostsFor24ExcludesSelfNetworkAndBroadcast() {
        let hosts = SubnetScanner.hosts(address: "192.168.100.208", netmask: "255.255.255.0")
        XCTAssertEqual(hosts.count, 253)
        XCTAssertEqual(hosts.first, "192.168.100.1")
        XCTAssertEqual(hosts.last, "192.168.100.254")
        XCTAssertFalse(hosts.contains("192.168.100.208"))
        XCTAssertFalse(hosts.contains("192.168.100.0"))
        XCTAssertFalse(hosts.contains("192.168.100.255"))
    }

    func testWideNetworksAreNarrowedTo24AndSmallOnesKept() {
        let wide = SubnetScanner.hosts(address: "10.0.5.20", netmask: "255.255.0.0")
        XCTAssertEqual(wide.count, 253)
        XCTAssertEqual(wide.first, "10.0.5.1")

        let small = SubnetScanner.hosts(address: "192.168.1.130", netmask: "255.255.255.192")
        XCTAssertEqual(small.first, "192.168.1.129")
        XCTAssertEqual(small.last, "192.168.1.190")
        XCTAssertEqual(small.count, 61)
    }

    func testInvalidInputsGiveNoHosts() {
        XCTAssertTrue(SubnetScanner.hosts(address: "garbage", netmask: "255.255.255.0").isEmpty)
        XCTAssertTrue(SubnetScanner.hosts(address: "192.168.1.1", netmask: "255.0.255.0").isEmpty)
        XCTAssertTrue(SubnetScanner.hosts(address: "192.168.1.1", netmask: "255.255.255.255").isEmpty)
    }

    func testScanFindsTVAmongManyHostsWithBoundedConcurrency() async {
        let hosts = (1...60).map { "10.0.0.\($0)" }
        let tracker = ConcurrencyTracker()
        let outcome = await SubnetScanner.scan(hosts: hosts, concurrency: 8, probe: { host in
            tracker.enter()
            defer { tracker.leave() }
            try await Task.sleep(nanoseconds: 2_000_000)
            if host == "10.0.0.42" { return DiscoveredTV(host: host, modelName: "KD-55X8507C") }
            if host == "10.0.0.7" { return nil }
            throw BraviaError.unreachable
        })
        XCTAssertEqual(outcome.found, [DiscoveredTV(host: "10.0.0.42", modelName: "KD-55X8507C")])
        XCTAssertFalse(outcome.localNetworkDenied)
        XCTAssertLessThanOrEqual(tracker.maximum, 8)
    }

    func testScanReportsLocalNetworkDenial() async {
        let outcome = await SubnetScanner.scan(hosts: ["10.0.0.1", "10.0.0.2"], probe: { _ in
            throw BraviaError.localNetworkDenied
        })
        XCTAssertTrue(outcome.localNetworkDenied)
        XCTAssertTrue(outcome.found.isEmpty)
    }

    func testProbeAcceptsTVsAndRejectsOtherSonyDevices() async throws {
        let tv = MockTransport { _ in .result([["productCategory": "tv", "productName": "BRAVIA", "modelName": "KD-55X8507C", "interfaceVersion": "3.0.0"]]) }
        let found = try await RemoteModel.probe(host: "1.2.3.4", transport: tv, clientID: "x", timeout: 1)
        XCTAssertEqual(found, DiscoveredTV(host: "1.2.3.4", modelName: "KD-55X8507C"))
        XCTAssertEqual(tv.requests.first?.rpcMethod, "getInterfaceInformation")
        XCTAssertEqual(tv.requests.first?.timeoutInterval, 1)

        let soundbar = MockTransport { _ in .result([["productCategory": "audiosystem", "productName": "HT", "modelName": "HT-X", "interfaceVersion": "1"]]) }
        let notTV = try await RemoteModel.probe(host: "1.2.3.5", transport: soundbar, clientID: "x", timeout: 1)
        XCTAssertNil(notTV)
    }
}

final class WakeOnLANTests: XCTestCase {
    func testMagicPacketBytes() throws {
        let packet = try XCTUnwrap(WakeOnLAN.magicPacket(mac: "FC:F1:52:0A:1B:2C"))
        XCTAssertEqual(packet.count, 102)
        XCTAssertEqual(Array(packet.prefix(6)), [UInt8](repeating: 0xFF, count: 6))
        let mac: [UInt8] = [0xFC, 0xF1, 0x52, 0x0A, 0x1B, 0x2C]
        for index in 0..<16 {
            let start = 6 + index * 6
            XCTAssertEqual(Array(packet[start..<start + 6]), mac)
        }
    }

    func testMagicPacketAcceptsCommonFormatsAndRejectsGarbage() {
        XCTAssertNotNil(WakeOnLAN.magicPacket(mac: "fc-f1-52-0a-1b-2c"))
        XCTAssertNotNil(WakeOnLAN.magicPacket(mac: "fcf1520a1b2c"))
        XCTAssertNil(WakeOnLAN.magicPacket(mac: "fc:f1:52:0a:1b"))
        XCTAssertNil(WakeOnLAN.magicPacket(mac: "zz:f1:52:0a:1b:2c"))
        XCTAssertNil(WakeOnLAN.magicPacket(mac: ""))
    }

    func testHostWithoutPort() {
        XCTAssertEqual(WakeOnLAN.hostWithoutPort("192.168.1.5:8080"), "192.168.1.5")
        XCTAssertEqual(WakeOnLAN.hostWithoutPort("192.168.1.5"), "192.168.1.5")
    }
}

final class TVStoreTests: XCTestCase {
    private func makeStore() -> TVStore {
        let suite = "PultTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return TVStore(defaults: defaults, secrets: MemorySecretStore())
    }

    func testPersistsTVCredentialsAndClientID() {
        let store = makeStore()
        XCTAssertNil(store.savedTV)
        XCTAssertEqual(store.credentials, .none)

        let tv = SavedTV(host: "192.168.1.50", modelName: "KD-55X8507C", macAddress: "aa:bb:cc:dd:ee:ff", irccCodes: ["Home": "X=="])
        store.savedTV = tv
        store.credentials = .pin(pin: "1234", cookie: "c", issuedAt: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(store.savedTV, tv)
        XCTAssertEqual(store.credentials, .pin(pin: "1234", cookie: "c", issuedAt: Date(timeIntervalSince1970: 100)))

        let id = store.clientID
        XCTAssertTrue(id.hasPrefix("Pult:"))
        XCTAssertEqual(store.clientID, id)

        store.forgetTV()
        XCTAssertNil(store.savedTV)
        XCTAssertEqual(store.credentials, .none)
        XCTAssertEqual(store.clientID, id, "client id must survive forgetting a TV")
    }

    func testCredentialsIsConfigured() {
        XCTAssertFalse(Credentials.none.isConfigured)
        XCTAssertFalse(Credentials.psk("").isConfigured)
        XCTAssertTrue(Credentials.psk("0000").isConfigured)
        XCTAssertFalse(Credentials.pin(pin: "1234", cookie: nil, issuedAt: nil).isConfigured)
        XCTAssertTrue(Credentials.pin(pin: "1234", cookie: "c", issuedAt: nil).isConfigured)
    }
}

final class ConcurrencyTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private(set) var maximum = 0

    func enter() {
        lock.lock()
        current += 1
        maximum = max(maximum, current)
        lock.unlock()
    }

    func leave() {
        lock.lock()
        current -= 1
        lock.unlock()
    }
}
