import XCTest
@testable import BraviaKit

@MainActor
final class RemoteModelTests: XCTestCase {
    private var wakes: StringRecorder!

    private func makeStore(tv: SavedTV? = nil, credentials: Credentials = .none) -> TVStore {
        let suite = "PultModelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = TVStore(defaults: defaults, secrets: MemorySecretStore())
        store.savedTV = tv
        store.credentials = credentials
        return store
    }

    private func makeModel(
        store: TVStore,
        transport: MockTransport,
        network: (address: String, netmask: String)? = ("192.168.1.10", "255.255.255.0")
    ) -> RemoteModel {
        let wakes = StringRecorder()
        self.wakes = wakes
        return RemoteModel(
            store: store,
            transport: transport,
            wake: { mac, host in wakes.append("\(mac)@\(host)") },
            pause: { _ in },
            networkInfo: { network }
        )
    }

    private let tv = SavedTV(host: "192.168.1.50", modelName: "KD-55X8507C", macAddress: "fc:f1:52:00:11:22")

    // MARK: Startup routing

    func testInitialScreenDependsOnSavedState() {
        XCTAssertEqual(makeModel(store: makeStore(), transport: MockTransport()).screen, .discovery)
        XCTAssertEqual(makeModel(store: makeStore(tv: tv), transport: MockTransport()).screen, .pairing)
        XCTAssertEqual(makeModel(store: makeStore(tv: tv, credentials: .psk("0000")), transport: MockTransport()).screen, .remote)
    }

    // MARK: Discovery

    func testScanFindsTVAndSelectingItOpensPairing() async {
        let transport = MockTransport { request in
            if request.url?.host == "192.168.1.50" {
                return .result([["productCategory": "tv", "productName": "BRAVIA", "modelName": "KD-55X8507C", "interfaceVersion": "3"]])
            }
            throw URLError(.cannotConnectToHost)
        }
        let model = makeModel(store: makeStore(), transport: transport)

        await model.startScan()

        XCTAssertEqual(model.discovered, [DiscoveredTV(host: "192.168.1.50", modelName: "KD-55X8507C")])
        XCTAssertTrue(model.scanCompleted)
        XCTAssertFalse(model.isScanning)

        model.select(model.discovered[0])
        XCTAssertEqual(model.screen, .pairing)
        XCTAssertEqual(model.tv?.host, "192.168.1.50")
    }

    func testScanWithoutWiFiShowsBanner() async {
        let model = makeModel(store: makeStore(), transport: MockTransport(), network: nil)
        await model.startScan()
        XCTAssertTrue(model.discovered.isEmpty)
        XCTAssertEqual(model.banner?.isError, true)
    }

    func testNormalizeHost() {
        XCTAssertEqual(RemoteModel.normalizeHost(" 192.168.1.50 "), "192.168.1.50")
        XCTAssertEqual(RemoteModel.normalizeHost("http://192.168.1.50/sony/system"), "192.168.1.50")
        XCTAssertEqual(RemoteModel.normalizeHost("192.168.1.50:8080"), "192.168.1.50:8080")
        XCTAssertEqual(RemoteModel.normalizeHost("bravia.local"), "bravia.local")
        XCTAssertNil(RemoteModel.normalizeHost(""))
        XCTAssertNil(RemoteModel.normalizeHost("192.168.1.50 extra"))
        XCTAssertNil(RemoteModel.normalizeHost("a@b"))
    }

    func testManualConnectFailsGracefully() async {
        let model = makeModel(store: makeStore(), transport: MockTransport { _ in throw URLError(.timedOut) })
        await model.connectManually(host: "192.168.1.77")
        XCTAssertEqual(model.screen, .discovery)
        XCTAssertEqual(model.banner?.text, BraviaError.unreachable.localizedDescription)
    }

    // MARK: Pairing

    func testPSKPairingSavesCredentialsAndMAC() async {
        let store = makeStore(tv: SavedTV(host: "192.168.1.50", modelName: "BRAVIA"))
        let transport = MockTransport { request in
            guard request.value(forHTTPHeaderField: "X-Auth-PSK") == "0000" else {
                return .error(403, "Forbidden", status: 403)
            }
            switch request.rpcMethod {
            case "getSystemInformation":
                return .result([["model": "KD-55X8507C", "name": "BRAVIA", "macAddr": "fc:f1:52:00:11:22"]])
            case "getPowerStatus":
                return .result([["status": "active"]])
            case "getRemoteControllerInfo":
                return .result([["bundled": true], [["name": "Home", "value": "HOME=="]]])
            default:
                return .result([])
            }
        }
        let model = makeModel(store: store, transport: transport)

        await model.usePSK("1111")
        XCTAssertEqual(model.screen, .pairing)
        XCTAssertEqual(store.credentials, .none)
        XCTAssertEqual(model.banner?.isError, true)

        await model.usePSK(" 0000 ")
        XCTAssertEqual(model.screen, .remote)
        XCTAssertEqual(store.credentials, .psk("0000"))
        XCTAssertEqual(store.savedTV?.macAddress, "fc:f1:52:00:11:22")
        XCTAssertEqual(store.savedTV?.modelName, "KD-55X8507C")
        XCTAssertEqual(store.savedTV?.irccCodes, ["Home": "HOME=="])
        XCTAssertEqual(model.keymap.code(for: .home), "HOME==")
        XCTAssertEqual(model.power, .on)
    }

