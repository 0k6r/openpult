import XCTest
import PultIR
@testable import BraviaKit

@MainActor
final class InfraredTests: XCTestCase {
    private func makeStore() -> TVStore {
        let suite = "PultInfraredTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return TVStore(defaults: defaults, secrets: MemorySecretStore())
    }

    private func code(_ proto: IRProtocolID, _ address: UInt32, _ command: UInt32) -> IRCommand {
        .code(IRCode(proto: proto, address: address, command: command))
    }

    // MARK: Catalog

    private func makeCatalogDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("profiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("brands"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let files: [String: String] = [
            "index.json": #"{"schema":1,"source":{"db":"test"},"brands":[{"id":"lg","name":"LG","file":"brands/lg.json","profiles":3}],"future":true}"#,
            "brands/lg.json": #"""
            [
              {"id":"lg-1","brand":"LG","name":"LG A","models":[],"weight":5,"source":[],
               "keys":{"power":{"p":"NEC","a":4,"c":8},"volumeUp":{"p":"NEC","a":4,"c":2},"teleport":{"p":"Unknown","a":1,"c":1}},
               "extra":[{"name":"Q.Menu","cmd":{"p":"NEC","a":4,"c":69}}]},
              {"id":"lg-2","brand":"LG","name":"LG B","keys":{"power":{"p":"NEC","a":4,"c":8},"mute":{"p":"NEC","a":4,"c":9},"volumeUp":{"p":"NEC","a":4,"c":2}}},
              {"id":"lg-3","brand":"LG","name":"LG raw","weight":1,
               "keys":{"power":{"raw":{"f":38000,"d":33,"i":[],"r":[9000,4500,560,40000]}}}}
            ]
            """#,
            "power_scan.json": #"[{"cmd":{"p":"NEC","a":4,"c":8},"brands":["LG"],"weight":55},{"cmd":{"p":"Nope","a":1,"c":1},"brands":[],"weight":1}]"#,
        ]
        for (name, text) in files {
            try Data(text.utf8).write(to: directory.appendingPathComponent(name))
        }
        return directory
    }

    func testCatalogDecodesProfiles() throws {
        let catalog = ProfileCatalog(directory: try makeCatalogDirectory())
        let brands = try catalog.brands()
        XCTAssertEqual(brands.map(\.name), ["LG"])
        let profiles = try catalog.profiles(for: brands[0])
        XCTAssertEqual(profiles.map(\.id), ["lg-1", "lg-2", "lg-3"])
        XCTAssertEqual(profiles[0].keys["power"], code(.nec, 4, 8))
        XCTAssertNil(profiles[0].keys["teleport"], "unknown protocols are skipped")
        XCTAssertEqual(profiles[0].extra, [IRNamedCommand(name: "Q.Menu", command: code(.nec, 4, 69))])
        XCTAssertEqual(profiles[1].weight, 1)
        XCTAssertEqual(profiles[2].keys["power"], .raw(IRSignal(carrierHz: 38000, dutyPercent: 33, intro: [], repeat: [9000, 4500, 560, 40000], minRepeats: 2)))

        let scan = try catalog.powerScan()
        XCTAssertEqual(scan.map(\.command), [code(.nec, 4, 8)])
        let best = try catalog.bestProfile(withPower: code(.nec, 4, 8), brands: ["lg"])
        XCTAssertEqual(best?.id, "lg-1")
    }

    /// The Flipper-IRDB layout below `irdb` read like the device reads a download: the same file rules and order.
    private func buildInput(irdb: URL, commit: String) throws -> ProfileBuildInput {
        let tvs = irdb.appendingPathComponent("TVs")
        let fm = FileManager.default
        var files: [IRDBManifest.File] = []
        var urls: [String: URL] = [:]
        let enumerator = try XCTUnwrap(fm.enumerator(at: tvs, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]))
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let path = String(url.standardizedFileURL.path.dropFirst(tvs.standardizedFileURL.path.count + 1))
            guard IRDBClient.isImportable(path, components: IRDBClient.splitPath(path)) else { continue }
            let data = try Data(contentsOf: url)
            guard data.count <= IRDBLimits.maxFileBytes else { continue }
            files.append(IRDBManifest.File(path: path, sha: GitObjectHash.blob(data), size: data.count))
            urls[path] = url
        }
        let readme = try? Data(contentsOf: irdb.appendingPathComponent("README.md"))
        return ProfileBuildInput(
            files: IRDBClient.walkOrder(files).map { file in
                let url = urls[file.path]!
                return ProfileBuildInput.File(path: file.path) { try Data(contentsOf: url) }
            },
            commit: commit,
            url: IRDBPin.url,
            licenseNote: IRDBLicense.note(readme: readme)
        )
    }

    /// Imports with the real importer (PultProfiles) and checks that every command fits the bridge's signal blob.
    @discardableResult
    private func assertPlayable(irdb: URL, commit: String, minimumCommands: Int, minimumPowerCodes: Int, file: StaticString = #filePath, line: UInt = #line) throws -> [ProfileFile] {
        XCTAssertTrue(IRDBLicense.isCC0(try Data(contentsOf: irdb.appendingPathComponent("LICENSE"))), file: file, line: line)
        let output = try PultProfileBuilder().build(try buildInput(irdb: irdb, commit: commit))
        _ = try ProfileDatabaseStorage.validate(output, files: 0)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("profiles-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        for item in output {
            let url = directory.appendingPathComponent(item.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try item.data.write(to: url)
        }
        let catalog = ProfileCatalog(directory: directory)
        var failures: [String] = []
        var count = 0
        for brand in try catalog.brands() {
            for profile in try catalog.profiles(for: brand) {
                let commands = profile.keys.map { ($0.key, $0.value) } + profile.extra.map { ($0.name, $0.command) }
                for (key, command) in commands {
                    count += 1
                    let signal = IRCodecs.signal(for: command, toggle: false)
                    do {
                        _ = try IRSignalBlob.encode(signal)
                    } catch {
                        failures.append("\(profile.id).\(key): \(error)")
                    }
                }
            }
        }
        XCTAssertGreaterThan(count, minimumCommands, file: file, line: line)
        XCTAssertEqual(failures, [], "\(failures.count) of \(count) commands cannot be played", file: file, line: line)
        XCTAssertGreaterThan(try catalog.powerScan().count, minimumPowerCodes, file: file, line: line)
        XCTAssertEqual(try catalog.source()?.commit, commit, file: file, line: line)
        return output
    }

    func testFixtureProfilesAreAllPlayable() throws {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("tools/profiles/fixtures/irdb/TVs").path) {
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { throw XCTSkip("tools/profiles/fixtures/irdb not found") }
            directory = parent
        }
        try assertPlayable(irdb: directory.appendingPathComponent("tools/profiles/fixtures/irdb"), commit: String(repeating: "0123456789", count: 4),
                           minimumCommands: 0, minimumPowerCodes: 0)
    }

    /// The whole database: OPENPULT_IRDB=<Flipper-IRDB checkout of IRDBPin.commit>. With
    /// OPENPULT_PROFILES_EXPECTED=<Python output for it> the files read the way a download is read must build
    /// byte-identical profiles.
    func testFullDatabaseIsPlayable() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["OPENPULT_IRDB"] else {
            throw XCTSkip("set OPENPULT_IRDB to a Flipper-IRDB checkout")
        }
        let output = try assertPlayable(irdb: URL(fileURLWithPath: path), commit: IRDBPin.commit, minimumCommands: 5000, minimumPowerCodes: 50)
        guard let expected = environment["OPENPULT_PROFILES_EXPECTED"] else { return }
        let expectedURL = URL(fileURLWithPath: expected)
        let names = try FileManager.default.subpathsOfDirectory(atPath: expected).filter { $0.hasSuffix(".json") }
        XCTAssertEqual(Set(output.map(\.path)), Set(names))
        for item in output {
            XCTAssertEqual(item.data, try Data(contentsOf: expectedURL.appendingPathComponent(item.path)), item.path)
        }
    }

    // MARK: Remote and signals

    func testSonyRemoteAndSubstitutes() throws {
        let sony = IRRemote.sony()
        XCTAssertEqual(sony.command(for: .power), code(.sirc, 1, 21))
        XCTAssertEqual(sony.command(for: .back), code(.sirc15, 151, 35))

        let old = IRRemote(name: "Old", keys: ["menu": code(.rc5, 0, 48), "exit": code(.rc5, 0, 49)])
        XCTAssertEqual(old.command(for: .options), code(.rc5, 0, 48))
        XCTAssertEqual(old.command(for: .back), code(.rc5, 0, 49))
        XCTAssertNil(old.command(for: .mute))

        let data = try JSONEncoder().encode(sony)
        XCTAssertEqual(try JSONDecoder().decode(IRRemote.self, from: data), sony)
    }

    func testToggleBitsFlipOnNewPressesOnly() {
        let infrared = InfraredController(store: makeStore(), catalog: nil)
        infrared.use(IRRemote(name: "Philips", keys: ["num1": code(.rc5, 0, 1)]))
        let first = infrared.signal(for: .num1, newPress: true)
        let held = infrared.signal(for: .num1, newPress: false)
        let second = infrared.signal(for: .num1, newPress: true)
        XCTAssertEqual(first, held)
        XCTAssertNotEqual(first, second)
        XCTAssertNil(first?.legacy)
    }

    func testSonySignalsCarryTheLegacyCode() {
        let infrared = InfraredController(store: makeStore(), catalog: nil)
        infrared.use(.sony())
        XCTAssertEqual(infrared.signal(for: .power, newPress: true)?.legacy, SIRCCode(ircc: RemoteKey.power.fallbackCode))
    }

    func testLearnedKeysPersist() {
        let store = makeStore()
        let infrared = InfraredController(store: store, catalog: nil)
        infrared.use(.sony())
        infrared.setLearned(code(.nec, 1, 2), for: "mute")
        XCTAssertEqual(store.irRemote?.keys["mute"], code(.nec, 1, 2))
        XCTAssertEqual(store.irRemote?.learnedKeys, ["mute"])
        XCTAssertEqual(InfraredController(store: store, catalog: nil).remote?.keys["mute"], code(.nec, 1, 2))
    }

    // MARK: Code test

    private func profile(_ id: String, weight: Int = 1, _ keys: [String: IRCommand]) -> IRProfile {
        IRProfile(id: id, brand: "LG", name: id, models: [], weight: weight, keys: keys, extra: [])
    }

    func testCodeTesterGroupsByTheTestKey() async throws {
        let a = profile("a", ["power": code(.nec, 4, 8), "mute": code(.nec, 4, 9)])
        let b = profile("b", weight: 3, ["power": code(.nec, 4, 8), "mute": code(.nec, 4, 9), "num1": code(.nec, 4, 17)])
        let c = profile("c", ["power": code(.necext, 0x7F00, 0xE51A)])
        let tester = CodeTester(brand: "LG", profiles: [a, b, c])
        XCTAssertEqual(tester.groups.count, 2)
        XCTAssertEqual(tester.fallback?.id, "b", "the most complete profile overall")

        let infrared = InfraredController(store: makeStore(), catalog: nil)
        var sent: [BlasterSignal] = []
        try await tester.test(using: infrared) { sent.append($0) }
        XCTAssertEqual(sent.map(\.signal), [IRCodecs.signal(for: code(.nec, 4, 8), toggle: false)])

        tester.reject()
        XCTAssertEqual(tester.current.map(\.id), ["c"])
        tester.reject()
        XCTAssertTrue(tester.isExhausted)

        tester.select(.mute)
        XCTAssertEqual(tester.groups.count, 1, "c has no mute key")
        XCTAssertFalse(tester.isExhausted)
        XCTAssertEqual(tester.accept()?.id, "b", "a and b agree on mute: the most complete one wins")
    }

    func testCodeTesterRefinesAGroupWithASecondKey() {
        let a = profile("a", ["power": code(.nec, 4, 8), "volumeUp": code(.nec, 4, 2)])
        let b = profile("b", ["power": code(.nec, 4, 8), "volumeUp": code(.nec, 4, 66)])
        let tester = CodeTester(brand: "LG", profiles: [a, b])
        XCTAssertNil(tester.accept(), "power matched, but the volume codes differ")
        XCTAssertTrue(tester.isRefining)
        XCTAssertEqual(tester.testKey, .volumeUp)
        XCTAssertEqual(tester.groups.map { $0.map(\.id) }, [["a"], ["b"]])
        tester.reject()
        XCTAssertEqual(tester.accept()?.id, "b")
    }

    func testCodeTesterPicksATestKeyTheBrandHas() {
        let xiaomi = profile("x", ["volumeUp": code(.nec, 1, 2), "up": code(.nec, 1, 3)])
        let tester = CodeTester(brand: "Xiaomi", profiles: [xiaomi])
        XCTAssertEqual(tester.testKey, .volumeUp)
        XCTAssertEqual(tester.availableKeys, [.volumeUp, .up])
        XCTAssertFalse(tester.isExhausted)

        let roku = CodeTester(brand: "Roku", profiles: [profile("r", ["confirm": code(.nec, 1, 9)])])
        XCTAssertFalse(roku.canTest)
        XCTAssertEqual(roku.fallback?.id, "r")
    }

    // MARK: Power scan

    func testPowerScanSendsCodesInTurnUntilStopped() async {
        let sleeper = ManualSleeper()
        let entries = [
            PowerScanEntry(command: code(.nec, 4, 8), brands: ["LG"], weight: 55),
            PowerScanEntry(command: code(.samsung32, 7, 2), brands: ["Samsung"], weight: 41),
            PowerScanEntry(command: code(.sirc, 1, 21), brands: ["Sony"], weight: 28),
        ]
        let clock = TestClock()
        let scanner = PowerScanner(entries: entries, sleep: { await sleeper.sleep($0) }, now: { clock.now })
        let infrared = InfraredController(store: makeStore(), catalog: nil)
        var sent: [IRSignal] = []
        scanner.start(using: infrared, send: { sent.append($0.signal) }, onError: { _ in })

        let first = await eventually { sent.count == 1 }
        XCTAssertTrue(first)
        let sleeping = await eventually { await sleeper.durations.contains(2.0) }
        XCTAssertTrue(sleeping)
        clock.advance(2.0)
        await sleeper.fire(2.0)
        let second = await eventually { sent.count == 2 }
        XCTAssertTrue(second)
        XCTAssertEqual(scanner.index, 1)

        // The TV switched off a moment after Samsung's code went out: LG's code caused it.
        clock.advance(0.6)
        scanner.markReacted()
        XCTAssertFalse(scanner.isRunning)
        XCTAssertEqual(scanner.current?.brands, ["LG"])
        scanner.step(by: -1)
        XCTAssertEqual(scanner.index, 0)
        scanner.step(by: 5)
        XCTAssertEqual(scanner.index, 2)
    }

    func testLateReactionKeepsTheLastCode() async {
        let sleeper = ManualSleeper()
        let clock = TestClock()
        let entries = [
            PowerScanEntry(command: code(.nec, 4, 8), brands: ["LG"], weight: 55),
            PowerScanEntry(command: code(.samsung32, 7, 2), brands: ["Samsung"], weight: 41),
        ]
        let scanner = PowerScanner(entries: entries, sleep: { await sleeper.sleep($0) }, now: { clock.now })
        var sent = 0
        scanner.start(using: InfraredController(store: makeStore(), catalog: nil), send: { _ in sent += 1 }, onError: { _ in })
        let waiting = await eventually { await sleeper.durations.contains(2.0) }
        XCTAssertTrue(waiting)
        clock.advance(1.5)
        scanner.markReacted()
        XCTAssertEqual(scanner.index, 0, "1.5 s after the code: it was this one")
        scanner.pause()
        XCTAssertFalse(scanner.isRunning)
    }

    func testLocateNeverMixesVolumeWithMute() {
        let infrared = InfraredController(store: makeStore(), catalog: nil)
        infrared.use(IRRemote(name: "Odd", keys: ["volumeUp": code(.nec, 1, 2), "mute": code(.nec, 1, 9)]))
        let pair = infrared.locateSignals()
        XCTAssertEqual(pair?.up.signal, IRCodecs.signal(for: code(.nec, 1, 9), toggle: false))
        XCTAssertEqual(pair?.down.signal, IRCodecs.signal(for: code(.nec, 1, 9), toggle: false))
        infrared.use(IRRemote(name: "None", keys: ["volumeUp": code(.nec, 1, 2)]))
        XCTAssertNil(infrared.locateSignals())
    }

    func testSonyRemoteFollowsLaterTVCodes() {
        let infrared = InfraredController(store: makeStore(), catalog: nil)
        infrared.use(.sony())
        infrared.setLearned(code(.nec, 1, 2), for: "mute")
        infrared.refreshSony(keymap: IRCCKeymap(tvCodes: ["Return": "AAAAAgAAAJcAAAAkAw=="]))
        XCTAssertEqual(infrared.remote?.keys["back"], code(.sirc15, 151, 36))
        XCTAssertEqual(infrared.remote?.keys["mute"], code(.nec, 1, 2), "learned keys stay")
    }

    func testRawRecordingsPlayTwiceAndWakeUpMatchesScans() throws {
        let directory = try makeCatalogDirectory()
        try Data(#"[{"id":"lg-9","brand":"LG","name":"LG wake","keys":{"wakeUp":{"p":"NEC","a":4,"c":196}}}]"#.utf8)
            .write(to: directory.appendingPathComponent("brands/lg.json"))
        let catalog = ProfileCatalog(directory: directory)
        XCTAssertEqual(try catalog.bestProfile(withPower: code(.nec, 4, 196), brands: ["LG"])?.id, "lg-9")

        let fresh = ProfileCatalog(directory: try makeCatalogDirectory())
        let raw = try fresh.profiles(for: try fresh.brands()[0])[2].keys["power"]
        guard case .raw(let signal) = raw else { return XCTFail("expected raw") }
        XCTAssertEqual(signal.minRepeats, 2)
    }

    // MARK: Learning

    private let necCapture: [Int] = {
        var durations = [9000, 4500]
        for byte: UInt8 in [0x04, 0xFB, 0x08, 0xF7] {
            for bit in 0..<8 { durations += [562, (byte >> bit) & 1 == 1 ? 1687 : 562] }
        }
        return durations + [562]
    }()

    private func captureNotification(_ durations: [Int], id: UInt8) -> Data {
        var bytes: [UInt8] = [id, 0x80, 0, UInt8(durations.count & 0xFF), UInt8(durations.count >> 8)]
        for var value in durations {
            repeat {
                let low = UInt8(value & 0x7F)
                value >>= 7
                bytes.append(value == 0 ? low : low | 0x80)
            } while value != 0
        }
        return Data(bytes)
    }

    func testKeyLearnerNeedsTwoMatchingCaptures() async {
        let link = MockBlasterLink()
        let session = BlasterSession(link: link, store: {
            let store = makeStore()
            store.savedBlaster = SavedBlaster(id: UUID(), name: "OpenPult")
            return store
        }(), sleep: { _ in try? await Task.sleep(nanoseconds: 60_000_000_000) })
        session.activate()
        link.emit(.ready)
        link.emit(.status(Data([2, 0, 0x94, 0x11, 8, 0, 0, 0, 0b1011, 0x40, 0x02, 0])))

        let learner = KeyLearner(key: "power")
        learner.start(with: session)
        let listening = await eventually { session.isLearning && link.writes.count == 1 }
        XCTAssertTrue(listening)
        link.emit(.capture(captureNotification(necCapture, id: 1)))
        let again = await eventually { learner.state == .waitingSecond }
        XCTAssertTrue(again)

        let listeningAgain = await eventually { session.isLearning && link.writes.count == 2 }
        XCTAssertTrue(listeningAgain)
        link.emit(.capture(captureNotification(necCapture.map { $0 + 40 }, id: 2)))
        let learned = await eventually { if case .learned = learner.state { return true } else { return false } }
        XCTAssertTrue(learned)
        XCTAssertEqual(learner.state, .learned(code(.nec, 4, 8)))
    }

    func testKeyLearnerRecoversAfterTheAppWasInTheBackground() async {
        let link = MockBlasterLink()
        let store = makeStore()
        store.savedBlaster = SavedBlaster(id: UUID(), name: "OpenPult")
        let session = BlasterSession(link: link, store: store, sleep: { _ in try? await Task.sleep(nanoseconds: 60_000_000_000) })
        session.activate()
        link.emit(.ready)
        let learner = KeyLearner(key: "power")
        learner.start(with: session)
        let listening = await eventually { session.isLearning && link.writes.count == 1 }
        XCTAssertTrue(listening)

        session.deactivate()
        let interrupted = await eventually { learner.state == .interrupted }
        XCTAssertTrue(interrupted)

        session.activate()
        link.emit(.ready)
        learner.start(with: session)
        let again = await eventually { session.isLearning && learner.state == .waitingFirst }
        XCTAssertTrue(again)
        learner.cancel(with: session)
    }

    func testKeyLearnerReportsMissingReceiver() async {
        let link = MockBlasterLink()
        let store = makeStore()
        store.savedBlaster = SavedBlaster(id: UUID(), name: "OpenPult")
        let session = BlasterSession(link: link, store: store)
        session.activate()
        link.emit(.ready)
        link.emit(.status(Data([2, 0, 0x94, 0x11, 8, 0, 0, 0, 0b1001, 0x40, 0x02, 0])))
        let learner = KeyLearner(key: "power")
        learner.start(with: session)
        let failed = await eventually { learner.state == .failed(.noReceiver) }
        XCTAssertTrue(failed)
    }
}
