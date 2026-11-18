import XCTest
import PultIR
@testable import BraviaKit

// MARK: - Test doubles

@MainActor
final class MockBlasterLink: BlasterLink {
    var onEvent: ((BlasterLinkEvent) -> Void)?
    var connectCalls: [UUID] = []
    var disconnectCount = 0
    var scanStarts = 0
    var scanStops = 0
    var writes: [Data] = []
    var writeError: BlasterLinkError?
    /// Fails only the next write.
    var failNextWrite: BlasterLinkError?
    /// Decides per write (returns an error to fail it).
    var onWrite: ((Data) -> BlasterLinkError?)?
    var maxWriteLength = 244
    /// Emit `.ready` as soon as `connect` is called.
    var readyOnConnect = false

    func startScan() { scanStarts += 1 }
    func stopScan() { scanStops += 1 }

    func connect(id: UUID) {
        connectCalls.append(id)
        if readyOnConnect { emit(.ready) }
    }

    func disconnect() { disconnectCount += 1 }

    func write(_ data: Data) async throws {
        if let failNextWrite {
            self.failNextWrite = nil
            throw failNextWrite
        }
        if let writeError { throw writeError }
        if let error = onWrite?(data) { throw error }
        writes.append(data)
    }

    /// Signals reassembled from PLAY writes, in order.
    var played: [IRSignal] {
        var result: [IRSignal] = []
        var buffer = Data()
        for write in writes where write.first == 0x10 && write.count >= 4 {
            if write[write.startIndex + 3] & 0x7F == 0 { buffer = Data() }
            buffer.append(write.dropFirst(4))
            if write[write.startIndex + 3] & 0x80 != 0, let signal = try? IRSignalBlob.decode(buffer) {
                result.append(signal)
            }
        }
        return result
    }

    /// `(sig_id, count)` of HOLD writes.
    var holds: [[UInt8]] { writes.filter { $0.first == 0x11 }.map { Array($0.dropFirst()) } }

    func emit(_ event: BlasterLinkEvent) { onEvent?(event) }
}

/// Sleeps that last until the test fires them.
actor ManualSleeper {
    private var pending: [(seconds: Double, continuation: CheckedContinuation<Void, Never>)] = []

    func sleep(_ seconds: Double) async {
        await withCheckedContinuation { pending.append((seconds, $0)) }
    }

    var durations: [Double] { pending.map(\.seconds) }

    func fire(_ seconds: Double) {
        let due = pending.filter { $0.seconds == seconds }
        pending.removeAll { $0.seconds == seconds }
        due.forEach { $0.continuation.resume() }
    }
}

func irSignal(_ key: RemoteKey) -> IRSignal {
    irSignal(SIRCCode(ircc: key.fallbackCode)!)
}

func irSignal(_ code: SIRCCode) -> IRSignal {
    IRCodecs.signal(for: .code(code.irCode), toggle: false)
}

func blasterSignal(_ key: RemoteKey) -> BlasterSignal {
    let code = SIRCCode(ircc: key.fallbackCode)!
    return BlasterSignal(signal: irSignal(code), legacy: code)
}

