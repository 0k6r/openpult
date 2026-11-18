import XCTest
import PultIR
@testable import BraviaKit

@MainActor
final class RemoteModelInfraredTests: XCTestCase {
    private let tv = SavedTV(host: "192.168.1.50", modelName: "KD-55X8507C")
    private let bridge = DiscoveredBlaster(id: UUID(), name: "Pult IR", rssi: -50)

    private struct Fixture {
        let model: RemoteModel
        let link: MockBlasterLink
        let transport: MockTransport
        let store: TVStore
    }

    private func make(
        mode: ControlMode = .infrared,
        paired: Bool = true,
        tv: SavedTV? = nil,
        transport: MockTransport = MockTransport(),
        pause: @escaping @Sendable (Double) async -> Void = { _ in },
        remote: IRRemote? = .sony()
    ) -> Fixture {
        let suite = "PultIRModelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = TVStore(defaults: defaults, secrets: MemorySecretStore())
        store.controlMode = mode
        if let tv {
            store.savedTV = tv
            store.credentials = .psk("0000")
        }
        if paired { store.savedBlaster = SavedBlaster(id: bridge.id, name: bridge.name) }
        store.irRemote = remote

        let link = MockBlasterLink()
        link.readyOnConnect = true
        let sleeper = ManualSleeper()
        let session = BlasterSession(link: link, store: store, sleep: { await sleeper.sleep($0) })
        let model = RemoteModel(
            store: store,
            transport: transport,
            wake: { _, _ in },
            pause: pause,
            networkInfo: { nil },
            blaster: session
        )
        return Fixture(model: model, link: link, transport: transport, store: store)
    }

    private func sent(_ key: RemoteKey) -> IRSignal { irSignal(key) }

    func testStartupRouting() {
        XCTAssertEqual(make(paired: false).model.screen, .blasterSetup)
        XCTAssertEqual(make(paired: true).model.screen, .remote)
        XCTAssertEqual(make(paired: true, remote: nil).model.screen, .irSetup)
        XCTAssertEqual(make(mode: .network, paired: true).model.screen, .discovery)
    }

    func testSonyPairedOverWiFiGetsTheSonyRemote() {
        let fixture = make(paired: true, tv: tv, remote: nil)
        XCTAssertEqual(fixture.model.screen, .remote)
        XCTAssertEqual(fixture.model.infrared.remote?.profileID, IRRemote.sonyProfileID)
        XCTAssertEqual(fixture.store.irRemote?.profileID, IRRemote.sonyProfileID)
    }

    func testChoosingAnotherTV() async {
        let fixture = make()
        fixture.model.chooseTV()
        XCTAssertEqual(fixture.model.screen, .irSetup)
        let lg = IRRemote(name: "LG", keys: ["power": .code(IRCode(proto: .nec, address: 4, command: 8))])
        fixture.model.finishIRSetup(lg)
        XCTAssertEqual(fixture.model.screen, .remote)
        XCTAssertEqual(fixture.store.irRemote, lg)

        await fixture.model.press(.power)
        let nec = IRCodecs.signal(for: .code(IRCode(proto: .nec, address: 4, command: 8)), toggle: false)
        XCTAssertEqual(fixture.link.played, [nec])

        let missing = await fixture.model.press(.mute)
        XCTAssertFalse(missing)
        XCTAssertFalse(fixture.model.isAvailable(.mute))
        XCTAssertNotNil(fixture.model.banner)
    }

    func testPairingWithoutARemoteContinuesToTVChoice() {
        let fixture = make(paired: false, remote: nil)
        fixture.model.pairBlaster(bridge)
        XCTAssertEqual(fixture.model.screen, .irSetup)
    }

    func testLocateUsesTheChosenTVsVolumeKeys() async {
        let fixture = make()
        let lgUp = IRCode(proto: .nec, address: 4, command: 2)
        let lgDown = IRCode(proto: .nec, address: 4, command: 3)
        fixture.model.finishIRSetup(IRRemote(name: "LG", keys: ["volumeUp": .code(lgUp), "volumeDown": .code(lgDown)]))
        fixture.model.startLocate()
        let sent = await eventually { fixture.link.played.count >= 1 }
        XCTAssertTrue(sent)
        XCTAssertEqual(fixture.link.played.first, IRCodecs.signal(for: .code(lgUp), toggle: false))
        fixture.model.blaster.stopLocate()
    }

    func testKeysGoThroughTheBridgeNotTheNetwork() async {
        let fixture = make(tv: tv)
        let first = await fixture.model.press(.back)
        let repeated = await fixture.model.press(.volumeUp, isRepeat: true)

        XCTAssertTrue(first)
        XCTAssertTrue(repeated)
        XCTAssertEqual(fixture.link.played, [sent(.back), sent(.volumeUp)])
        XCTAssertTrue(fixture.transport.requests.isEmpty)
    }

