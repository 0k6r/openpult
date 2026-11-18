import Foundation
import Observation
import PultIR

/// What the IR bridge sends for each key: the chosen TV remote plus toggle-bit state.
@MainActor
@Observable
public final class InfraredController {
    public private(set) var remote: IRRemote?
    /// The TV code database on the device; `nil` for a controller with a fixed catalog.
    @ObservationIgnored public let profiles: ProfileDatabase?
    @ObservationIgnored private let fixedCatalog: ProfileCatalog?
    /// Kept across remote changes: the first real press after a code test must flip the toggle again.
    @ObservationIgnored private var toggles = IRToggleState()
    private let store: TVStore

    /// The installed profiles: `nil` until the database is downloaded, a new catalog after each update.
    /// Observable through `profiles`.
    public var catalog: ProfileCatalog? { profiles?.catalog ?? fixedCatalog }

    public init(store: TVStore, profiles: ProfileDatabase?) {
        self.store = store
        self.profiles = profiles
        fixedCatalog = nil
        remote = store.irRemote
    }

    /// A fixed catalog, for tests and previews.
    public init(store: TVStore, catalog: ProfileCatalog?) {
        self.store = store
        profiles = nil
        fixedCatalog = catalog
        remote = store.irRemote
    }

    public func use(_ remote: IRRemote) {
        self.remote = remote
        store.irRemote = remote
    }

    public func forgetRemote() {
        remote = nil
        store.irRemote = nil
    }

    /// The built-in Sony remote follows codes the TV reported later; learned keys stay.
    public func refreshSony(keymap: IRCCKeymap) {
        guard let current = remote, current.profileID == IRRemote.sonyProfileID else { return }
        var updated = IRRemote.sony(keymap: keymap)
        updated.name = current.name
        for key in current.learnedKeys {
            if let command = current.keys[key] { updated.setLearned(command, for: key) }
        }
        if updated != current { use(updated) }
    }

    public func isAvailable(_ key: RemoteKey) -> Bool {
        remote?.command(for: key) != nil
    }

    /// The signal for a key. `newPress` flips RC5/RC6 toggle bits; hold repeats keep them.
    public func signal(for key: RemoteKey, newPress: Bool) -> BlasterSignal? {
        remote?.command(for: key).map { signal(for: $0, newPress: newPress) }
    }

    public func signal(for command: IRCommand, newPress: Bool) -> BlasterSignal {
        switch command {
        case .code(let code):
            let toggle = IRCodecs.usesToggle(code.proto) ? toggles.toggle(for: code, newPress: newPress) : false
            return BlasterSignal(signal: IRCodecs.signal(for: command, toggle: toggle), legacy: SIRCCode(code))
        case .raw(let signal):
            return BlasterSignal(signal: signal)
        }
    }

    /// Volume up/down for aiming, or Mute twice; never a mix (that would drift the volume).
    public func locateSignals() -> (up: BlasterSignal, down: BlasterSignal)? {
        if let up = signal(for: .volumeUp, newPress: true), let down = signal(for: .volumeDown, newPress: true) {
            return (up, down)
        }
        if let first = signal(for: .mute, newPress: true), let second = signal(for: .mute, newPress: true) {
            return (first, second)
        }
        return nil
    }

    public func setLearned(_ command: IRCommand, for key: String) {
        guard var remote else { return }
        remote.setLearned(command, for: key)
        use(remote)
    }
}

// MARK: - Code test

/// Tries the profiles of one brand, grouped by the code of a test key, until the TV reacts.
/// When the matching group still holds profiles that differ, a second key narrows it down.
@MainActor
@Observable
public final class CodeTester {
    public enum TestKey: String, CaseIterable, Sendable {
        /// Turns the TV off or on: works when the TV is off, the best first test.
        case power
        /// Harmless when the TV is on: the volume bar appears.
        case volumeUp
        case mute
        case channelUp
        case home
        case up
    }

