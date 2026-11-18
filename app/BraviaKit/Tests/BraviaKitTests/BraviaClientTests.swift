import XCTest
@testable import BraviaKit

final class BraviaClientTests: XCTestCase {
    private func makeClient(
        _ transport: MockTransport,
        credentials: Credentials = .none,
        clock: TestClock = TestClock(),
        onChange: (@Sendable (Credentials) -> Void)? = nil
    ) -> BraviaClient {
        BraviaClient(
            host: "192.168.1.50",
            credentials: credentials,
            clientID: "Pult:TEST",
            nickname: "Test",
            transport: transport,
            now: { clock.now },
            onCredentialsChange: onChange
        )
    }

    // MARK: JSON-RPC

    func testRPCRequestShapeAndPSKHeader() async throws {
        let transport = MockTransport { _ in .result([["status": "active"]]) }
        let client = makeClient(transport, credentials: .psk("0000"))

        let status = try await client.powerStatus()

        XCTAssertEqual(status, .active)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "http://192.168.1.50/sony/system")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Auth-PSK"), "0000")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        let body = try XCTUnwrap(request.jsonBody)
        XCTAssertEqual(body["method"] as? String, "getPowerStatus")
        XCTAssertEqual(body["version"] as? String, "1.0")
        XCTAssertEqual((body["params"] as? [Any])?.count, 0)
        XCTAssertNotNil(body["id"] as? Int)
    }

    func testCookieHeaderForPinCredentials() async throws {
        let transport = MockTransport { _ in .result([]) }
        let client = makeClient(transport, credentials: .pin(pin: "1234", cookie: "abc", issuedAt: Date()))

        try await client.setPower(true)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "auth=abc")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Auth-PSK"))
        let params = try XCTUnwrap(request.jsonBody?["params"] as? [[String: Any]])
        XCTAssertEqual(params.first?["status"] as? Bool, true)
    }

    func testErrorMapping() async {
        let cases: [(MockResponse, BraviaError)] = [
            (.error(403, "Forbidden", status: 403), .unauthorized),
            (.error(401, "Unauthorized", status: 401), .unauthorized),
            (.error(40005, "Display Is Turned off"), .displayOff),
            (.error(7, "not power-on"), .displayOff),
            (.error(12, "No Such Method"), .unsupported),
            (.error(14, "Unsupported Version"), .unsupported),
            (MockResponse(status: 404), .unsupported),
            (.error(41400, "Some app error"), .tv(code: 41400, message: "Some app error")),
            (MockResponse(status: 200, body: Data("<html>".utf8)), .invalidResponse),
        ]
        for (response, expected) in cases {
            let client = makeClient(MockTransport { _ in response })
            do {
                _ = try await client.powerStatus()
                XCTFail("Expected \(expected)")
            } catch {
                XCTAssertEqual(error as? BraviaError, expected, "for \(response.status) \(String(decoding: response.body, as: UTF8.self))")
            }
        }
    }

    func testURLErrorsMapToReachability() async {
        let timeout = makeClient(MockTransport { _ in throw URLError(.timedOut) })
        do {
            _ = try await timeout.powerStatus()
            XCTFail("Expected error")
        } catch {
            XCTAssertEqual(error as? BraviaError, .unreachable)
        }

        let denied = makeClient(MockTransport { _ in throw URLError(.notConnectedToInternet) })
        do {
            _ = try await denied.powerStatus()
            XCTFail("Expected error")
        } catch {
            XCTAssertEqual(error as? BraviaError, .localNetworkDenied)
        }
    }

    func testSendTextMapsIllegalStateToKeyboardInactive() async throws {
        let transport = MockTransport { _ in .error(7, "Illegal State") }
        let client = makeClient(transport, credentials: .psk("0000"))
        do {
            try await client.sendText("hello")
            XCTFail("Expected error")
        } catch {
            XCTAssertEqual(error as? BraviaError, .keyboardInactive)
        }
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.path, "/sony/appControl")
        XCTAssertEqual(request.jsonBody?["params"] as? [String], ["hello"])
    }

    // MARK: Typed parsing

    func testParsesApplicationsInputsAndSystemInfo() async throws {
        let transport = MockTransport { request in
            switch request.rpcMethod {
            case "getApplicationList":
                return .result([[
                    ["title": "YouTube", "uri": "com.sony.dtv.youtube", "icon": "http://192.168.1.50/icon.png"],
                    ["title": "", "uri": "com.sony.dtv.noname", "icon": ""],
                    ["title": "Broken", "uri": ""],
                ]])
            case "getCurrentExternalInputsStatus":
                return .result([[
                    ["uri": "extInput:hdmi?port=2", "title": "HDMI 2", "label": "PS4", "connection": true, "icon": "meta:hdmi"],
                ]])
            case "getSystemInformation":
                return .result([["model": "KD-55X8507C", "name": "BRAVIA", "macAddr": "fc:f1:52:00:11:22"]])
            case "getSystemSupportedFunction":
                return .result([[["option": "WOL", "value": "FC:F1:52:00:11:22"]]])
            default:
                return .error(12, "No Such Method")
            }
        }
        let client = makeClient(transport, credentials: .psk("0000"))

        let apps = try await client.applications()
        XCTAssertEqual(apps.map(\.title), ["YouTube", "com.sony.dtv.noname"])
        XCTAssertEqual(apps.first?.iconURL?.absoluteString, "http://192.168.1.50/icon.png")
        XCTAssertNil(apps.last?.iconURL)

        let inputs = try await client.externalInputs()
        XCTAssertEqual(inputs.first?.displayName, "HDMI 2 — PS4")
        XCTAssertEqual(inputs.first?.hdmiPort, 2)
        XCTAssertEqual(inputs.first?.isConnected, true)

        let info = try await client.systemInformation()
        XCTAssertEqual(info.model, "KD-55X8507C")
        XCTAssertEqual(info.macAddress, "fc:f1:52:00:11:22")

        let mac = try await client.wakeOnLANMACAddress()
        XCTAssertEqual(mac, "FC:F1:52:00:11:22")
    }

    // MARK: PIN pairing

    func testPinPairingFlow() async throws {
        let changes = CredentialsRecorder()
        let clock = TestClock()
        let transport = MockTransport { request in
            guard request.path == "/sony/accessControl" else { return .error(12, "No Such Method") }
            if request.value(forHTTPHeaderField: "Authorization") == nil {
                return .error(401, "Unauthorized", status: 401)
            }
            return MockResponse(
                status: 200,
                body: try! JSONSerialization.data(withJSONObject: ["result": [], "id": 1]),
                headers: ["Set-Cookie": "auth=9f3c1a; Path=/sony/; Max-Age=1209600; Expires=Sat, 28 Nov 2026 18:00:00 GMT+00:00"]
            )
        }
        let client = makeClient(transport, clock: clock, onChange: { changes.append($0) })

        let start = try await client.startPairing()
        XCTAssertEqual(start, .pinShown)

        try await client.completePairing(pin: " 1234 ")

        let credentials = await client.credentials
        XCTAssertEqual(credentials, .pin(pin: "1234", cookie: "9f3c1a", issuedAt: clock.now))
        XCTAssertEqual(changes.values, [credentials])

        let requests = transport.requests
        XCTAssertEqual(requests.count, 2)
        let authorization = requests[1].value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(authorization, "Basic " + Data(":1234".utf8).base64EncodedString())
        let params = try XCTUnwrap(requests[0].jsonBody?["params"] as? [Any])
        let registration = try XCTUnwrap(params.first as? [String: Any])
        XCTAssertEqual(registration["clientid"] as? String, "Pult:TEST")
        XCTAssertEqual(registration["nickname"] as? String, "Test")
        XCTAssertEqual(registration["level"] as? String, "private")
        let functions = try XCTUnwrap(params.last as? [[String: Any]])
        XCTAssertEqual(functions.first?["function"] as? String, "WOL")
    }

    func testWrongPinAndInvalidPin() async {
        let client = makeClient(MockTransport { _ in .error(401, "Unauthorized", status: 401) })
        do {
            try await client.completePairing(pin: "9999")
            XCTFail("Expected error")
        } catch {
            XCTAssertEqual(error as? BraviaError, .wrongPIN)
        }
        do {
            try await client.completePairing(pin: "12a4")
            XCTFail("Expected error")
        } catch {
            guard case BraviaError.invalidInput = error else { return XCTFail("Unexpected \(error)") }
        }
    }

    func testPairingRejectedWhenTVForbids() async {
        let client = makeClient(MockTransport { _ in .error(403, "Forbidden", status: 403) })
        do {
            _ = try await client.startPairing()
            XCTFail("Expected error")
        } catch {
            XCTAssertEqual(error as? BraviaError, .pairingRejected)
        }
    }

    func testCookieParsingHandlesFoldedHeaders() {
        let response = HTTPURLResponse(
            url: URL(string: "http://tv/sony/accessControl")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["set-cookie": "other=1; Path=/, auth=XYZ==; Path=/sony/; Expires=Sat, 28 Nov 2026"]
        )!
        XCTAssertEqual(BraviaClient.authCookie(from: response), "XYZ==")

        let none = HTTPURLResponse(url: URL(string: "http://tv")!, statusCode: 200, httpVersion: nil, headerFields: [:])!
        XCTAssertNil(BraviaClient.authCookie(from: none))
    }

    // MARK: Cookie renewal

    func testRenewsCookieOn403AndRetriesOnce() async throws {
        let changes = CredentialsRecorder()
        let transport = MockTransport { request in
            if request.path == "/sony/accessControl" {
                return MockResponse(status: 200, body: Data(#"{"result":[],"id":1}"#.utf8), headers: ["Set-Cookie": "auth=new; Path=/sony/"])
            }
            if request.value(forHTTPHeaderField: "Cookie") == "auth=new" {
                return .result([["status": "standby"]])
            }
            return .error(403, "Forbidden", status: 403)
        }
        let client = makeClient(transport, credentials: .pin(pin: "1234", cookie: "old", issuedAt: Date()), onChange: { changes.append($0) })

        let status = try await client.powerStatus()

        XCTAssertEqual(status, .standby)
        XCTAssertEqual(transport.requests.map(\.path), ["/sony/system", "/sony/accessControl", "/sony/system"])
        if case .pin(_, let cookie, _) = await client.credentials {
            XCTAssertEqual(cookie, "new")
        } else {
            XCTFail("Expected pin credentials")
        }
        XCTAssertEqual(changes.values.count, 1)
    }

    func testDoesNotLoopWhenRenewalFails() async {
        let transport = MockTransport { _ in .error(403, "Forbidden", status: 403) }
        let client = makeClient(transport, credentials: .pin(pin: "1234", cookie: "old", issuedAt: Date()))
        do {
            _ = try await client.powerStatus()
            XCTFail("Expected error")
        } catch {
            XCTAssertEqual(error as? BraviaError, .unauthorized)
        }
        XCTAssertEqual(transport.requests.map(\.path), ["/sony/system", "/sony/accessControl"])
    }

    func testPSKFailureDoesNotTryRenewal() async {
        let transport = MockTransport { _ in .error(403, "Forbidden", status: 403) }
        let client = makeClient(transport, credentials: .psk("bad"))
        do {
            _ = try await client.systemInformation()
            XCTFail("Expected error")
        } catch {
            XCTAssertEqual(error as? BraviaError, .unauthorized)
        }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testRenewIfNeededOnlyForStaleCookie() async {
        let clock = TestClock()
        let transport = MockTransport { _ in
            MockResponse(status: 200, body: Data(#"{"result":[],"id":1}"#.utf8), headers: ["Set-Cookie": "auth=fresh"])
        }
        let client = makeClient(transport, credentials: .pin(pin: "1234", cookie: "c", issuedAt: clock.now), clock: clock)

        await client.renewIfNeeded()
        XCTAssertTrue(transport.requests.isEmpty)

        clock.advance(8 * 24 * 3600)
        await client.renewIfNeeded()
        XCTAssertEqual(transport.requests.map(\.path), ["/sony/accessControl"])
        let renewed = await client.credentials
        XCTAssertEqual(renewed, .pin(pin: "1234", cookie: "fresh", issuedAt: clock.now))
    }

    // MARK: IRCC

    func testIRCCRequestFormat() async throws {
        let transport = MockTransport { _ in .ok }
        let client = makeClient(transport, credentials: .psk("0000"))

        try await client.send(.home, keymap: IRCCKeymap())

        // First command after idle is preceded by an empty "wake" code.
        let requests = transport.requests
        XCTAssertEqual(requests.map(\.irccCode), ["", "AAAAAQAAAAEAAABgAw=="])
        let request = requests[1]
        XCTAssertEqual(request.url?.absoluteString, "http://192.168.1.50/sony/IRCC")
        XCTAssertEqual(request.value(forHTTPHeaderField: "SOAPACTION"), "\"urn:schemas-sony-com:service:IRCC:1#X_SendIRCC\"")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "text/xml; charset=UTF-8")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Auth-PSK"), "0000")
        XCTAssertTrue(request.bodyString.contains(#"<u:X_SendIRCC xmlns:u="urn:schemas-sony-com:service:IRCC:1">"#))
        XCTAssertTrue(request.bodyString.hasPrefix("<?xml version=\"1.0\"?><s:Envelope"))
    }

    func testIRCCWakeOnlyAfterIdle() async throws {
        let clock = TestClock()
        let transport = MockTransport { _ in .ok }
        let client = makeClient(transport, credentials: .psk("0000"), clock: clock)

        try await client.send(.up, keymap: IRCCKeymap())
        try await client.send(.down, keymap: IRCCKeymap())
        clock.advance(11 * 60)
        try await client.send(.left, keymap: IRCCKeymap())

        XCTAssertEqual(transport.requests.map(\.irccCode), [
            "", RemoteKey.up.fallbackCode,
            RemoteKey.down.fallbackCode,
            "", RemoteKey.left.fallbackCode,
        ])
    }

    func testIRCCWakeRejectionIsIgnored() async throws {
        let transport = MockTransport { request in
            request.irccCode == "" ? MockResponse(status: 500) : .ok
        }
        let client = makeClient(transport, credentials: .psk("0000"))
        try await client.send(.confirm, keymap: IRCCKeymap())
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testIRCCSwitchesPathCaseOn404AndRemembersIt() async throws {
        let transport = MockTransport { request in
            request.path == "/sony/ircc" ? .ok : MockResponse(status: 404)
        }
        let client = makeClient(transport, credentials: .psk("0000"))

        try await client.send(.up, keymap: IRCCKeymap())
        try await client.send(.down, keymap: IRCCKeymap())

        // wake (current path, result ignored) → key on /sony/IRCC (404) → /sony/ircc (ok, remembered) → next key
        XCTAssertEqual(transport.requests.map(\.path), ["/sony/IRCC", "/sony/IRCC", "/sony/ircc", "/sony/ircc"])
    }

    func testIRCCErrors() async {
        let rejected = makeClient(MockTransport { request in request.irccCode == "" ? .ok : MockResponse(status: 500) })
        do {
            try await rejected.send(.up, keymap: IRCCKeymap())
            XCTFail("Expected error")
        } catch {
            XCTAssertEqual(error as? BraviaError, .keyRejected)
        }

        let forbidden = makeClient(MockTransport { _ in MockResponse(status: 403) }, credentials: .psk("x"))
        do {
            try await forbidden.send(.up, keymap: IRCCKeymap())
            XCTFail("Expected error")
        } catch {
            XCTAssertEqual(error as? BraviaError, .unauthorized)
        }

        let unreachable = MockTransport { _ in throw URLError(.timedOut) }
        let offline = makeClient(unreachable)
        do {
            try await offline.send(.up, keymap: IRCCKeymap())
            XCTFail("Expected error")
        } catch {
            XCTAssertEqual(error as? BraviaError, .unreachable)
        }
        // A wake-up timeout is tolerated (slow TV), so the real key is still tried once.
        XCTAssertEqual(unreachable.requests.count, 2)
    }

    func testIRCCRejectsNonBase64Codes() async {
        let transport = MockTransport()
        let client = makeClient(transport)
        do {
            try await client.sendIRCC("</IRCCCode><evil/>")
            XCTFail("Expected error")
        } catch {
            guard case BraviaError.invalidInput = error else { return XCTFail("Unexpected \(error)") }
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testSlowCommandIsNotOvertakenByNextOne() async throws {
        let completed = StringRecorder()
        let slowCode = RemoteKey.num1.fallbackCode
        let transport = MockTransport { request in
            let code = request.irccCode ?? ""
            if code == slowCode { usleep(300_000) }
            if !code.isEmpty { completed.append(code) }
            return .ok
        }
        let client = makeClient(transport, credentials: .psk("0000"))

        let first = Task { try await client.send(.num1, keymap: IRCCKeymap()) }
        // Wait until the slow request is in flight before sending the next key.
        while !transport.requests.contains(where: { $0.irccCode == slowCode }) {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let second = Task { try await client.send(.num2, keymap: IRCCKeymap()) }
        try await first.value
        try await second.value

        XCTAssertEqual(completed.values, [slowCode, RemoteKey.num2.fallbackCode])
    }
}

final class StringRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func append(_ value: String) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

final class CredentialsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Credentials] = []

    func append(_ value: Credentials) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }

    var values: [Credentials] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