    func testCachedTVCodesArePreferred() async {
        var known = tv
        // The TV reports its own Return code (here: a different, made-up command) and a broken Home code.
        known.irccCodes = ["Return": "AAAAAgAAAJcAAAAkAw==", "Home": "garbage"]
        let fixture = make(tv: known, remote: nil)
        await fixture.model.press(.back)
        await fixture.model.press(.home) // invalid cached code falls back to the built-in one
        let tvReturn = irSignal(SIRCCode(ircc: "AAAAAgAAAJcAAAAkAw==")!)
        XCTAssertEqual(fixture.link.played, [tvReturn, sent(.home)])
    }

    func testPowerTogglesOverIR() async {
        let fixture = make()
        await fixture.model.togglePower()
        XCTAssertEqual(fixture.link.played, [sent(.power)])
        XCTAssertFalse(fixture.model.isPowerBusy)
    }

    func testFailedPressShowsBannerAndReportsFailure() async {
        let fixture = make()
        fixture.link.writeError = .rejected(BlasterRejection.queueFull.rawValue)
        let delivered = await fixture.model.press(.up)
        XCTAssertFalse(delivered)
        XCTAssertEqual(fixture.model.banner?.text, BlasterError.busy.errorDescription)
    }

    func testPairingFromSetupOpensRemoteWhenTheTVIsKnown() {
        let fixture = make(paired: false)
        XCTAssertEqual(fixture.model.screen, .blasterSetup)
        fixture.model.pairBlaster(bridge)
        XCTAssertEqual(fixture.model.screen, .remote)
        XCTAssertEqual(fixture.model.banner?.text, L10n.blasterConnected)
        XCTAssertEqual(fixture.store.savedBlaster?.id, bridge.id)
    }

    func testLostBondOffersRepair() {
        let fixture = make()
        fixture.model.blaster.activate()
        fixture.link.emit(.disconnected(.peerRemovedPairing))
        XCTAssertEqual(fixture.model.banner?.text, BlasterError.needsRepair.errorDescription)
        XCTAssertEqual(fixture.model.banner?.action, .repairBlaster)

        fixture.model.repairBlaster()
        XCTAssertEqual(fixture.model.screen, .blasterSetup)
        XCTAssertNil(fixture.store.savedBlaster)
    }

    func testSlowNetworkWakeDoesNotBlockIRPower() async {
        var known = tv
        known.macAddress = "fc:f1:52:00:11:22"
        let sleeper = ManualSleeper()
        let transport = MockTransport { _ in throw URLError(.cannotConnectToHost) }
        let fixture = make(mode: .network, paired: true, tv: known, transport: transport, pause: { await sleeper.sleep($0) })

        let wake = Task { await fixture.model.togglePower() }
        let waking = await eventually { await sleeper.durations.contains(1.5) }
        XCTAssertTrue(waking)
        XCTAssertTrue(fixture.model.isPowerBusy)

        fixture.model.useInfrared()
        XCTAssertFalse(fixture.model.isPowerBusy)
        await fixture.model.togglePower()
        XCTAssertEqual(fixture.link.played, [sent(.power)])

        await sleeper.fire(1.5)
        await wake.value
        XCTAssertNotEqual(fixture.model.banner?.isError, true, "no network banner over the IR remote")
    }

    func testSwitchingModes() async {
        let fixture = make(mode: .network, paired: true, tv: tv)
        XCTAssertEqual(fixture.model.screen, .remote)

        fixture.model.useInfrared()
        XCTAssertEqual(fixture.model.screen, .remote)
        XCTAssertTrue(fixture.model.isInfrared)
        XCTAssertEqual(fixture.store.controlMode, .infrared)
        XCTAssertEqual(fixture.model.blaster.connection, .ready)

        fixture.model.useNetwork()
        XCTAssertEqual(fixture.model.screen, .remote)
        XCTAssertEqual(fixture.store.controlMode, .network)
        XCTAssertEqual(fixture.model.blaster.connection, .idle)
        XCTAssertEqual(fixture.link.disconnectCount, 1)
    }

    func testInfraredWithoutBridgeOpensSetup() {
        let fixture = make(mode: .network, paired: false)
        fixture.model.useInfrared()
        XCTAssertEqual(fixture.model.screen, .blasterSetup)
        XCTAssertTrue(fixture.link.connectCalls.isEmpty)
    }

    func testForgetBridgeReturnsToSetup() {
        let fixture = make()
        fixture.model.forgetBlaster()
        XCTAssertEqual(fixture.model.screen, .blasterSetup)
        XCTAssertNil(fixture.store.savedBlaster)
    }

    func testNetworkOnlyFeaturesAreOffOverIR() async {
        let fixture = make(tv: tv)
        let textSent = await fixture.model.sendText("hello")
        await fixture.model.loadApps()
        await fixture.model.loadInputs()
        XCTAssertFalse(textSent)
        XCTAssertTrue(fixture.model.apps.isEmpty)
        XCTAssertTrue(fixture.model.inputs.isEmpty)
        XCTAssertTrue(fixture.transport.requests.isEmpty)
    }

    func testRefreshAndBackgroundDriveTheConnection() async {
        let fixture = make()
        await fixture.model.refresh()
        XCTAssertEqual(fixture.model.blaster.connection, .ready)
        fixture.model.enterBackground()
        XCTAssertEqual(fixture.model.blaster.connection, .idle)
        XCTAssertEqual(fixture.link.disconnectCount, 1)
    }
}