    public let brand: String
    /// Test keys that at least one candidate has.
    public private(set) var availableKeys: [TestKey] = []
    /// Candidates grouped by the code of the test key.
    public private(set) var groups: [[IRProfile]] = []
    public private(set) var index = 0
    public private(set) var testKey: TestKey = .power
    public private(set) var isSending = false
    /// Narrowing down inside a group that matched.
    public private(set) var isRefining = false
    private var candidates: [IRProfile]

    public init(brand: String, profiles: [IRProfile]) {
        self.brand = brand
        candidates = profiles
        regroup(preferring: nil)
    }

    public var current: [IRProfile] { groups.indices.contains(index) ? groups[index] : [] }
    public var isExhausted: Bool { index >= groups.count }
    /// Nothing to test with: offer the most complete profile without a test.
    public var canTest: Bool { !availableKeys.isEmpty }

    public func select(_ key: TestKey) {
        regroup(preferring: key)
    }

    /// Sends the test key of the current candidate.
    public func test(using infrared: InfraredController, send: (BlasterSignal) async throws -> Void) async throws {
        guard let profile = current.first, let command = profile.keys[testKey.rawValue] else { return }
        isSending = true
        defer { isSending = false }
        try await send(infrared.signal(for: command, newPress: true))
    }

    public func reject() {
        if index < groups.count { index += 1 }
    }

    public func restart() {
        index = 0
    }

    /// The TV reacted. Returns the profile, or `nil` when a second key is needed to tell profiles apart
    /// (the tester then shows those candidates).
    public func accept() -> IRProfile? {
        let group = current
        guard !isRefining, group.count > 1, let key = distinguishingKey(in: group) else {
            return best(of: group)
        }
        isRefining = true
        candidates = group
        regroup(preferring: key)
        return nil
    }

    /// The most complete profile when testing is impossible or the user skips it.
    public var fallback: IRProfile? { best(of: candidates) }

    private func best(of profiles: [IRProfile]) -> IRProfile? {
        profiles.max { lhs, rhs in (lhs.weight, lhs.keys.count) < (rhs.weight, rhs.keys.count) }
    }

    private func distinguishingKey(in group: [IRProfile]) -> TestKey? {
        TestKey.allCases.first { key in
            key != testKey && Set(group.compactMap { $0.keys[key.rawValue] }).count > 1
        }
    }

    private func regroup(preferring preferred: TestKey?) {
        availableKeys = TestKey.allCases.filter { key in candidates.contains { $0.keys[key.rawValue] != nil } }
        if let preferred, availableKeys.contains(preferred) {
            testKey = preferred
        } else if let first = availableKeys.first {
            testKey = first
        }
        var order: [IRCommand] = []
        var byCommand: [IRCommand: [IRProfile]] = [:]
        for profile in candidates {
            guard let command = profile.keys[testKey.rawValue] else { continue }
            if byCommand[command] == nil { order.append(command) }
            byCommand[command, default: []].append(profile)
        }
        groups = order.map { byCommand[$0]! }
        index = 0
    }
}

// MARK: - Power scan

/// Sends every known power code in turn until the user says the TV reacted.
@MainActor
@Observable
public final class PowerScanner {
    public let entries: [PowerScanEntry]
    public private(set) var index = 0
    public private(set) var isRunning = false
    /// Time between codes: long enough for the TV to react before the next one goes out.
    public var interval: Double = 2.0
    /// A reaction this soon after a code is attributed to the previous one.
    public static let reactionTime: TimeInterval = 1.2
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastSentAt: Date?
    private let sleep: @Sendable (_ seconds: Double) async -> Void
    private let now: () -> Date