    func testPINPairingFlow() async {
        let store = makeStore(tv: SavedTV(host: "192.168.1.50", modelName: "BRAVIA"))
        let transport = MockTransport { request in
            if request.path == "/sony/accessControl" {
                if request.value(forHTTPHeaderField: "Authorization") == nil {
                    return .error(401, "Unauthorized", status: 401)
                }
                return MockResponse(status: 200, body: Data(#"{"result":[],"id":1}"#.utf8), headers: ["Set-Cookie": "auth=cookie1; Path=/sony/"])
            }
            return request.rpcMethod == "getPowerStatus" ? .result([["status": "standby"]]) : .result([])
        }
        let model = makeModel(store: store, transport: transport)

        await model.requestPIN()
        XCTAssertTrue(model.pinRequested)

        await model.submitPIN("4321")
        XCTAssertEqual(model.screen, .remote)
        guard case .pin(let pin, let cookie, _) = store.credentials else {
            return XCTFail("Expected pin credentials, got \(store.credentials)")
        }
        XCTAssertEqual(pin, "4321")
        XCTAssertEqual(cookie, "cookie1")
        XCTAssertEqual(model.power, .standby)
    }

    // MARK: Remote

    func testPressSendsResolvedCode() async {
        let transport = MockTransport { _ in .ok }
        let store = makeStore(tv: SavedTV(host: "192.168.1.50", modelName: "X", irccCodes: ["Return": "TVRETURN=="]), credentials: .psk("0000"))
        let model = makeModel(store: store, transport: transport)

        await model.press(.back)

        XCTAssertEqual(transport.requests.last?.irccCode, "TVRETURN==")
        XCTAssertNil(model.banner)
    }

    func testUnauthorizedPressOffersRepair() async {
        let transport = MockTransport { _ in MockResponse(status: 403) }
        let model = makeModel(store: makeStore(tv: tv, credentials: .psk("0000")), transport: transport)

        await model.press(.home)

        XCTAssertEqual(model.banner?.action, .repair)
        model.repair()
        XCTAssertEqual(model.screen, .pairing)
    }

    func testPowerOffWhenActive() async {
        let transport = MockTransport { request in
            request.rpcMethod == "getPowerStatus" ? .result([["status": "active"]]) : .result([])
        }
        let model = makeModel(store: makeStore(tv: tv, credentials: .psk("0000")), transport: transport)

        await model.togglePower()

        let setPower = transport.requests.first { $0.rpcMethod == "setPowerStatus" }
        XCTAssertEqual((setPower?.jsonBody?["params"] as? [[String: Any]])?.first?["status"] as? Bool, false)
        XCTAssertEqual(model.power, .standby)
    }

    func testPowerOnFromStandbyFallsBackToWakeUpKey() async {
        let transport = MockTransport { request in
            switch request.rpcMethod {
            case "getPowerStatus": return .result([["status": "standby"]])
            case "setPowerStatus": return .error(15, "Unsupported Operation")
            default: return .ok
            }
        }
        let model = makeModel(store: makeStore(tv: tv, credentials: .psk("0000")), transport: transport)

        await model.togglePower()

        XCTAssertTrue(transport.requests.contains { $0.irccCode == RemoteKey.wakeUp.fallbackCode })
        XCTAssertEqual(model.power, .on)
    }

    func testPowerOnFromOfflineUsesWakeOnLANThenSetPower() async {
        let attempts = StringRecorder()
        let transport = MockTransport { request in
            if request.rpcMethod == "getPowerStatus" {
                attempts.append("status")
                // Unreachable for the first check and the first wake attempt.
                if attempts.values.count <= 2 { throw URLError(.timedOut) }
                return .result([["status": "standby"]])
            }
            return .result([])
        }
        let model = makeModel(store: makeStore(tv: tv, credentials: .psk("0000")), transport: transport)

        await model.togglePower()

        XCTAssertEqual(wakes.values, ["fc:f1:52:00:11:22@192.168.1.50", "fc:f1:52:00:11:22@192.168.1.50"])
        let setPower = transport.requests.first { $0.rpcMethod == "setPowerStatus" }
        XCTAssertEqual((setPower?.jsonBody?["params"] as? [[String: Any]])?.first?["status"] as? Bool, true)
        XCTAssertEqual(model.power, .on)
        XCTAssertFalse(model.isPowerBusy)
    }

    func testPowerOnWithoutMACExplainsWhatToDo() async {
        let transport = MockTransport { _ in throw URLError(.timedOut) }
        let store = makeStore(tv: SavedTV(host: "192.168.1.50", modelName: "X"), credentials: .psk("0000"))
        let model = makeModel(store: store, transport: transport)

        await model.togglePower()

        XCTAssertTrue(wakes.values.isEmpty)
        XCTAssertEqual(model.power, .offline)
        XCTAssertEqual(model.banner?.isError, true)
    }

    func testPowerOnGivesUpAfterRetries() async {
        let transport = MockTransport { _ in throw URLError(.timedOut) }
        let model = makeModel(store: makeStore(tv: tv, credentials: .psk("0000")), transport: transport)

        await model.togglePower()

        XCTAssertEqual(wakes.values.count, 8)
        XCTAssertEqual(model.power, .offline)
        XCTAssertEqual(model.banner?.isError, true)
    }

    func testConcurrentRefreshesAreCoalesced() async {
        let transport = MockTransport { request in
            request.rpcMethod == "getPowerStatus" ? .result([["status": "active"]]) : .result([])
        }
        let model = makeModel(store: makeStore(tv: tv, credentials: .psk("0000")), transport: transport)

        async let first: Void = model.refresh()
        async let second: Void = model.refresh()
        _ = await (first, second)

        XCTAssertEqual(transport.requests.filter { $0.rpcMethod == "getPowerStatus" }.count, 1)
        await model.refresh()
        XCTAssertEqual(transport.requests.filter { $0.rpcMethod == "getPowerStatus" }.count, 2)
    }

    func testRefreshMarksOfflineWhenUnreachable() async {
        let model = makeModel(store: makeStore(tv: tv, credentials: .psk("0000")), transport: MockTransport { _ in throw URLError(.timedOut) })
        await model.refresh()
        XCTAssertEqual(model.power, .offline)
    }

    func testSendTextReportsInactiveKeyboard() async {
        let transport = MockTransport { _ in .error(7, "Illegal State") }
        let model = makeModel(store: makeStore(tv: tv, credentials: .psk("0000")), transport: transport)

        let sent = await model.sendText("матрица")

        XCTAssertFalse(sent)
        XCTAssertEqual(model.banner?.text, BraviaError.keyboardInactive.localizedDescription)
        XCTAssertEqual(transport.requests.first?.jsonBody?["params"] as? [String], ["матрица"])
    }

    func testAppsAreSortedAndLaunched() async {
        let transport = MockTransport { request in
            switch request.rpcMethod {
            case "getApplicationList":
                return .result([[["title": "YouTube", "uri": "yt"], ["title": "Netflix", "uri": "nf"], ["title": "browser", "uri": "br"]]])
            default:
                return .result([])
            }
        }
        let model = makeModel(store: makeStore(tv: tv, credentials: .psk("0000")), transport: transport)

        await model.loadApps()
        XCTAssertEqual(model.apps.map(\.title), ["browser", "Netflix", "YouTube"])

        await model.launch(model.apps[1])
        let launch = transport.requests.last
        XCTAssertEqual(launch?.rpcMethod, "setActiveApp")
        XCTAssertEqual((launch?.jsonBody?["params"] as? [[String: Any]])?.first?["uri"] as? String, "nf")
    }

    func testSwitchInputFallsBackToHDMIKey() async {
        let transport = MockTransport { request in
            request.rpcMethod == "setPlayContent" ? .error(15, "Unsupported Operation") : .ok
        }
        let model = makeModel(store: makeStore(tv: tv, credentials: .psk("0000")), transport: transport)

        await model.switchInput(ExternalInput(uri: "extInput:hdmi?port=3", title: "HDMI 3", label: "", isConnected: true))

        XCTAssertEqual(transport.requests.last?.irccCode, RemoteKey.hdmi3.fallbackCode)
    }

    func testForgetTVReturnsToDiscovery() {
        let store = makeStore(tv: tv, credentials: .psk("0000"))
        let model = makeModel(store: store, transport: MockTransport())
        model.forgetTV()
        XCTAssertEqual(model.screen, .discovery)
        XCTAssertNil(store.savedTV)
        XCTAssertEqual(store.credentials, .none)
    }

    func testSelectingAnotherTVDropsOldCredentials() {
        let store = makeStore(tv: tv, credentials: .psk("0000"))
        let model = makeModel(store: store, transport: MockTransport())

        model.select(DiscoveredTV(host: "192.168.1.51", modelName: "Other"))

        XCTAssertEqual(store.credentials, .none)
        XCTAssertEqual(model.screen, .pairing)
    }
}
