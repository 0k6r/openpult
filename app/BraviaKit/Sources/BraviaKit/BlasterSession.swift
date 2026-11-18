import Foundation
import Observation
import PultIR

public enum BlasterError: Error, Equatable, LocalizedError {
    case bluetoothOff, bluetoothDenied, bluetoothUnsupported
    case notPaired
    case unreachable
    case pairingFailed
    case needsRepair
    case busy
    case rejected
    case firmwareTooOld
    case unsupportedSignal
    case noReceiver
    case learnTimeout
    /// Learning stopped because the app left the foreground or the bridge was released.
    case learnInterrupted
    /// The bridge's board cannot do this (e.g. no UF2 bootloader).
    case notSupportedByBoard
    /// Internal: HOLD found nothing to extend; the session falls back to a new press.
    case nothingToHold
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .bluetoothOff:
            return String(
                localized: "Bluetooth is off. Turn it on to use the IR bridge.",
                bundle: .module, comment: "Error: Bluetooth is powered off."
            )
        case .bluetoothDenied:
            return String(
                localized: "OpenPult doesn't have access to Bluetooth. Allow it in Settings → Apps → OpenPult → Bluetooth.",
                bundle: .module, comment: "Error: Bluetooth permission denied. OpenPult is the app name, as shown in iOS Settings → Apps (iOS 18+)."
            )
        case .bluetoothUnsupported:
            return String(localized: "Bluetooth isn't available on this device.", bundle: .module, comment: "Error: no Bluetooth LE.")
        case .notPaired:
            return String(localized: "The IR bridge isn't connected yet.", bundle: .module, comment: "Error: no bridge has been paired.")
        case .unreachable:
            return String(
                localized: "The bridge isn't responding. Make sure it's on and nearby, and that the batteries aren't dead.",
                bundle: .module, comment: "Error: the IR bridge cannot be reached over Bluetooth."
            )
        case .pairingFailed:
            return String(
                localized: "Pairing failed. Turn the bridge off and on, then connect it again within 2 minutes.",
                bundle: .module, comment: "Error: Bluetooth pairing with the bridge failed."
            )
        case .needsRepair:
            return String(
                localized: "The bridge forgot this iPhone. Forget OpenPult in Settings → Bluetooth, turn the bridge off and on, and connect it again.",
                bundle: .module, comment: "Error: the bridge lost its bond. OpenPult is the bridge's Bluetooth name; do not translate."
            )
        case .busy:
            return String(localized: "The bridge is still sending previous commands.", bundle: .module, comment: "Error: the bridge's queue is full.")
        case .rejected:
            return String(
                localized: "The bridge rejected the command. It may need a firmware update.",
                bundle: .module, comment: "Error: the bridge did not accept a command."
            )
        case .firmwareTooOld:
            return String(
                localized: "The bridge firmware is outdated and only supports Sony TVs. Update the firmware.",
                bundle: .module, comment: "Error: firmware speaks protocol v1 only."
            )
        case .unsupportedSignal:
            return String(localized: "The bridge can't send this signal.", bundle: .module, comment: "Error: the IR signal is out of the bridge's limits.")
        case .noReceiver:
            return String(
                localized: "The bridge has no IR receiver, so learning isn't available. Connect a VS1838B or TSOP38238.",
                bundle: .module, comment: "Error: learning needs an IR receiver module (part numbers)."
            )
        case .learnTimeout:
            return String(
                localized: "No signal received. Point the remote at the bridge from 5–10 cm away and press the button again.",
                bundle: .module, comment: "Error: learning timed out."
            )
        case .learnInterrupted:
            return String(
                localized: "Listening stopped. Tap Listen Again.",
                bundle: .module, comment: "Error: learning was interrupted. Listen Again is a button on the learning screen."
            )
        case .notSupportedByBoard:
            return String(localized: "The bridge's board can't do this.", bundle: .module, comment: "Error: e.g. no UF2 bootloader.")
        case .nothingToHold:
            return String(localized: "The bridge found no signal to repeat.", bundle: .module, comment: "Error: internal, a held key had nothing to extend.")
        case .failed(let message):
            return String(localized: "Bluetooth error: \(message)", bundle: .module, comment: "Error: %@ is a system or bridge error message.")
        }
    }
}