    public init(
        entries: [PowerScanEntry],
        sleep: @escaping @Sendable (_ seconds: Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        now: @escaping () -> Date = Date.init
    ) {
        self.entries = entries
        self.sleep = sleep
        self.now = now
    }

    public var current: PowerScanEntry? { entries.indices.contains(index) ? entries[index] : nil }
    public var isFinished: Bool { index >= entries.count }

    public func start(using infrared: InfraredController, send: @escaping (BlasterSignal) async throws -> Void, onError: @escaping (Error) -> Void) {
        guard !isRunning, !isFinished else { return }
        isRunning = true
        task = Task { [weak self] in
            while let self, self.isRunning, !Task.isCancelled, let entry = self.current {
                do {
                    try await send(infrared.signal(for: entry.command, newPress: true))
                } catch {
                    guard !Task.isCancelled else { return }
                    if !(error is CancellationError) { onError(error) }
                    self.isRunning = false
                    return
                }
                self.lastSentAt = self.now()
                await self.sleep(self.interval)
                guard self.isRunning, !Task.isCancelled else { return }
                self.index += 1
            }
            guard !Task.isCancelled else { return }
            self?.isRunning = false
        }
    }

    /// Pauses without judging which code worked.
    public func pause() {
        isRunning = false
        task?.cancel()
        task = nil
    }

    /// The TV reacted: stop on the code that most likely caused it (TVs take a moment to switch off).
    public func markReacted() {
        let sentAt = lastSentAt
        pause()
        if let sentAt, now().timeIntervalSince(sentAt) < Self.reactionTime, index > 0 {
            index -= 1
        }
    }

    public func step(by offset: Int) {
        pause()
        index = min(max(index + offset, 0), max(entries.count - 1, 0))
    }

    public func restart() {
        pause()
        index = 0
    }

    public func sendCurrent(using infrared: InfraredController, send: (BlasterSignal) async throws -> Void) async throws {
        guard let entry = current else { return }
        try await send(infrared.signal(for: entry.command, newPress: true))
    }
}

// MARK: - Learning

/// Learns one key: two captures of the same button must agree.
@MainActor
@Observable
public final class KeyLearner {
    public enum State: Equatable {
        case idle
        case waitingFirst
        case waitingSecond
        case learned(IRCommand)
        case mismatch
        /// The app went to the background or the bridge was released; listen again.
        case interrupted
        case failed(BlasterError)
    }

    public let key: String
    public private(set) var state: State = .idle
    @ObservationIgnored private var first: IRCommand?
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(key: String) {
        self.key = key
    }

    public var isListening: Bool { state == .waitingFirst || state == .waitingSecond }

    public func start(with blaster: BlasterSession) {
        task?.cancel()
        blaster.cancelLearning()
        first = nil
        state = .waitingFirst
        task = Task { [weak self] in
            await self?.run(blaster)
        }
    }

    public func cancel(with blaster: BlasterSession) {
        task?.cancel()
        task = nil
        blaster.cancelLearning()
        if isListening { state = .idle }
    }

    private func run(_ blaster: BlasterSession) async {
        while !Task.isCancelled {
            let result: IRCaptureResult
            do {
                result = try await blaster.learn()
            } catch {
                guard !Task.isCancelled else { return }
                switch error {
                case BlasterError.learnInterrupted, is CancellationError:
                    state = .interrupted
                case BlasterError.busy:
                    // An earlier listen is still being stopped; try again shortly.
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    continue
                default:
                    state = .failed(error as? BlasterError ?? .failed(error.localizedDescription))
                }
                return
            }
            guard !Task.isCancelled else { return }
            guard case .durations(let durations, _) = result else {
                continue // a corrupted capture: just listen again
            }
            let command = IRDecoder.decode(durations)
            if let first {
                state = IRDecoder.sameCommand(first, command) ? .learned(preferCode(first, command)) : .mismatch
                return
            }
            first = command
            state = .waitingSecond
        }
    }

    /// Two captures of a toggling protocol differ only in the toggle bit; either is fine.
    private func preferCode(_ first: IRCommand, _ second: IRCommand) -> IRCommand {
        if case .code = second { return second }
        return first
    }
}
