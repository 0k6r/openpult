import CoreBluetooth
import BraviaKit

/// CoreBluetooth transport to the «OpenPult» bridge. All callbacks run on the main queue.
///
/// The central manager is created lazily, so the Bluetooth permission prompt only appears
/// once the user switches to the IR bridge. The adapter never reconnects on its own:
/// after it reports `.disconnected`, reconnecting is the session's decision.
@MainActor
final class CoreBluetoothBlasterLink: NSObject, BlasterLink {
    var onEvent: ((BlasterLinkEvent) -> Void)?

    private static let service = CBUUID(string: BlasterProtocol.serviceUUID)
    private static let commandUUID = CBUUID(string: BlasterProtocol.commandUUID)
    private static let statusUUID = CBUUID(string: BlasterProtocol.statusUUID)
    private static let captureUUID = CBUUID(string: BlasterProtocol.captureUUID)
    private static let batteryService = CBUUID(string: BlasterProtocol.batteryServiceUUID)
    private static let batteryLevel = CBUUID(string: BlasterProtocol.batteryLevelUUID)
    private static let deviceInfoService = CBUUID(string: BlasterProtocol.deviceInfoServiceUUID)
    private static let firmwareRevision = CBUUID(string: BlasterProtocol.firmwareRevisionUUID)
    private static let writeTimeout: Duration = .seconds(3)
    /// Fallback if the disconnect callback for our own cancel never arrives.
    private static let cancelGrace: Duration = .milliseconds(1500)

    private enum Phase {
        case idle, connecting, discovering
        /// Subscribed to / reading the encrypted Status: this is where iOS pairs.
        case securing
        case ready
    }

    private var manager: CBCentralManager?
    private var wantsScan = false
    private var targetID: UUID?
    /// Scanning only to find `targetID`, which iOS did not have cached.
    private var scanningForTarget = false
    private var peripheral: CBPeripheral?
    private var phase: Phase = .idle
    private var command: CBCharacteristic?
    private var capture: CBCharacteristic?
    /// A peripheral we cancelled whose disconnect callback is still due.
    private var cancelled: CBPeripheral?
    /// `connect` deferred until that callback, so the stale disconnect cannot kill the new attempt.
    private var connectAfterCancel = false
    private var pendingWrites: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    // MARK: BlasterLink

    var maxWriteLength: Int {
        guard let peripheral, phase == .ready else { return 20 }
        return min(max(peripheral.maximumWriteValueLength(for: .withoutResponse), 20), 244)
    }

    func startScan() {
        wantsScan = true
        let manager = ensureManager()
        guard manager.state == .poweredOn else { return }
        scan(manager)
        reportConnectedBridges(manager)
    }

    func stopScan() {
        wantsScan = false
        guard let manager, manager.state == .poweredOn, !scanningForTarget else { return }
        manager.stopScan()
    }

    func connect(id: UUID) {
        targetID = id
        let manager = ensureManager()
        if manager.state == .poweredOn { startConnection(manager) }
    }

    func disconnect() {
        targetID = nil
        connectAfterCancel = false
        stopTargetScan()
        resetLink(failing: .notConnected)
        if let peripheral { cancel(peripheral) }
        peripheral = nil
    }