/// Connection to the «OpenPult» bridge: connects while the app is in the foreground,
/// drops the link when idle or in the background to save the bridge's batteries.
///
/// Commands are written strictly in the order `send` was called, even when several
/// presses pile up while the link is still coming up.
@MainActor
@Observable
public final class BlasterSession {
    public enum Connection: Equatable {
        case idle, connecting, ready
    }

    public private(set) var saved: SavedBlaster?
    /// The bridge being paired; it is saved only after the first successful connection.
    public private(set) var pairingCandidate: SavedBlaster?
    public private(set) var availability: BlasterAvailability = .unknown
    public private(set) var connection: Connection = .idle
    public private(set) var needsRepair = false
    public private(set) var batteryPercent: Int?
    public private(set) var status: BlasterStatus?
    public private(set) var firmwareVersion: String?
    public private(set) var discovered: [DiscoveredBlaster] = []
    public private(set) var isScanning = false
    public private(set) var isLocating = false
    public private(set) var isLearning = false

    /// The bridge became ready (first connection after pairing, or a reconnect).
    @ObservationIgnored var onReady: (() -> Void)?
    /// Problems the user should see (pairing failures, lost bond, failed aiming).
    @ObservationIgnored var onError: ((BlasterError) -> Void)?

    static let readyTimeout = 6.0
    static let pairingTimeout = 40.0
    static let idleTimeout = 300.0
    static let locateInterval = 0.6
    /// About a minute of aiming, then it stops by itself.
    static let locateMaxSteps = 100
    /// Frames per hold repeat: overlaps the ~120–180 ms repeat period of a held button.
    static let holdFrames: UInt8 = 5

    private enum WaitResult { case ready, failed, cancelled }

    private let link: BlasterLink
    private let store: TVStore
    private let sleep: @Sendable (_ seconds: Double) async -> Void
    private var isActive = false
    private var lastLinkError: BlasterLinkError?
    private var readyWaiters: [(id: UUID, continuation: CheckedContinuation<WaitResult, Never>)] = []
    private var idleTask: Task<Void, Never>?
    private var locateTask: Task<Void, Never>?
    private var pairingTimeoutTask: Task<Void, Never>?
    private var writeChain: Task<Void, Never>?
    private var lastSequence = 0
    /// Commands queued up to this sequence number fail fast after the link failed to come up.
    private var failedThrough = 0
    private var lastFailure: Error = BlasterError.unreachable
    /// Press token of the signal last sent with PLAY (HOLD refers to it).
    private var sigID: UInt8 = 0
    private var lastSignal: IRSignal?
    /// The bridge speaks protocol 1 (Sony SIRC only).
    private var usesLegacyProtocol = false

    private enum LearnOutcome { case captured(IRCaptureResult), timedOut, cancelled, interrupted, linkLost }
    private var learnContinuation: CheckedContinuation<LearnOutcome, Never>?
    /// Identifies the current `learn` call, so a timer of an earlier one cannot end it.
    private var learnGeneration = 0
    /// An outcome that arrived before `learn` started waiting (e.g. a capture right after LEARN_START).
    private var pendingLearnOutcome: LearnOutcome?
    private var captureAssembler = IRCaptureAssembler()