@MainActor
func eventually(_ condition: @MainActor () async -> Bool) async -> Bool {
    for _ in 0..<2000 {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}

// MARK: - SIRC codes

final class SIRCCodeTests: XCTestCase {
    /// Same vectors as firmware/PROTOCOL.md and firmware/tests/host.
    func testProtocolVectors() {
        let vectors: [(String, SIRCCode.Bits, UInt16, UInt8, UInt32)] = [
            ("AAAAAQAAAAEAAAAVAw==", .b12, 1, 21, 0xA90),   // Power
            ("AAAAAQAAAAEAAAAuAw==", .b12, 1, 46, 0x750),   // WakeUp
            ("AAAAAQAAAAEAAAAvAw==", .b12, 1, 47, 0xF50),   // PowerOff
            ("AAAAAQAAAAEAAAAAAw==", .b12, 1, 0, 0x010),    // Num1
            ("AAAAAQAAAAEAAAASAw==", .b12, 1, 18, 0x490),   // VolumeUp
            ("AAAAAgAAAJcAAAAjAw==", .b15, 151, 35, 0x62E9), // Back
            ("AAAAAgAAAJcAAAA2Aw==", .b15, 151, 54, 0x36E9), // Options
            ("AAAAAgAAABoAAABaAw==", .b15, 26, 90, 0x2D58),  // Hdmi1
        ]
        for (ircc, bits, device, command, value) in vectors {
            let code = SIRCCode(ircc: ircc)
            XCTAssertEqual(code?.bits, bits, ircc)
            XCTAssertEqual(code?.device, device, ircc)
            XCTAssertEqual(code?.command, command, ircc)
            XCTAssertEqual(code?.transmissionValue, value, ircc)
        }
    }

    func testEveryFallbackCodeIsTransmittable() {
        for key in RemoteKey.allCases {
            XCTAssertNotNil(SIRCCode(ircc: key.fallbackCode), "\(key)")
        }
    }

    func testRejectsMalformedCodes() {
        func ircc(type: UInt32, device: UInt32, command: UInt32, tail: [UInt8] = [3]) -> String {
            var bytes: [UInt8] = []
            for word in [type, device, command] {
                bytes += [UInt8(word >> 24 & 0xFF), UInt8(word >> 16 & 0xFF), UInt8(word >> 8 & 0xFF), UInt8(word & 0xFF)]
            }
            return Data(bytes + tail).base64EncodedString()
        }
        XCTAssertNil(SIRCCode(ircc: ""))
        XCTAssertNil(SIRCCode(ircc: "not base64!"))
        XCTAssertNil(SIRCCode(ircc: ircc(type: 1, device: 1, command: 21, tail: [])))   // 12 bytes
        XCTAssertNil(SIRCCode(ircc: ircc(type: 4, device: 1, command: 21)))              // unknown type
        XCTAssertNil(SIRCCode(ircc: ircc(type: 1, device: 1, command: 128)))             // 8-bit command
        XCTAssertNil(SIRCCode(ircc: ircc(type: 1, device: 32, command: 1)))              // device > 5 bits
        XCTAssertNil(SIRCCode(ircc: ircc(type: 2, device: 256, command: 1)))             // device > 8 bits
        XCTAssertNotNil(SIRCCode(ircc: ircc(type: 3, device: 0x1FFF, command: 127)))     // 20-bit maximum
        XCTAssertNil(SIRCCode(ircc: ircc(type: 3, device: 0x2000, command: 1)))
    }

    func testTwentyBitCodeSendsDeviceThenExtended() {
        // device5 = 0b00001, extended = 0b10000000 → device field 0x1001
        let code = SIRCCode(bits: .b20, device: 0x1001, command: 0)!
        // 7 zero command bits, device LSB first 1,0,0,0,0, extended LSB first 0×7,1
        XCTAssertEqual(code.transmissionValue, 0b0000000_10000_00000001)
    }
}

// MARK: - Wire format

final class BlasterProtocolTests: XCTestCase {
    func testSendEncoding() {
        let power = SIRCCode(ircc: RemoteKey.power.fallbackCode)!
        XCTAssertEqual([UInt8](BlasterProtocol.send(power)), [0x01, 0x00, 12, 0x01, 0x00, 21, 3])

        let back = SIRCCode(ircc: RemoteKey.back.fallbackCode)!
        XCTAssertEqual([UInt8](BlasterProtocol.send(back, hold: true)), [0x01, 0x01, 15, 0x97, 0x00, 35, 3])

        let extended = SIRCCode(bits: .b20, device: 0x1F3, command: 5)!
        XCTAssertEqual([UInt8](BlasterProtocol.send(extended, frames: 50)), [0x01, 0x00, 20, 0xF3, 0x01, 5, 20])
        XCTAssertEqual(BlasterProtocol.send(extended, frames: 0).last, 3)
    }

    func testControlCommands() {
        XCTAssertEqual([UInt8](BlasterProtocol.stop), [0x02])
        XCTAssertEqual([UInt8](BlasterProtocol.enterBootloader), [0xF0, 0x55, 0xAA])
    }

    func testProtocolTwoStatus() {
        let status = BlasterStatus(data: Data([2, 0b11000, 0, 0, 8, 0, 1, 0, 0b1011, 0x40, 0x02, 0]))
        XCTAssertEqual(status?.supportsPlay, true)
        XCTAssertEqual(status?.isLearning, true)
        XCTAssertEqual(status?.isExternallyPowered, true)
        XCTAssertEqual(status?.capabilities, [.play, .learn, .uf2Bootloader])
        XCTAssertEqual(status?.maxBlob, 576)
        XCTAssertNil(BlasterStatus(data: Data([1, 0, 0, 0, 0, 0, 0, 0]))?.capabilities)
    }

    func testStatusParsing() {
        let status = BlasterStatus(data: Data([1, 0b101, 0xB8, 0x0B, 7, 0x81, 0x2C, 0x01]))
        XCTAssertEqual(status?.protocolVersion, 1)
        XCTAssertEqual(status?.isTransmitting, true)
        XCTAssertEqual(status?.isPairingWindowOpen, false)
        XCTAssertEqual(status?.isBatteryLow, true)
        XCTAssertEqual(status?.batteryMillivolts, 3000)
        XCTAssertEqual(status?.queueFree, 7)
        XCTAssertEqual(status?.lastError, 0x81)
        XCTAssertEqual(status?.uptimeMinutes, 300)
        XCTAssertNil(BlasterStatus(data: Data([1, 0, 0])))
    }
}

// MARK: - Session

@MainActor
final class BlasterSessionTests: XCTestCase {
    private let bridge = DiscoveredBlaster(id: UUID(), name: "Pult IR", rssi: -50)
    private let power = SIRCCode(ircc: RemoteKey.power.fallbackCode)!

    private func makeStore(paired: Bool) -> TVStore {
        let suite = "PultBlasterTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = TVStore(defaults: defaults, secrets: MemorySecretStore())
        if paired { store.savedBlaster = SavedBlaster(id: bridge.id, name: bridge.name) }
        return store
    }

    private func makeSession(paired: Bool = true, sleeper: ManualSleeper = ManualSleeper())
        -> (BlasterSession, MockBlasterLink, TVStore) {
        let link = MockBlasterLink()
        let store = makeStore(paired: paired)
        let session = BlasterSession(link: link, store: store, sleep: { await sleeper.sleep($0) })
        return (session, link, store)
    }

    private func readySession(sleeper: ManualSleeper = ManualSleeper()) -> (BlasterSession, MockBlasterLink) {
        let (session, link, _) = makeSession(sleeper: sleeper)
        session.activate()
        link.emit(.ready)
        return (session, link)
    }

    func testActivateConnectsSavedBridgeAndSendsOnceReady() async throws {
        let (session, link, _) = makeSession()
        session.activate()
        XCTAssertEqual(link.connectCalls, [bridge.id])
        XCTAssertEqual(session.connection, .connecting)

        link.emit(.ready)
        XCTAssertEqual(session.connection, .ready)
        try await session.send(power)
        XCTAssertEqual(link.played, [irSignal(power)])
    }

    func testFirstPressWaitsForTheLink() async throws {
        let (session, link, _) = makeSession()
        session.activate()
        let send = Task { try await session.send(power) }
        let connecting = await eventually { link.connectCalls.count == 1 }
        XCTAssertTrue(connecting)
        XCTAssertTrue(link.writes.isEmpty)

        link.emit(.ready)
        try await send.value
        XCTAssertEqual(link.played, [irSignal(power)])
    }

    func testPressFailsWhenBridgeDoesNotAppear() async {
        let sleeper = ManualSleeper()
        let (session, _, _) = makeSession(sleeper: sleeper)
        session.activate()
        let send = Task { try await session.send(power) }
        let waiting = await eventually { await sleeper.durations.contains(BlasterSession.readyTimeout) }
        XCTAssertTrue(waiting)

        await sleeper.fire(BlasterSession.readyTimeout)
        do {
            try await send.value
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? BlasterError, .unreachable)
        }
    }

    func testPressWithoutPairedBridge() async {
        let (session, link, _) = makeSession(paired: false)
        do {
            try await session.send(power)
            XCTFail("expected notPaired")
        } catch {
            XCTAssertEqual(error as? BlasterError, .notPaired)
        }
        XCTAssertTrue(link.connectCalls.isEmpty)
    }

    func testBluetoothOffFailsImmediately() async {
        let (session, link, _) = makeSession()
        link.emit(.availability(.poweredOff))
        do {
            try await session.send(power)
            XCTFail("expected bluetoothOff")
        } catch {
            XCTAssertEqual(error as? BlasterError, .bluetoothOff)
        }
    }

    func testBluetoothTurningOffDropsReadyState() {
        let (session, link) = readySession()
        link.emit(.availability(.poweredOff))
        XCTAssertEqual(session.connection, .idle)

        link.emit(.availability(.poweredOn))
        XCTAssertEqual(session.connection, .connecting)
        XCTAssertEqual(link.connectCalls.count, 2)
    }

    func testDeactivateReleasesTheBridgeWithoutReconnecting() {
        let (session, link) = readySession()
        session.deactivate()
        XCTAssertEqual(link.disconnectCount, 1)
        XCTAssertEqual(session.connection, .idle)

        link.emit(.disconnected(nil))
        XCTAssertEqual(link.connectCalls.count, 1)
    }

    func testUnexpectedDisconnectReconnects() {
        let (session, link) = readySession()
        link.emit(.disconnected(.failed("link lost")))
        XCTAssertEqual(session.connection, .connecting)
        XCTAssertEqual(link.connectCalls.count, 2)
    }

    func testLostBondNeedsRepair() async {
        let (session, link) = readySession()
        var errors: [BlasterError] = []
        session.onError = { errors.append($0) }

        link.emit(.disconnected(.peerRemovedPairing))
        XCTAssertTrue(session.needsRepair)
        XCTAssertEqual(errors, [.needsRepair])
        XCTAssertEqual(link.connectCalls.count, 1)
        do {
            try await session.send(power)
            XCTFail("expected needsRepair")
        } catch {
            XCTAssertEqual(error as? BlasterError, .needsRepair)
        }
    }

    func testRejectedPairingIsReportedAndNotRetried() {
        let (session, link, _) = makeSession(paired: false)
        var errors: [BlasterError] = []
        session.onError = { errors.append($0) }

        session.pair(bridge)
        link.emit(.disconnected(.pairingFailed))
        XCTAssertEqual(errors, [.pairingFailed])
        XCTAssertEqual(session.connection, .idle)
        XCTAssertEqual(link.connectCalls.count, 1)
    }

    func testScanListsBridgesAndPairingSavesTheChoice() {
        let (session, link, store) = makeSession(paired: false)
        link.emit(.discovered(bridge)) // not scanning yet: ignored
        XCTAssertTrue(session.discovered.isEmpty)

        session.startScan()
        link.emit(.discovered(bridge))
        var closer = bridge
        closer.rssi = -40
        link.emit(.discovered(closer))
        XCTAssertEqual(session.discovered, [closer])

        session.pair(closer)
        XCTAssertFalse(session.isScanning)
        XCTAssertEqual(link.scanStops, 1)
        XCTAssertEqual(link.connectCalls, [bridge.id])
        XCTAssertNil(store.savedBlaster, "saved only once the first connection succeeds")
        XCTAssertEqual(session.pairingCandidate?.id, bridge.id)

        link.emit(.ready)
        XCTAssertEqual(store.savedBlaster, SavedBlaster(id: bridge.id, name: "Pult IR"))
        XCTAssertEqual(session.saved, store.savedBlaster)
        XCTAssertNil(session.pairingCandidate)
    }

    func testPairingDroppedByTheBridgeIsReported() {
        let (session, link, store) = makeSession(paired: false)
        var errors: [BlasterError] = []
        session.onError = { errors.append($0) }

        session.pair(bridge)
        link.emit(.disconnected(.failed("dropped")))
        XCTAssertEqual(errors, [.pairingFailed])
        XCTAssertNil(session.pairingCandidate)
        XCTAssertNil(store.savedBlaster)
    }

    func testPairingTimesOut() async {
        let sleeper = ManualSleeper()
        let (session, link, _) = makeSession(paired: false, sleeper: sleeper)
        var errors: [BlasterError] = []
        session.onError = { errors.append($0) }

        session.pair(bridge)
        let waiting = await eventually { await sleeper.durations.contains(BlasterSession.pairingTimeout) }
        XCTAssertTrue(waiting)
        await sleeper.fire(BlasterSession.pairingTimeout)
        let failed = await eventually { errors == [.pairingFailed] }
        XCTAssertTrue(failed)
        XCTAssertEqual(session.connection, .idle)
        XCTAssertNil(session.pairingCandidate)
        XCTAssertGreaterThanOrEqual(link.disconnectCount, 2) // drop before pairing + on timeout
    }

    func testPressesQueuedWhileConnectingKeepTheirOrder() async throws {
        let (session, link, _) = makeSession()
        session.activate()
        let digits = (0...5).map { SIRCCode(ircc: RemoteKey.digit($0)!.fallbackCode)! }
        var tasks: [Task<Void, Error>] = []
        for digit in digits {
            tasks.append(Task { try await session.send(digit) })
            await Task.yield()
        }
        for _ in 0..<20 { await Task.yield() }
        link.emit(.ready)
        for task in tasks { try await task.value }
        XCTAssertEqual(link.played, digits.map { irSignal($0) })
        XCTAssertEqual(link.writes.map { $0[2] }, [1, 2, 3, 4, 5, 6], "a new sig_id per press")
    }

    func testPressesQueuedBehindATimeoutFailFast() async {
        let sleeper = ManualSleeper()
        let (session, _, _) = makeSession(sleeper: sleeper)
        session.activate()
        let first = Task { try await session.send(power) }
        let second = Task { try await session.send(power) }
        let waiting = await eventually { await sleeper.durations.contains(BlasterSession.readyTimeout) }
        XCTAssertTrue(waiting)
        await sleeper.fire(BlasterSession.readyTimeout)

        for task in [first, second] {
            do {
                try await task.value
                XCTFail("expected unreachable")
            } catch {
                XCTAssertEqual(error as? BlasterError, .unreachable)
            }
        }
        let readyWaits = await sleeper.durations.filter { $0 == BlasterSession.readyTimeout }
        XCTAssertTrue(readyWaits.isEmpty, "the second press must not wait again")
    }

    func testOwnDisconnectAlwaysReachesTheAdapter() {
        let (session, link) = readySession()
        link.emit(.availability(.poweredOff))
        XCTAssertEqual(session.connection, .idle)
        session.deactivate()
        XCTAssertEqual(link.disconnectCount, 1)
    }

    func testReadyWhileIdleIsKeptOnlyWhenWanted() {
        let (session, link, _) = makeSession()
        link.emit(.ready) // not active: release it
        XCTAssertEqual(session.connection, .idle)
        XCTAssertEqual(link.disconnectCount, 1)

        session.activate()
        link.emit(.disconnected(.failed("first attempt failed")))
        XCTAssertEqual(session.connection, .idle, "a failed attempt is not retried in a loop")
        link.emit(.ready) // the link came up anyway
        XCTAssertEqual(session.connection, .ready)
        XCTAssertEqual(link.disconnectCount, 1)
    }

    func testFailedWriteMarksLinkLostAndReconnects() async {
        let (session, link) = readySession()
        link.writeError = .notConnected
        do {
            try await session.send(power)
            XCTFail("expected unreachable")
        } catch {
            XCTAssertEqual(error as? BlasterError, .unreachable)
        }
        XCTAssertEqual(session.connection, .connecting)
        XCTAssertEqual(link.connectCalls.count, 2)
    }

    func testBluetoothResetDropsTheLink() {
        let (session, link) = readySession()
        link.emit(.availability(.poweredOn))
        link.emit(.availability(.unknown)) // CBManagerState.resetting
        XCTAssertEqual(session.connection, .idle)
        link.emit(.availability(.poweredOn))
        XCTAssertEqual(session.connection, .connecting)
    }

    func testForgettingDuringAWaitCancelsQuietly() async {
        let (session, _, _) = makeSession()
        session.activate()
        let send = Task { try await session.send(power) }
        for _ in 0..<20 { await Task.yield() }
        session.forget()
        do {
            try await send.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testBootloaderAcceptsTheBridgeRebooting() async throws {
        let (session, link) = readySession()
        link.writeError = .timeout
        try await session.enterBootloader()
        XCTAssertEqual(session.connection, .idle)
        XCTAssertEqual(link.connectCalls.count, 1)
    }

    func testLostBondIsRetriedAfterReturningFromBackground() {
        let (session, link) = readySession()
        link.emit(.disconnected(.peerRemovedPairing))
        XCTAssertTrue(session.needsRepair)
        session.deactivate()
        session.activate()
        XCTAssertFalse(session.needsRepair)
        XCTAssertEqual(session.connection, .connecting)
    }

    func testBridgeRejectionsMapToUserErrors() async {
        let (session, link) = readySession()
        link.writeError = .rejected(BlasterRejection.queueFull.rawValue)
        do {
            try await session.send(power)
            XCTFail("expected busy")
        } catch {
            XCTAssertEqual(error as? BlasterError, .busy)
        }
        link.writeError = .rejected(BlasterRejection.malformed.rawValue)
        do {
            try await session.send(power)
            XCTFail("expected rejected")
        } catch {
            XCTAssertEqual(error as? BlasterError, .rejected)
        }
    }

    func testIdleLinkIsDropped() async throws {
        let sleeper = ManualSleeper()
        let (session, link) = readySession(sleeper: sleeper)
        try await session.send(power)
        let scheduled = await eventually { await sleeper.durations.contains(BlasterSession.idleTimeout) }
        XCTAssertTrue(scheduled)

        await sleeper.fire(BlasterSession.idleTimeout)
        let dropped = await eventually { session.connection == .idle }
        XCTAssertTrue(dropped)
        XCTAssertEqual(link.disconnectCount, 1)
        XCTAssertEqual(link.connectCalls.count, 1)
    }

    func testLocateAlternatesVolumeKeysUntilStopped() async {
        let sleeper = ManualSleeper()
        let (session, link) = readySession(sleeper: sleeper)
        let up = irSignal(.volumeUp)
        let down = irSignal(.volumeDown)

        session.startLocate(up: blasterSignal(.volumeUp), down: blasterSignal(.volumeDown))
        let first = await eventually { link.played == [up] }
        XCTAssertTrue(first)
        let sleeping = await eventually { await sleeper.durations.contains(BlasterSession.locateInterval) }
        XCTAssertTrue(sleeping)
        await sleeper.fire(BlasterSession.locateInterval)
        let second = await eventually { link.played == [up, down] }
        XCTAssertTrue(second)
        let sleepingAgain = await eventually { await sleeper.durations.contains(BlasterSession.locateInterval) }
        XCTAssertTrue(sleepingAgain)

        session.stopLocate()
        XCTAssertFalse(session.isLocating)
        await sleeper.fire(BlasterSession.locateInterval)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(link.played, [up, down])
    }

    func testLocateStepsBackAfterStoppingOnLouder() async {
        let sleeper = ManualSleeper()
        let (session, link) = readySession(sleeper: sleeper)
        let up = irSignal(.volumeUp)
        let down = irSignal(.volumeDown)

        session.startLocate(up: blasterSignal(.volumeUp), down: blasterSignal(.volumeDown))
        let first = await eventually { link.played == [up] }
        XCTAssertTrue(first)
        let sleeping = await eventually { await sleeper.durations.contains(BlasterSession.locateInterval) }
        XCTAssertTrue(sleeping)
        session.stopLocate()
        await sleeper.fire(BlasterSession.locateInterval)
        let stepped = await eventually { link.played == [up, down] }
        XCTAssertTrue(stepped)
    }

    func testHoldExtendsThePressOnAir() async throws {
        let (session, link) = readySession()
        try await session.send(power)
        try await session.send(power, hold: true)
        XCTAssertEqual(link.played, [irSignal(power)])
        XCTAssertEqual(link.holds, [[1, 5]], "SIRC: ceil(180 / 45) + 1 = 5 units")
    }

    func testHoldWithoutAPressOnAirStartsANewOne() async throws {
        let (session, link) = readySession()
        try await session.send(power)
        link.failNextWrite = .rejected(BlasterRejection.nothingToHold.rawValue)
        try await session.send(power, hold: true)
        XCTAssertEqual(link.played, [irSignal(power), irSignal(power)])
        XCTAssertEqual(link.writes.last?[2], 2)
    }

    func testHoldForAnotherKeyIsANewPress() async throws {
        let (session, link) = readySession()
        try await session.send(power)
        try await session.send(blasterSignal(.volumeUp), hold: true)
        XCTAssertEqual(link.played, [irSignal(power), irSignal(.volumeUp)])
        XCTAssertTrue(link.holds.isEmpty)
    }

    func testLongSignalsAreFragmented() async throws {
        let (session, link) = readySession()
        link.maxWriteLength = 20
        let nec = IRCodecs.signal(for: .code(IRCode(proto: .nec, address: 0x04, command: 0x08)), toggle: false)
        try await session.send(BlasterSignal(signal: nec), hold: false)
        XCTAssertGreaterThan(link.writes.count, 1)
        XCTAssertTrue(link.writes.allSatisfy { $0.count <= 20 })
        XCTAssertEqual(link.played, [nec])
    }

    func testProtocolOneBridgeGetsLegacySonyCodes() async throws {
        let (session, link) = readySession()
        link.emit(.status(Data([1, 0, 0x94, 0x11, 8, 0, 0, 0])))
        try await session.send(power)
        try await session.send(power, hold: true)
        XCTAssertEqual(link.writes, [
            BlasterProtocol.send(power),
            BlasterProtocol.send(power, frames: BlasterSession.holdFrames, hold: true),
        ])
    }

    func testProtocolOneBridgeCannotPlayOtherBrands() async {
        let (session, link) = readySession()
        link.emit(.status(Data([1, 0, 0x94, 0x11, 8, 0, 0, 0])))
        let nec = IRCodecs.signal(for: .code(IRCode(proto: .nec, address: 0x04, command: 0x08)), toggle: false)
        do {
            try await session.send(BlasterSignal(signal: nec))
            XCTFail("expected firmwareTooOld")
        } catch {
            XCTAssertEqual(error as? BlasterError, .firmwareTooOld)
        }
    }

    func testUnknownBridgeRejectingPlayFallsBackToLegacy() async throws {
        let (session, link) = readySession()
        link.failNextWrite = .rejected(BlasterRejection.malformed.rawValue)
        try await session.send(power)
        XCTAssertEqual(link.writes, [BlasterProtocol.send(power)])
    }

    // MARK: Learning

    private let learnStatus = Data([2, 0, 0x94, 0x11, 8, 0, 0, 0, 0b1011, 0x40, 0x02, 0])
    private let capture = Data([0x07, 0x80, 0x00, 0x06, 0x00, 0xA8, 0x46, 0x94, 0x23, 0xB2, 0x04, 0xB2, 0x04, 0xB2, 0x04, 0xC0, 0xB8, 0x02])

    func testLearningReturnsTheCapturedSignal() async throws {
        let (session, link) = readySession()
        link.emit(.status(learnStatus))
        let learning = Task { try await session.learn(timeoutSeconds: 10) }
        let started = await eventually { link.writes == [BlasterProtocol.learnStart(timeoutSeconds: 10)] }
        XCTAssertTrue(started)
        XCTAssertTrue(session.isLearning)

        link.emit(.capture(capture))
        let result = try await learning.value
        XCTAssertEqual(result, .durations([9000, 4500, 562, 562, 562, 40000], truncated: false))
        XCTAssertFalse(session.isLearning)
    }

    func testLearningNeedsAReceiver() async {
        let (session, link) = readySession()
        link.emit(.status(Data([2, 0, 0x94, 0x11, 8, 0, 0, 0, 0b1001, 0x40, 0x02, 0])))
        do {
            _ = try await session.learn()
            XCTFail("expected noReceiver")
        } catch {
            XCTAssertEqual(error as? BlasterError, .noReceiver)
        }
        XCTAssertTrue(link.writes.isEmpty)
    }

    func testLearningTimesOut() async {
        let sleeper = ManualSleeper()
        let (session, link) = readySession(sleeper: sleeper)
        link.emit(.status(learnStatus))
        let learning = Task { try await session.learn(timeoutSeconds: 10) }
        let waiting = await eventually { await sleeper.durations.contains(13) }
        XCTAssertTrue(waiting)
        await sleeper.fire(13)
        do {
            _ = try await learning.value
            XCTFail("expected learnTimeout")
        } catch {
            XCTAssertEqual(error as? BlasterError, .learnTimeout)
        }
    }

    func testAnEarlierLearnTimerDoesNotEndTheNextLearn() async {
        let sleeper = ManualSleeper()
        let (session, link) = readySession(sleeper: sleeper)
        link.emit(.status(learnStatus))
        let first = Task { try await session.learn(timeoutSeconds: 10) }
        let firstWaiting = await eventually { await sleeper.durations.contains(13) }
        XCTAssertTrue(firstWaiting)
        link.emit(.capture(capture))
        _ = try? await first.value

        let second = Task { try await session.learn(timeoutSeconds: 20) }
        let secondWaiting = await eventually { await sleeper.durations.contains(23) }
        XCTAssertTrue(secondWaiting)
        await sleeper.fire(13) // the first learn's timer
        for _ in 0..<50 { await Task.yield() }
        XCTAssertTrue(session.isLearning, "the second learn is still listening")
        session.cancelLearning()
        _ = try? await second.value
    }

    func testBluetoothOffEndsLearning() async {
        let (session, link) = readySession()
        link.emit(.status(learnStatus))
        let learning = Task { try await session.learn() }
        let started = await eventually { session.isLearning && !link.writes.isEmpty }
        XCTAssertTrue(started)
        link.emit(.availability(.poweredOff))
        do {
            _ = try await learning.value
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? BlasterError, .unreachable)
        }
    }

    func testReleasingTheBridgeInterruptsLearning() async {
        let (session, link) = readySession()
        link.emit(.status(learnStatus))
        let learning = Task { try await session.learn() }
        let started = await eventually { session.isLearning && !link.writes.isEmpty }
        XCTAssertTrue(started)
        session.deactivate()
        do {
            _ = try await learning.value
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? BlasterError, .learnInterrupted)
        }
    }

    func testBootloaderNeedsTheCapability() async {
        let (session, link) = readySession()
        link.emit(.status(Data([2, 0, 0, 0, 8, 0, 0, 0, 0b0011, 0x40, 0x02, 0])))
        XCTAssertFalse(session.hasBootloader)
        do {
            try await session.enterBootloader()
            XCTFail("expected notSupportedByBoard")
        } catch {
            XCTAssertEqual(error as? BlasterError, .notSupportedByBoard)
        }
        XCTAssertTrue(link.writes.isEmpty)
    }

    func testLostReassemblyIsRetriedWithANewPress() async throws {
        let (session, link) = readySession()
        link.emit(.status(learnStatus))
        link.maxWriteLength = 20
        let nec = IRCodecs.signal(for: .code(IRCode(proto: .nec, address: 0x04, command: 0x08)), toggle: false)
        var failures = 0
        link.onWrite = { data in
            if data.first == 0x10, data[3] == 1, failures == 0 {
                failures += 1
                return .rejected(BlasterRejection.malformed.rawValue)
            }
            return nil
        }
        try await session.send(BlasterSignal(signal: nec))
        XCTAssertEqual(link.played, [nec])
        XCTAssertEqual(Set(link.writes.map { $0[2] }), [1, 2], "the retry uses a new sig_id")
    }

    func testLegacyFallbackIsNotStickyOnceStatusArrives() async throws {
        let (session, link) = readySession()
        link.failNextWrite = .rejected(BlasterRejection.malformed.rawValue)
        try await session.send(power)
        link.emit(.status(learnStatus)) // a protocol 2 bridge after all
        try await session.send(power)
        XCTAssertEqual(link.writes.first, BlasterProtocol.send(power))
        XCTAssertEqual(link.played, [irSignal(power)])
    }

    func testCancelledLearningStopsTheReceiver() async {
        let (session, link) = readySession()
        link.emit(.status(learnStatus))
        let learning = Task { try await session.learn() }
        let started = await eventually { session.isLearning && !link.writes.isEmpty }
        XCTAssertTrue(started)
        session.cancelLearning()
        do {
            _ = try await learning.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let stopped = await eventually { link.writes.last == BlasterProtocol.learnStop }
        XCTAssertTrue(stopped)
    }

    func testLocateStopsOnError() async {
        let (session, link) = readySession()
        var errors: [BlasterError] = []
        session.onError = { errors.append($0) }
        link.writeError = .notConnected

        session.startLocate(up: blasterSignal(.volumeUp), down: blasterSignal(.volumeDown))
        let stopped = await eventually { !session.isLocating }
        XCTAssertTrue(stopped)
        XCTAssertEqual(errors, [.unreachable])
    }

    func testBatteryStatusAndFirmwareEvents() {
        let (session, link) = readySession()
        link.emit(.battery(87))
        link.emit(.status(Data([1, 0, 0x10, 0x11, 8, 0, 5, 0])))
        link.emit(.firmware("1.0.0"))
        XCTAssertEqual(session.batteryPercent, 87)
        XCTAssertEqual(session.status?.batteryMillivolts, 0x1110)
        XCTAssertEqual(session.firmwareVersion, "1.0.0")

        link.emit(.battery(140))
        XCTAssertEqual(session.batteryPercent, 100)
    }

    func testForgetDropsTheBridge() {
        let (session, link) = readySession()
        link.emit(.battery(50))
        session.forget()
        XCTAssertNil(session.saved)
        XCTAssertNil(session.batteryPercent)
        XCTAssertEqual(session.connection, .idle)
        XCTAssertEqual(link.disconnectCount, 1)
    }
}