    func write(_ data: Data) async throws {
        guard phase == .ready, let peripheral, let command else { throw BlasterLinkError.notConnected }
        let id = UUID()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pendingWrites.append((id, continuation))
            peripheral.writeValue(data, for: command, type: .withResponse)
            Task { [weak self] in
                try? await Task.sleep(for: Self.writeTimeout)
                // A lost write response desynchronises the FIFO: drop the link.
                guard let self, self.pendingWrites.contains(where: { $0.id == id }) else { return }
                self.fail(.timeout)
            }
        }
    }

    // MARK: Connection management

    private func ensureManager() -> CBCentralManager {
        if let manager { return manager }
        // The app shows its own "Bluetooth is off" state.
        let created = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        manager = created
        return created
    }

    private func scan(_ manager: CBCentralManager) {
        manager.scanForPeripherals(withServices: [Self.service], options: nil)
    }

    /// A bridge already connected to this iPhone does not advertise; list it anyway.
    private func reportConnectedBridges(_ manager: CBCentralManager) {
        for connected in manager.retrieveConnectedPeripherals(withServices: [Self.service]) {
            onEvent?(.discovered(DiscoveredBlaster(id: connected.identifier, name: connected.name ?? "OpenPult", rssi: -50)))
        }
    }

    private func stopTargetScan() {
        guard scanningForTarget else { return }
        scanningForTarget = false
        if !wantsScan, let manager, manager.state == .poweredOn { manager.stopScan() }
    }

    private func startConnection(_ manager: CBCentralManager) {
        guard let targetID else { return }
        if let current = peripheral {
            if current.identifier == targetID {
                switch current.state {
                case .connected, .connecting:
                    if phase == .ready { onEvent?(.ready) }
                    return
                case .disconnecting:
                    connectAfterCancel = true
                    return
                case .disconnected:
                    attach(current, manager: manager)
                    return
                @unknown default:
                    return
                }
            }
            // Switching to another bridge.
            resetLink(failing: .notConnected)
            cancel(current)
            peripheral = nil
        }
        if let known = manager.retrievePeripherals(withIdentifiers: [targetID]).first {
            attach(known, manager: manager)
        } else {
            scanningForTarget = true
            scan(manager)
        }
    }

    private func attach(_ candidate: CBPeripheral, manager: CBCentralManager) {
        peripheral = candidate
        candidate.delegate = self
        phase = .connecting
        if candidate === cancelled {
            connectAfterCancel = true
            Task { [weak self] in
                try? await Task.sleep(for: Self.cancelGrace)
                guard let self, self.connectAfterCancel, self.peripheral === candidate else { return }
                self.cancelled = nil
                self.connectAfterCancel = false
                manager.connect(candidate, options: nil)
            }
            return
        }
        // No timeout: iOS completes the connection whenever the bridge shows up.
        manager.connect(candidate, options: nil)
    }

    private func cancel(_ target: CBPeripheral) {
        guard let manager else { return }
        let hasLink = target.state == .connected || target.state == .connecting || target.state == .disconnecting
        manager.cancelPeripheralConnection(target)
        if hasLink { cancelled = target }
    }

    private func resetLink(failing error: BlasterLinkError) {
        phase = .idle
        command = nil
        capture = nil
        let writes = pendingWrites
        pendingWrites = []
        for write in writes { write.continuation.resume(throwing: error) }
    }

    private func finishWrite(id: UUID, error: BlasterLinkError?) {
        guard let index = pendingWrites.firstIndex(where: { $0.id == id }) else { return }
        let write = pendingWrites.remove(at: index)
        if let error {
            write.continuation.resume(throwing: error)
        } else {
            write.continuation.resume()
        }
    }

    /// Drops the link on our side and reports it; the session decides whether to reconnect.
    private func fail(_ error: BlasterLinkError) {
        let current = peripheral
        resetLink(failing: error)
        if let current { cancel(current) }
        peripheral = nil
        targetID = nil
        connectAfterCancel = false
        stopTargetScan()
        onEvent?(.disconnected(error))
    }

    /// The link ended on the bridge's or iOS's side.
    private func lost(_ error: BlasterLinkError?) {
        let wasSecuring = phase == .securing
        resetLink(failing: .notConnected)
        peripheral = nil
        targetID = nil
        connectAfterCancel = false
        stopTargetScan()
        // A drop while iOS was pairing means the pairing did not complete.
        let reported: BlasterLinkError? = wasSecuring && error != .peerRemovedPairing ? .pairingFailed : error
        onEvent?(.disconnected(reported))
    }

    private static func map(_ error: Error?) -> BlasterLinkError? {
        guard let error else { return nil }
        let nsError = error as NSError
        if nsError.domain == CBATTErrorDomain {
            switch CBATTError.Code(rawValue: nsError.code) {
            case .insufficientEncryption, .insufficientAuthentication, .insufficientEncryptionKeySize:
                return .pairingFailed
            default:
                return .rejected(UInt8(truncatingIfNeeded: nsError.code))
            }
        }
        if nsError.domain == CBErrorDomain {
            switch CBError.Code(rawValue: nsError.code) {
            case .peerRemovedPairingInformation:
                return .peerRemovedPairing
            case .encryptionTimedOut, .tooManyLEPairedDevices:
                return .pairingFailed
            case .notConnected, .peripheralDisconnected, .connectionFailed, .connectionTimeout, .operationCancelled:
                return .notConnected
            default:
                break
            }
        }
        return .failed(error.localizedDescription)
    }

    private static func availability(_ state: CBManagerState) -> BlasterAvailability {
        switch state {
        case .poweredOn: return .poweredOn
        case .poweredOff: return .poweredOff
        case .unauthorized: return .unauthorized
        case .unsupported: return .unsupported
        case .resetting, .unknown: return .unknown
        @unknown default: return .unknown
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension CoreBluetoothBlasterLink: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            let state = central.state
            guard state == .poweredOn else {
                // `.unknown` right after creation keeps pending intents; anything else ends the link.
                let hadLink = peripheral != nil || (targetID != nil && state != .unknown)
                if state != .unknown || peripheral != nil {
                    resetLink(failing: .notConnected)
                    peripheral = nil
                    cancelled = nil
                    connectAfterCancel = false
                    scanningForTarget = false
                    targetID = nil
                }
                onEvent?(.availability(Self.availability(state)))
                if hadLink { onEvent?(.disconnected(.notConnected)) }
                return
            }
            onEvent?(.availability(.poweredOn))
            if wantsScan {
                scan(central)
                reportConnectedBridges(central)
            }
            if targetID != nil { startConnection(central) }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        MainActor.assumeIsolated {
            let found = DiscoveredBlaster(id: peripheral.identifier, name: name ?? peripheral.name ?? "OpenPult", rssi: RSSI.intValue)
            onEvent?(.discovered(found))
            if scanningForTarget, peripheral.identifier == targetID {
                stopTargetScan()
                attach(peripheral, manager: central)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            guard peripheral === self.peripheral else { return }
            phase = .discovering
            peripheral.discoverServices([Self.service, Self.batteryService, Self.deviceInfoService])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === self.peripheral else { return }
            lost(Self.map(error) ?? .notConnected)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            if peripheral === cancelled {
                // The callback for our own cancel: already reported (or requested by the session).
                cancelled = nil
                if connectAfterCancel, peripheral === self.peripheral, targetID == peripheral.identifier {
                    connectAfterCancel = false
                    central.connect(peripheral, options: nil)
                }
                return
            }
            guard peripheral === self.peripheral else { return }
            lost(Self.map(error))
        }
    }
}

// MARK: - CBPeripheralDelegate

extension CoreBluetoothBlasterLink: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === self.peripheral else { return }
            let services = peripheral.services ?? []
            guard error == nil, let main = services.first(where: { $0.uuid == Self.service }) else {
                fail(Self.map(error) ?? .failed(String(localized: "this isn't an OpenPult bridge", comment: "Shown after \"Bluetooth error:\". OpenPult is the bridge name.")))
                return
            }
            peripheral.discoverCharacteristics([Self.commandUUID, Self.statusUUID, Self.captureUUID], for: main)
            for service in services where service.uuid == Self.batteryService {
                peripheral.discoverCharacteristics([Self.batteryLevel], for: service)
            }
            for service in services where service.uuid == Self.deviceInfoService {
                peripheral.discoverCharacteristics([Self.firmwareRevision], for: service)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === self.peripheral else { return }
            let characteristics = service.characteristics ?? []
            switch service.uuid {
            case Self.service:
                guard error == nil,
                      let command = characteristics.first(where: { $0.uuid == Self.commandUUID }),
                      let status = characteristics.first(where: { $0.uuid == Self.statusUUID })
                else {
                    fail(Self.map(error) ?? .failed(String(localized: "the required characteristics are missing", comment: "Shown after \"Bluetooth error:\". GATT characteristics of the bridge.")))
                    return
                }
                self.command = command
                capture = characteristics.first(where: { $0.uuid == Self.captureUUID }) // protocol 2 only
                phase = .securing
                // Status and its CCC require encryption: subscribing makes iOS pair or reuse the bond.
                peripheral.setNotifyValue(true, for: status)
            case Self.batteryService:
                for characteristic in characteristics where characteristic.uuid == Self.batteryLevel {
                    peripheral.readValue(for: characteristic)
                    if characteristic.properties.contains(.notify) {
                        peripheral.setNotifyValue(true, for: characteristic)
                    }
                }
            case Self.deviceInfoService:
                for characteristic in characteristics where characteristic.uuid == Self.firmwareRevision {
                    peripheral.readValue(for: characteristic)
                }
            default:
                break
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === self.peripheral, characteristic.uuid == Self.statusUUID else { return }
            if let error {
                fail(Self.map(error) ?? .pairingFailed)
                return
            }
            // Confirm with an encrypted read before calling the link ready.
            if phase == .securing { peripheral.readValue(for: characteristic) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === self.peripheral else { return }
            if characteristic.uuid == Self.statusUUID, phase == .securing {
                if let error {
                    fail(Self.map(error) ?? .pairingFailed)
                    return
                }
                phase = .ready
                onEvent?(.ready)
                // Learning results arrive as Capture notifications (bridges with a receiver).
                if let capture { peripheral.setNotifyValue(true, for: capture) }
            }
            guard error == nil, let value = characteristic.value else { return }
            switch characteristic.uuid {
            case Self.statusUUID:
                onEvent?(.status(value))
            case Self.captureUUID:
                onEvent?(.capture(value))
            case Self.batteryLevel:
                if let level = value.first { onEvent?(.battery(Int(level))) }
            case Self.firmwareRevision:
                onEvent?(.firmware(String(decoding: value, as: UTF8.self)))
            default:
                break
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === self.peripheral, characteristic.uuid == Self.commandUUID,
                  let first = pendingWrites.first else { return }
            // Writes with response complete in order.
            finishWrite(id: first.id, error: Self.map(error))
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        MainActor.assumeIsolated {
            // A firmware update changed the GATT layout: reconnect and rediscover.
            guard peripheral === self.peripheral,
                  invalidatedServices.contains(where: { $0.uuid == Self.service }) else { return }
            fail(.notConnected)
        }
    }
}