    public init(
        link: BlasterLink,
        store: TVStore,
        sleep: @escaping @Sendable (_ seconds: Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) {
        self.link = link
        self.store = store
        self.sleep = sleep
        saved = store.savedBlaster
        link.onEvent = { [weak self] event in self?.handle(event) }
    }

    private var target: SavedBlaster? { pairingCandidate ?? saved }

    // MARK: - Lifecycle

    /// The app is in the foreground: keep the saved bridge connected.
    public func activate() {
        if !isActive {
            // The user may have fixed a lost bond in Settings while the app was away.
            needsRepair = false
        }
        isActive = true
        connectIfNeeded()
    }

    /// The app left the foreground: release the bridge.
    public func deactivate() {
        isActive = false
        stopLocate()
        stopScan()
        endPairing()
        dropConnection()
    }

    // MARK: - Setup

    public func startScan() {
        discovered = []
        isScanning = true
        link.startScan()
    }

    public func stopScan() {
        guard isScanning else { return }
        isScanning = false
        link.stopScan()
    }

    /// Connects to a discovered bridge; iOS shows the pairing dialog on first use.
    public func pair(_ blaster: DiscoveredBlaster) {
        stopScan()
        stopLocate()
        dropConnection()
        needsRepair = false
        lastLinkError = nil
        pairingCandidate = SavedBlaster(id: blaster.id, name: blaster.name)
        resetBridgeInfo()
        isActive = true
        connectIfNeeded()
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = Task { [weak self, sleep] in
            await sleep(Self.pairingTimeout)
            guard !Task.isCancelled, let self, self.pairingCandidate != nil else { return }
            self.endPairing()
            self.dropConnection()
            self.onError?(.pairingFailed)
        }
    }

    public func forget() {
        stopLocate()
        endPairing()
        dropConnection()
        store.savedBlaster = nil
        saved = nil
        needsRepair = false
        resetBridgeInfo()
    }

    private func resetBridgeInfo() {
        batteryPercent = nil
        status = nil
        firmwareVersion = nil
        usesLegacyProtocol = false
        lastSignal = nil
    }

    // MARK: - Commands

    /// Sends a key press (`hold == false`) or extends the press on air while a button is held.
    /// Waits a few seconds for the link if it is still coming up.
    public func send(_ key: BlasterSignal, hold: Bool = false) async throws {
        try await enqueue { session in try await session.transmit(key, hold: hold) }
    }

    /// Sony SIRC shortcut (also works with protocol 1 bridges).
    public func send(_ code: SIRCCode, hold: Bool = false) async throws {
        try await send(BlasterSignal(signal: IRCodecs.signal(for: .code(code.irCode), toggle: false), legacy: code), hold: hold)
    }

    /// Whether learning can work: the bridge reported a receiver (unknown → let the user try).
    public var canLearn: Bool {
        status?.capabilities.map { $0.contains(.learn) } ?? true
    }

    /// Whether the bridge reported a UF2 bootloader (unknown → assume yes, the bridge answers 0x85 otherwise).
    public var hasBootloader: Bool {
        status?.capabilities.map { $0.contains(.uf2Bootloader) } ?? true
    }

    /// Reboots the bridge into its UF2 bootloader.
    public func enterBootloader() async throws {
        guard hasBootloader else { throw BlasterError.notSupportedByBoard }
        do {
            // The bridge may reboot before its write response arrives: that is success too.
            try await enqueue { session in
                try await session.linkWrite(BlasterProtocol.enterBootloader, toleratingLinkLoss: true)
            }
        } catch BlasterError.rejected where status?.supportsPlay == true {
            throw BlasterError.notSupportedByBoard
        }
        dropConnection()
    }

    /// Captures one IR signal from the original remote (the bridge needs a receiver).
    public func learn(timeoutSeconds: Int = 20) async throws -> IRCaptureResult {
        if let capabilities = status?.capabilities, !capabilities.contains(.learn) { throw BlasterError.noReceiver }
        guard !isLearning else { throw BlasterError.busy }
        captureAssembler = IRCaptureAssembler()
        pendingLearnOutcome = nil
        learnGeneration += 1
        let generation = learnGeneration
        isLearning = true
        defer {
            isLearning = false
            pendingLearnOutcome = nil
        }
        do {
            try await enqueue { session in
                try await session.linkWrite(BlasterProtocol.learnStart(timeoutSeconds: timeoutSeconds))
            }
        } catch BlasterError.rejected where status?.supportsPlay != true {
            throw BlasterError.firmwareTooOld
        } catch is CancellationError {
            throw BlasterError.learnInterrupted
        }
        let outcome: LearnOutcome
        if let pending = pendingLearnOutcome {
            outcome = pending
        } else {
            outcome = await withCheckedContinuation { continuation in
                learnContinuation = continuation
                Task { [weak self, sleep] in
                    await sleep(Double(timeoutSeconds) + 3)
                    guard let self, self.learnGeneration == generation else { return }
                    self.finishLearning(.timedOut)
                }
            }
        }
        switch outcome {
        case .captured(.timeout):
            throw BlasterError.learnTimeout
        case .timedOut:
            // The bridge never answered: make sure it stops listening.
            Task { try? await self.enqueue { session in try await session.linkWrite(BlasterProtocol.learnStop) } }
            throw BlasterError.learnTimeout
        case .captured(let result):
            return result
        case .cancelled:
            throw CancellationError()
        case .interrupted:
            throw BlasterError.learnInterrupted
        case .linkLost:
            throw BlasterError.unreachable
        }
    }

    public func cancelLearning() {
        guard isLearning else { return }
        finishLearning(.cancelled)
        Task { try? await self.enqueue { session in try await session.linkWrite(BlasterProtocol.learnStop) } }
    }

    private func finishLearning(_ outcome: LearnOutcome) {
        if let continuation = learnContinuation {
            learnContinuation = nil
            continuation.resume(returning: outcome)
        } else if isLearning, pendingLearnOutcome == nil {
            pendingLearnOutcome = outcome
        }
    }

    /// Alternates two keys (Volume+ / Volume−) so the TV's volume bar flashes while the user aims the nose.
    public func startLocate(up: BlasterSignal, down: BlasterSignal) {
        guard !isLocating else { return }
        isLocating = true
        locateTask = Task { [weak self] in
            var raised = false
            var steps = 0
            while let self, self.isLocating, !Task.isCancelled, steps < Self.locateMaxSteps {
                do {
                    try await self.send(raised ? down : up)
                } catch {
                    if self.isLocating, !Task.isCancelled, !(error is CancellationError) {
                        self.onError?(error as? BlasterError ?? .failed(error.localizedDescription))
                    }
                    self.isLocating = false
                    return
                }
                raised.toggle()
                steps += 1
                await self.sleep(Self.locateInterval)
            }
            guard let self else { return }
            self.isLocating = false
            // Stopped right after "louder": step back so the volume ends where it was.
            if raised { try? await self.send(down) }
        }
    }

    public func stopLocate() {
        isLocating = false
        locateTask?.cancel()
        locateTask = nil
    }

    // MARK: - Write queue

    /// Runs `body` after every earlier command, once the link is ready.
    private func enqueue(_ body: @escaping @MainActor (BlasterSession) async throws -> Void) async throws {
        lastSequence += 1
        let sequence = lastSequence
        let previous = writeChain
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { throw CancellationError() }
            try await self.perform(sequence: sequence, body)
        }
        writeChain = Task { _ = await task.result }
        try await task.value
    }

