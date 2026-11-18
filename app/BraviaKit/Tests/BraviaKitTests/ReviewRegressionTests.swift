import XCTest
@testable import BraviaKit

/// Regression tests for issues found in code review.
final class ClientReviewRegressionTests: XCTestCase {
    private func makeClient(_ transport: MockTransport, credentials: Credentials) -> BraviaClient {
        BraviaClient(host: "192.168.1.50", credentials: credentials, clientID: "Pult:TEST", transport: transport)
    }

    private static let renewedCookieResponse = MockResponse(
        status: 200, body: Data(#"{"result":[],"id":1}"#.utf8), headers: ["Set-Cookie": "auth=new; Path=/sony/"]
    )

    func testParallel403sTriggerSingleRenewal() async throws {
        let transport = MockTransport { request in
            if request.path == "/sony/accessControl" { return Self.renewedCookieResponse }
            if request.value(forHTTPHeaderField: "Cookie") == "auth=new" {
                return .result([["status": "active"]])
            }
            usleep(30_000) // keep all stale requests in flight together
            return .error(403, "Forbidden", status: 403)
        }
        let client = makeClient(transport, credentials: .pin(pin: "1234", cookie: "old", issuedAt: Date()))

        try await withThrowingTaskGroup(of: PowerStatus.self) { group in
            for _ in 0..<5 { group.addTask { try await client.powerStatus() } }
            for try await status in group { XCTAssertEqual(status, .active) }
        }

        XCTAssertEqual(transport.requests.filter { $0.path == "/sony/accessControl" }.count, 1)
    }

    func testRejectedPINBlocksFurtherRenewals() async {
        let transport = MockTransport { request in
            request.path == "/sony/accessControl"
                ? .error(401, "Unauthorized", status: 401)
                : .error(403, "Forbidden", status: 403)
        }
        let client = makeClient(transport, credentials: .pin(pin: "1234", cookie: "old", issuedAt: Date()))

        for _ in 0..<3 {
            do {
                _ = try await client.powerStatus()
                XCTFail("Expected error")
            } catch {
                XCTAssertEqual(error as? BraviaError, .unauthorized)
            }
        }
        await client.renewIfNeeded()

        XCTAssertEqual(transport.requests.filter { $0.path == "/sony/accessControl" }.count, 1,
                       "each renewal may pop up a PIN on the TV, so a rejected PIN must not be retried")
    }

    func testIRCC403RenewsCookieAndRetries() async throws {
        let transport = MockTransport { request in
            if request.path == "/sony/accessControl" { return Self.renewedCookieResponse }
            return request.value(forHTTPHeaderField: "Cookie") == "auth=new" ? .ok : MockResponse(status: 403)
        }
        let client = makeClient(transport, credentials: .pin(pin: "1234", cookie: "old", issuedAt: Date()))

        try await client.send(.home, keymap: IRCCKeymap())

        XCTAssertEqual(transport.requests.map(\.path), ["/sony/IRCC", "/sony/IRCC", "/sony/accessControl", "/sony/IRCC"])
        XCTAssertEqual(transport.requests.last?.irccCode, RemoteKey.home.fallbackCode)
    }

    func testBothIRCCPathsMissingIsUnsupported() async {
        let client = makeClient(MockTransport { _ in MockResponse(status: 404) }, credentials: .psk("0000"))
        do {
            try await client.send(.home, keymap: IRCCKeymap())
            XCTFail("Expected error")
        } catch {
            XCTAssertEqual(error as? BraviaError, .unsupported)
        }
    }

    func testWakeTimeoutDoesNotDropTheKey() async throws {
        let transport = MockTransport { request in
            if request.irccCode == "" { throw URLError(.timedOut) }
            return .ok
        }
        let client = makeClient(transport, credentials: .psk("0000"))

        try await client.send(.confirm, keymap: IRCCKeymap())

        XCTAssertEqual(transport.requests.last?.irccCode, RemoteKey.confirm.fallbackCode)
    }

    func testWakeConnectionRefusedStopsTheKey() async {
        let transport = MockTransport { _ in throw URLError(.cannotConnectToHost) }
        let client = makeClient(transport, credentials: .psk("0000"))
        do {
            try await client.send(.confirm, keymap: IRCCKeymap())
            XCTFail("Expected error")
        } catch {
            XCTAssertEqual(error as? BraviaError, .unreachable)
        }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testPairedWithoutPINNeedsACookie() async throws {
        let noCookie = makeClient(MockTransport { _ in .result([]) }, credentials: .none)
        do {
            _ = try await noCookie.startPairing()
            XCTFail("Expected error")
        } catch {
            XCTAssertEqual(error as? BraviaError, .pairingRejected)
        }

        let withCookie = makeClient(MockTransport { _ in Self.renewedCookieResponse }, credentials: .none)
        let result = try await withCookie.startPairing()
        XCTAssertEqual(result, .paired)
        let credentials = await withCookie.credentials
        XCTAssertTrue(credentials.isConfigured)
    }
}

@MainActor
final class ModelReviewRegressionTests: XCTestCase {
    private let tv = SavedTV(host: "192.168.1.50", modelName: "KD-55X8507C", macAddress: "fc:f1:52:00:11:22")
    private var wakes = StringRecorder()

    private func makeStore(tv: SavedTV?, credentials: Credentials) -> TVStore {
        let suite = "PultRegression-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = TVStore(defaults: defaults, secrets: MemorySecretStore())
        store.savedTV = tv
        store.credentials = credentials
        return store
    }

    private func makeModel(store: TVStore, transport: MockTransport) -> RemoteModel {
        let wakes = StringRecorder()
        self.wakes = wakes
        return RemoteModel(
            store: store,
            transport: transport,
            wake: { mac, host in wakes.append("\(mac)@\(host)") },
            pause: { _ in },
            networkInfo: { ("192.168.1.10", "255.255.255.0") }
        )
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(condition(), "condition not reached")
    }

    func testForgetDuringRefreshDoesNotResurrectTV() async throws {
        let transport = MockTransport { request in
            switch request.rpcMethod {
            case "getPowerStatus": return .result([["status": "active"]])
            case "getRemoteControllerInfo":
                usleep(200_000)
                return .result([["bundled": true], [["name": "Home", "value": "HOME=="]]])
            default: return .result([])
            }
        }
        let store = makeStore(tv: SavedTV(host: "192.168.1.50", modelName: "X"), credentials: .psk("0000"))
        let model = makeModel(store: store, transport: transport)

        async let refresh: Void = model.refresh()
        try await waitUntil { transport.requests.contains { $0.rpcMethod == "getRemoteControllerInfo" } }
        model.forgetTV()
        await refresh

        XCTAssertNil(model.tv)
        XCTAssertNil(store.savedTV)
        XCTAssertEqual(model.screen, .discovery)
    }

    func testSelectingAnotherTVDuringRefreshKeepsNewTV() async throws {
        let transport = MockTransport { request in
            switch request.rpcMethod {
            case "getPowerStatus": return .result([["status": "active"]])
            case "getRemoteControllerInfo":
                usleep(200_000)
                return .result([["bundled": true], [["name": "Home", "value": "HOME=="]]])
            default: return .result([])
            }
        }
        let store = makeStore(tv: SavedTV(host: "192.168.1.50", modelName: "Old"), credentials: .psk("0000"))
        let model = makeModel(store: store, transport: transport)

        async let refresh: Void = model.refresh()
        try await waitUntil { transport.requests.contains { $0.rpcMethod == "getRemoteControllerInfo" } }
        model.select(DiscoveredTV(host: "192.168.1.77", modelName: "New"))
        await refresh

        XCTAssertEqual(store.savedTV?.host, "192.168.1.77")
        XCTAssertEqual(model.tv?.host, "192.168.1.77")
        XCTAssertEqual(store.savedTV?.irccCodes, [:])
    }

    func testTogglePowerWhenUnauthorizedOffersRepairInsteadOfWakeOnLAN() async {
        let transport = MockTransport { _ in .error(403, "Forbidden", status: 403) }
        let model = makeModel(store: makeStore(tv: tv, credentials: .psk("0000")), transport: transport)

        await model.togglePower()

        XCTAssertTrue(wakes.values.isEmpty)
        XCTAssertEqual(model.banner?.action, .repair)
    }

    func testSetPowerFailureAfterWakeOnLANFallsBackToWakeUpKey() async {
        let statusCalls = StringRecorder()
        let transport = MockTransport { request in
            switch request.rpcMethod {
            case "getPowerStatus":
                statusCalls.append("s")
                if statusCalls.values.count <= 2 { throw URLError(.timedOut) }
                return .result([["status": "standby"]])
            case "setPowerStatus":
                return .error(15, "Unsupported Operation")
            default:
                return .ok
            }
        }
        let model = makeModel(store: makeStore(tv: tv, credentials: .psk("0000")), transport: transport)

        await model.togglePower()

        XCTAssertTrue(transport.requests.contains { $0.irccCode == RemoteKey.wakeUp.fallbackCode })
        XCTAssertEqual(model.power, .on)
    }

    func testFailedTurnOnAfterWakeOnLANIsReported() async {
        let statusCalls = StringRecorder()
        let transport = MockTransport { request in
            if request.rpcMethod == "getPowerStatus" {
                statusCalls.append("s")
                if statusCalls.values.count <= 1 { throw URLError(.timedOut) }
                return .result([["status": "standby"]])
            }
            if request.rpcMethod == "setPowerStatus" { return .error(15, "Unsupported Operation") }
            return MockResponse(status: 500) // IRCC rejected too
        }
        let model = makeModel(store: makeStore(tv: tv, credentials: .psk("0000")), transport: transport)

        await model.togglePower()

        XCTAssertNotEqual(model.power, .on)
        XCTAssertEqual(model.banner?.isError, true)
    }

    func testCancelledPowerOnStopsSendingWakePackets() async {
        let model = makeModel(store: makeStore(tv: tv, credentials: .psk("0000")), transport: MockTransport { _ in throw URLError(.timedOut) })
        let task = Task { await model.togglePower() }
        task.cancel()
        await task.value
        XCTAssertTrue(wakes.values.isEmpty)
    }

    func testRepairDuringRenewalKeepsCredentialsCleared() async throws {
        let transport = MockTransport { request in
            if request.path == "/sony/accessControl" {
                usleep(200_000)
                return MockResponse(status: 200, body: Data(#"{"result":[],"id":1}"#.utf8), headers: ["Set-Cookie": "auth=new"])
            }
            return request.value(forHTTPHeaderField: "Cookie") == "auth=new" ? .ok : MockResponse(status: 403)
        }
        let store = makeStore(tv: tv, credentials: .pin(pin: "1234", cookie: "old", issuedAt: Date()))
        let model = makeModel(store: store, transport: transport)

        async let press = model.press(.home)
        try await waitUntil { transport.requests.contains { $0.path == "/sony/accessControl" } }
        model.repair()
        _ = await press
        try await Task.sleep(nanoseconds: 50_000_000) // let the credentials callback hop to the main actor

        XCTAssertEqual(store.credentials, .none)
        XCTAssertEqual(model.screen, .pairing)
    }

    func testPressReportsDeliveryForHoldToRepeat() async {
        let failing = makeModel(store: makeStore(tv: tv, credentials: .psk("0000")), transport: MockTransport { _ in MockResponse(status: 403) })
        let failed = await failing.press(.volumeUp)
        XCTAssertFalse(failed)

        let working = makeModel(store: makeStore(tv: tv, credentials: .psk("0000")), transport: MockTransport { _ in .ok })
        let delivered = await working.press(.volumeUp)
        XCTAssertTrue(delivered)
    }

    func testATSBlockGivesActionableMessage() {
        let error = BraviaError.from(urlError: URLError(.appTransportSecurityRequiresSecureConnection))
        guard case .invalidInput(let message) = error else { return XCTFail("Unexpected \(error)") }
        XCTAssertEqual(message, L10n.enterTVAddress)
    }

    func testConcurrentPairingCallsAreIgnored() async {
        let transport = MockTransport { _ in
            usleep(50_000)
            return .error(401, "Unauthorized", status: 401)
        }
        let model = makeModel(store: makeStore(tv: tv, credentials: .none), transport: transport)

        async let first: Void = model.requestPIN()
        async let second: Void = model.requestPIN()
        _ = await (first, second)

        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertFalse(model.isWorking)
    }
}