    private func perform(sequence: Int, _ body: @MainActor (BlasterSession) async throws -> Void) async throws {
        if connection != .ready {
            // Presses queued behind one that already waited in vain fail at once.
            if sequence <= failedThrough { throw lastFailure }
            do {
                try await ensureReady()
            } catch {
                if !(error is CancellationError) {
                    failedThrough = lastSequence
                    lastFailure = error
                }
                throw error
            }
        }
        try await body(self)
        scheduleIdleDisconnect()
    }

    private func linkWrite(_ data: Data, toleratingLinkLoss: Bool = false) async throws {
        do {
            try await link.write(data)
        } catch let error as BlasterLinkError {
            let linkLost = error == .notConnected || error == .timeout
            if linkLost && toleratingLinkLoss { return }
            if linkLost, connection == .ready {
                // The link died under us; the adapter's own disconnect event may come later.
                connection = .idle
                idleTask?.cancel()
                connectIfNeeded()
            }
            throw map(error)
        }
    }

    private func transmit(_ key: BlasterSignal, hold: Bool) async throws {
        if usesLegacyProtocol {
            try await transmitLegacy(key, hold: hold)
            return
        }
        if hold, sigID != 0, lastSignal == key.signal {
            do {
                try await linkWrite(IRSignalBlob.hold(sigID: sigID, count: IRSignalBlob.holdCount(for: key.signal)))
                return
            } catch BlasterError.nothingToHold {
                // The press already ended on the bridge: start a new one.
            }
        }
        let blob: Data
        do {
            blob = try IRSignalBlob.encode(key.signal)
        } catch {
            throw BlasterError.unsupportedSignal
        }
        var retried = false
        while true {
            sigID = sigID == 255 ? 1 : sigID + 1
            lastSignal = key.signal
            var fragment = 0
            do {
                for write in IRSignalBlob.playWrites(blob, sigID: sigID, maxWrite: link.maxWriteLength) {
                    try await linkWrite(write)
                    fragment += 1
                }
                return
            } catch BlasterError.rejected where fragment == 0 && status == nil && key.legacy != nil {
                // No Status yet and PLAY is unknown: probably a protocol 1 bridge. Its Status will confirm.
                try await transmitLegacy(key, hold: hold)
                return
            } catch BlasterError.rejected where fragment > 0 && !retried {
                // Reassembly was lost on the bridge (e.g. a 2 s pause between fragments): start over once.
                retried = true
            }
        }
    }

    private func transmitLegacy(_ key: BlasterSignal, hold: Bool) async throws {
        guard let code = key.legacy else { throw BlasterError.firmwareTooOld }
        let frames = hold ? Self.holdFrames : BlasterProtocol.defaultFrames
        try await linkWrite(BlasterProtocol.send(code, frames: frames, hold: hold))
    }

    private func ensureReady() async throws {
        if connection == .ready { return }
        guard target != nil else { throw BlasterError.notPaired }
        if let error = availabilityError { throw error }
        if needsRepair { throw BlasterError.needsRepair }
        guard isActive else { throw CancellationError() }
        connectIfNeeded()
        switch await waitUntilReady() {
        case .ready:
            return
        case .cancelled:
            throw CancellationError()
        case .failed:
            if let error = availabilityError { throw error }
            if needsRepair { throw BlasterError.needsRepair }
            if lastLinkError == .pairingFailed { throw BlasterError.pairingFailed }
            throw BlasterError.unreachable
        }
    }

    private var availabilityError: BlasterError? {
        switch availability {
        case .poweredOff: return .bluetoothOff
        case .unauthorized: return .bluetoothDenied
        case .unsupported: return .bluetoothUnsupported
        case .unknown, .poweredOn: return nil
        }
    }

    private func waitUntilReady() async -> WaitResult {
        if connection == .ready { return .ready }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            readyWaiters.append((id, continuation))
            Task { [weak self, sleep] in
                await sleep(Self.readyTimeout)
                self?.resolveWaiter(id, .failed)
            }
        }
    }

    private func resolveWaiter(_ id: UUID, _ result: WaitResult) {
        guard let index = readyWaiters.firstIndex(where: { $0.id == id }) else { return }
        readyWaiters.remove(at: index).continuation.resume(returning: result)
    }

    private func resolveAllWaiters(_ result: WaitResult) {
        let waiters = readyWaiters
        readyWaiters = []
        for waiter in waiters { waiter.continuation.resume(returning: result) }
    }

    // MARK: - Connection

    private func connectIfNeeded() {
        guard isActive, let target, connection == .idle, !needsRepair else { return }
        connection = .connecting
        lastLinkError = nil
        link.connect(id: target.id)
    }

    /// Our own disconnect: no automatic reconnect follows, waiting commands are cancelled.
    private func dropConnection() {
        idleTask?.cancel()
        idleTask = nil
        connection = .idle
        link.disconnect() // idempotent; also clears any pending connection in the adapter
        resolveAllWaiters(.cancelled)
        finishLearning(.interrupted)
    }

    private func endPairing() {
        pairingCandidate = nil
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = nil
    }

    private func scheduleIdleDisconnect() {
        idleTask?.cancel()
        idleTask = Task { [weak self, sleep] in
            await sleep(Self.idleTimeout)
            guard !Task.isCancelled, let self, self.connection == .ready, !self.isLocating, !self.isLearning else { return }
            self.dropConnection()
        }
    }

    private func handle(_ event: BlasterLinkEvent) {
        switch event {
        case .availability(let value):
            let previous = availability
            availability = value
            if value == .poweredOn {
                connectIfNeeded()
            } else if value != .unknown || previous == .poweredOn {
                // Off, reset or permission revoked: iOS has dropped every connection.
                idleTask?.cancel()
                connection = .idle
                endPairing()
                stopLocate()
                resolveAllWaiters(.failed)
                finishLearning(.linkLost)
            }

        case .discovered(let blaster):
            guard isScanning else { return }
            if let index = discovered.firstIndex(where: { $0.id == blaster.id }) {
                discovered[index] = blaster
            } else {
                discovered.append(blaster)
            }

        case .ready:
            switch connection {
            case .ready:
                return
            case .idle:
                // The adapter reconnected on its own: keep it only if we want the link.
                guard isActive, target != nil, !needsRepair else {
                    link.disconnect()
                    return
                }
            case .connecting:
                break
            }
            connection = .ready
            needsRepair = false
            lastLinkError = nil
            if let candidate = pairingCandidate {
                endPairing()
                saved = candidate
                store.savedBlaster = candidate
            }
            resolveAllWaiters(.ready)
            scheduleIdleDisconnect()
            onReady?()

        case .disconnected(let error):
            guard connection != .idle else { return } // our own disconnect
            let wasReady = connection == .ready
            connection = .idle
            idleTask?.cancel()
            lastLinkError = error
            resolveAllWaiters(.failed)
            finishLearning(.linkLost)
            if pairingCandidate != nil {
                endPairing()
                onError?(error == .peerRemovedPairing ? .needsRepair : .pairingFailed)
                return
            }
            switch error {
            case .peerRemovedPairing:
                needsRepair = true
                stopLocate()
                onError?(.needsRepair)
            case .pairingFailed:
                stopLocate()
                onError?(.pairingFailed)
            default:
                // Out of range or the bridge restarted: wait for it to come back.
                if wasReady { connectIfNeeded() }
            }

        case .battery(let percent):
            batteryPercent = min(max(percent, 0), 100)

        case .status(let data):
            if let value = BlasterStatus(data: data) {
                status = value
                usesLegacyProtocol = !value.supportsPlay
            }

        case .capture(let data):
            guard isLearning, let result = captureAssembler.append(data) else { return }
            finishLearning(.captured(result))

        case .firmware(let version):
            firmwareVersion = version
        }
    }

    private func map(_ error: BlasterLinkError) -> BlasterError {
        switch error {
        case .notConnected, .timeout:
            return .unreachable
        case .pairingFailed:
            return .pairingFailed
        case .peerRemovedPairing:
            needsRepair = true
            return .needsRepair
        case .rejected(let code):
            switch BlasterRejection(rawValue: code) {
            case .queueFull: return .busy
            case .nothingToHold: return .nothingToHold
            case .unsupportedSignal: return .unsupportedSignal
            case .unavailable: return isLearning ? .noReceiver : .rejected
            default: return .rejected
            }
        case .failed(let message):
            return .failed(message)
        }
    }
}
