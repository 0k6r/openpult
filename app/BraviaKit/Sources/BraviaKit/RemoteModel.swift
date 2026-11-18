import Foundation
import Observation
import PultIR

/// App state shared by all screens.
///
/// Every async operation captures the `BraviaClient` it started with and checks
/// `isCurrent(_:)` before writing results, so a slow response can never resurrect a TV
/// the user has forgotten or overwrite data of a TV selected in the meantime.
@MainActor
@Observable
public final class RemoteModel {
    public enum Screen: Equatable {
        case discovery, pairing, remote, blasterSetup
        /// Choosing which TV the IR bridge controls (brand, code test, scan, learning).
        case irSetup
    }

    public enum TVPower: Equatable {
        case unknown, on, standby, offline
    }

    public struct Banner: Identifiable, Equatable {
        public enum Action: Equatable { case repair, repairBlaster }
        public let id = UUID()
        public var text: String
        public var isError: Bool
        public var action: Action?
    }

    public private(set) var screen: Screen = .discovery
    public private(set) var mode: ControlMode
    public private(set) var tv: SavedTV?
    public private(set) var power: TVPower = .unknown
    public var banner: Banner?

    // Discovery
    public private(set) var isScanning = false
    public private(set) var discovered: [DiscoveredTV] = []
    public private(set) var scanCompleted = false
    public private(set) var localNetworkDenied = false

    // Pairing / long operations
    public private(set) var pinRequested = false
    public private(set) var isWorking = false
    /// A power command is in flight in the current mode (network and IR are tracked separately,
    /// so a long Wake-on-LAN attempt never blocks the IR power key).
    public var isPowerBusy: Bool { mode == .infrared ? infraredPowerBusy : networkPowerBusy }
    private var networkPowerBusy = false
    private var infraredPowerBusy = false

    // Remote extras
    public private(set) var apps: [TVApp] = []
    public private(set) var inputs: [ExternalInput] = []
    public private(set) var keymap = IRCCKeymap()

    /// The BLE → IR bridge used when the TV is not reachable over Wi‑Fi.
    public let blaster: BlasterSession
    /// Which IR codes the bridge sends.
    public let infrared: InfraredController
    public var isInfrared: Bool { mode == .infrared }

    private let store: TVStore
    private let transport: HTTPTransport
    private let wake: @Sendable (_ mac: String, _ host: String) async -> Void
    private let pause: @Sendable (_ seconds: Double) async -> Void
    private let networkInfo: () -> (address: String, netmask: String)?
    private var isInBackground = false
    private var client: BraviaClient?
    private var clientToken = UUID()
    private var refreshInFlight: (client: BraviaClient, task: Task<Void, Never>)?

    public init(
        store: TVStore,
        transport: HTTPTransport = URLSessionTransport(),
        wake: @escaping @Sendable (_ mac: String, _ host: String) async -> Void = { await WakeOnLAN.send(mac: $0, host: $1) },
        pause: @escaping @Sendable (_ seconds: Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        networkInfo: @escaping () -> (address: String, netmask: String)? = NetworkInfo.currentIPv4,
        blaster: BlasterSession? = nil,
        profiles: ProfileDatabase? = nil
    ) {
        self.store = store
        self.transport = transport
        self.wake = wake
        self.pause = pause
        self.networkInfo = networkInfo
        self.blaster = blaster ?? BlasterSession(link: UnavailableBlasterLink(), store: store)
        infrared = InfraredController(store: store, profiles: profiles)
        mode = store.controlMode

        if let saved = store.savedTV {
            tv = saved
            keymap = IRCCKeymap(tvCodes: saved.irccCodes)
            makeClient(for: saved)
            screen = store.credentials.isConfigured ? .remote : .pairing
        }
        migrateSonyRemoteIfNeeded()
        if mode == .infrared {
            screen = infraredScreen
        }
        self.blaster.onReady = { [weak self] in self?.blasterBecameReady() }
        self.blaster.onError = { [weak self] error in
            guard let self, self.mode == .infrared else { return }
            self.showBlaster(error)
        }
    }

    // MARK: - Discovery

    public func startScan() async {
        guard !isScanning else { return }
        isScanning = true
        scanCompleted = false
        localNetworkDenied = false
        discovered = []
        defer {
            isScanning = false
            scanCompleted = true
        }

        guard let network = networkInfo() else {
            show(String(localized: "Couldn't get the iPhone's Wi‑Fi address. Connect to Wi‑Fi and search again.", bundle: .module, comment: "Error: no IPv4 address on Wi‑Fi, so the TV search cannot run."))
            return
        }
        let hosts = SubnetScanner.hosts(address: network.address, netmask: network.netmask)
        let transport = transport
        let clientID = store.clientID
        let outcome = await SubnetScanner.scan(
            hosts: hosts,
            concurrency: 64,
            probe: { host in
                try await RemoteModel.probe(host: host, transport: transport, clientID: clientID, timeout: 1.5)
            },
            onFound: { [weak self] tv in
                await self?.appendDiscovered(tv)
            }
        )
        discovered = outcome.found
        localNetworkDenied = outcome.localNetworkDenied
    }

    private func appendDiscovered(_ tv: DiscoveredTV) {
        if !discovered.contains(tv) { discovered.append(tv) }
    }

    nonisolated static func probe(
        host: String,
        transport: HTTPTransport,
        clientID: String,
        timeout: TimeInterval
    ) async throws -> DiscoveredTV? {
        let client = BraviaClient(host: host, clientID: clientID, transport: transport)
        let info = try await client.interfaceInformation(timeout: timeout)
        let category = info.productCategory.lowercased()
        guard category.isEmpty || category == "tv" else { return nil }
        return DiscoveredTV(host: host, modelName: info.displayName)
    }

    /// Accepts "192.168.1.50", "192.168.1.50:8080" or a pasted URL.
    public static func normalizeHost(_ raw: String) -> String? {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["http://", "https://"] where host.lowercased().hasPrefix(prefix) {
            host = String(host.dropFirst(prefix.count))
        }
        if let slash = host.firstIndex(of: "/") { host = String(host[..<slash]) }
        guard !host.isEmpty,
              host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == ":" }),
              URL(string: "http://\(host)/")?.host != nil
        else { return nil }
        return host
    }

    public func connectManually(host raw: String) async {
        guard !isWorking else { return }
        guard let host = Self.normalizeHost(raw) else {
            show(String(localized: "Enter the TV's IP address, for example, 192.168.1.50.", bundle: .module, comment: "Error: the typed TV address is not valid."))
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let tv = try await Self.probe(host: host, transport: transport, clientID: store.clientID, timeout: 4)
                ?? DiscoveredTV(host: host, modelName: "Sony BRAVIA")
            select(tv)
        } catch BraviaError.unsupported {
            // Old firmware without getInterfaceInformation: let the user try anyway.
            select(DiscoveredTV(host: host, modelName: "Sony BRAVIA"))
        } catch {
            show(error)
        }
    }

    public func select(_ discoveredTV: DiscoveredTV) {
        let previous = store.savedTV
        var saved: SavedTV
        if let previous, previous.host == discoveredTV.host {
            saved = previous
        } else {
            saved = SavedTV(host: discoveredTV.host, modelName: discoveredTV.modelName)
            store.credentials = .none
        }
        saved.modelName = discoveredTV.modelName
        store.savedTV = saved
        tv = saved
        keymap = IRCCKeymap(tvCodes: saved.irccCodes)
        apps = []
        inputs = []
        power = .unknown
        pinRequested = false
        makeClient(for: saved)
        if store.credentials.isConfigured {
            screen = .remote
            Task { await refresh() }
        } else {
            screen = .pairing
        }
    }

    // MARK: - Pairing

    public func requestPIN() async {
        guard let client, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            switch try await client.startPairing() {
            case .pinShown:
                if isCurrent(client) { pinRequested = true }
            case .paired:
                await finishPairing(client)
            }
        } catch {
            if isCurrent(client) { show(error) }
        }
    }

    public func submitPIN(_ pin: String) async {
        guard let client, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await client.completePairing(pin: pin)
            await finishPairing(client)
        } catch {
            if isCurrent(client) { show(error) }
        }
    }

    public func usePSK(_ rawKey: String) async {
        guard let client, !isWorking else { return }
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            show(String(localized: "Enter the Pre-Shared Key set in the TV's settings.", bundle: .module, comment: "Error: the Pre-Shared Key field is empty."))
            return
        }
        isWorking = true
        defer { isWorking = false }
        let previous = await client.credentials
        await client.updateCredentials(.psk(key))
        do {
            // getSystemInformation needs the "private" level: a wrong key fails here.
            let info = try await client.systemInformation()
            guard isCurrent(client) else { return }
            store.credentials = .psk(key)
            updateTV(of: client) { saved in
                if let mac = info.macAddress { saved.macAddress = mac }
                if !info.model.isEmpty { saved.modelName = info.model }
            }
            await finishPairing(client)
        } catch {
            await client.updateCredentials(previous)
            guard isCurrent(client) else { return }
            if case BraviaError.unauthorized = error {
                show(String(localized: "The key didn't work. Check the Pre-Shared Key and make sure the TV's authentication is set to Normal and Pre-Shared Key.", bundle: .module, comment: "Error: wrong PSK. Normal and Pre-Shared Key is a Sony menu option."))
            } else {
                show(error)
            }
        }
    }

    private func finishPairing(_ client: BraviaClient) async {
        let credentials = await client.credentials
        guard isCurrent(client) else { return }
        store.credentials = credentials
        pinRequested = false
        banner = Banner(text: String(localized: "TV connected", bundle: .module, comment: "Banner after pairing with the TV."), isError: false)
        screen = .remote
        await refresh()
    }

    /// Drops credentials and returns to pairing for the same TV.
    public func repair() {
        store.credentials = .none
        if let tv { makeClient(for: tv) }
        pinRequested = false
        banner = nil
        screen = .pairing
    }

    public func forgetTV() {
        store.forgetTV()
        client = nil
        clientToken = UUID()
        refreshInFlight = nil
        tv = nil
        keymap = IRCCKeymap()
        apps = []
        inputs = []
        power = .unknown
        pinRequested = false
        banner = nil
        screen = .discovery
    }

    // MARK: - Remote

    /// Updates power state and caches TV data (key codes, MAC for Wake-on-LAN).
    /// Concurrent calls for the same TV share one in-flight refresh.
    public func refresh() async {
        if mode == .infrared {
            blaster.activate()
            return
        }
        guard let client else { return }
        if let running = refreshInFlight, running.client === client {
            await running.task.value
            return
        }
        let task = Task { await self.performRefresh(client) }
        refreshInFlight = (client, task)
        await task.value
        if refreshInFlight?.client === client {
            refreshInFlight = nil
        }
    }

    private func performRefresh(_ client: BraviaClient) async {
        await client.renewIfNeeded()
        let status: PowerStatus
        do {
            status = try await client.powerStatus(timeout: 3)
        } catch {
            guard isCurrent(client) else { return }
            if let error = error as? BraviaError, error == .unreachable || error == .localNetworkDenied {
                power = .offline
            } else {
                power = .unknown
            }
            return
        }
        guard isCurrent(client) else { return }
        power = status == .active ? .on : .standby

        if tv?.irccCodes.isEmpty == true,
           let codes = try? await client.remoteControllerCodes(), !codes.isEmpty {
            updateTV(of: client) { $0.irccCodes = codes }
        }
        if isCurrent(client), tv?.macAddress == nil {
            var mac = try? await client.wakeOnLANMACAddress()
            if mac == nil { mac = (try? await client.systemInformation())?.macAddress }
            if let mac {
                updateTV(of: client) { $0.macAddress = mac }
            }
        }
    }

    /// Forces re-reading key codes from the TV.
    public func reloadKeyCodes() async {
        guard let client else { return }
        do {
            let codes = try await client.remoteControllerCodes()
            guard isCurrent(client) else { return }
            updateTV(of: client) { $0.irccCodes = codes }
            banner = Banner(text: String(localized: "Updated codes for \(codes.count) buttons", bundle: .module, comment: "Banner after reloading IRCC codes from the TV. %lld is the number of buttons."), isError: false)
        } catch {
            if isCurrent(client) { show(error) }
        }
    }

    /// Returns `false` if the key could not be delivered (lets hold-to-repeat stop).
    /// `isRepeat` marks auto-repeats of a held button; the IR bridge then extends
    /// the current transmission instead of queueing a new press.
    @discardableResult
    public func press(_ key: RemoteKey, isRepeat: Bool = false) async -> Bool {
        if mode == .infrared {
            return await pressInfrared(key, isRepeat: isRepeat)
        }
        guard let client else { return false }
        do {
            try await client.send(key, keymap: keymap)
            if isCurrent(client), power == .offline || power == .unknown {
                // The TV answered, so the shown status is stale.
                Task { await refresh() }
            }
            return true
        } catch {
            if isCurrent(client) { show(error) }
            return false
        }
    }

    public func togglePower() async {
        guard !isPowerBusy else { return }
        if mode == .infrared {
            // Over IR the power state is unknown: send the toggle key.
            infraredPowerBusy = true
            defer { infraredPowerBusy = false }
            await pressInfrared(.power, isRepeat: false)
            return
        }
        guard let client else { return }
        networkPowerBusy = true
        defer { networkPowerBusy = false }

        let status: PowerStatus
        do {
            status = try await client.powerStatus(timeout: 2)
        } catch BraviaError.unreachable {
            await wakeOverNetwork(client)
            return
        } catch {
            if isCurrent(client) { show(error) }
            return
        }
        guard isCurrent(client) else { return }

        if status == .active {
            do {
                try await client.setPower(false)
            } catch {
                do {
                    try await client.send(.power, keymap: keymap)
                } catch {
                    if isCurrent(client) { show(error) }
                    return
                }
            }
            if isCurrent(client) { power = .standby }
        } else if await turnOn(client), isCurrent(client) {
            power = .on
        }
    }

    /// TV is reachable but in standby: `setPowerStatus(true)`, falling back to the WakeUp key.
    private func turnOn(_ client: BraviaClient) async -> Bool {
        do {
            try await client.setPower(true)
            return true
        } catch {
            do {
                try await client.send(.wakeUp, keymap: keymap)
                return true
            } catch {
                if isCurrent(client) { show(error) }
                return false
            }
        }
    }

    private func wakeOverNetwork(_ client: BraviaClient) async {
        guard isCurrent(client), let tv else { return }
        guard let mac = tv.macAddress else {
            power = .offline
            show(String(localized: "The TV is offline. Turn it on with its button or the original remote. To turn it on from your phone, enable Remote Start on the TV.", bundle: .module, comment: "Error: no MAC address for Wake-on-LAN. Remote Start is a Sony menu item."))
            return
        }
        let progress = Banner(text: String(localized: "Turning on the TV…", bundle: .module, comment: "Banner while Wake-on-LAN is in progress."), isError: false)
        banner = progress
        for _ in 0..<8 {
            if Task.isCancelled || !isCurrent(client) { return }
            await wake(mac, tv.host)
            await pause(1.5)
            if Task.isCancelled || !isCurrent(client) { return }
            do {
                let status = try await client.powerStatus(timeout: 1.5)
                guard isCurrent(client) else { return }
                var isOn = true
                if status != .active {
                    isOn = await turnOn(client)
                }
                guard isCurrent(client) else { return }
                if isOn {
                    power = .on
                    if banner?.id == progress.id { banner = nil }
                } else {
                    power = .standby
                }
                return
            } catch BraviaError.unreachable {
                continue
            } catch {
                if isCurrent(client) { show(error) }
                return
            }
        }
        guard isCurrent(client) else { return }
        power = .offline
        show(String(localized: "The TV didn't respond. Turn it on with its button and check that Remote Start is on. After a long standby, the TV may not be reachable over the network.", bundle: .module, comment: "Error: Wake-on-LAN gave up. Remote Start is a Sony menu item."))
    }

    /// Returns `true` when the text was delivered.
    public func sendText(_ text: String) async -> Bool {
        guard mode == .network, let client, !text.isEmpty else { return false }
        do {
            try await client.sendText(text)
            if isCurrent(client) { banner = Banner(text: String(localized: "Text sent", bundle: .module, comment: "Banner after text was typed on the TV."), isError: false) }
            return true
        } catch {
            if isCurrent(client) { show(error) }
            return false
        }
    }

    public func loadApps() async {
        guard mode == .network, let client else { return }
        do {
            let list = try await client.applications().sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            if isCurrent(client) { apps = list }
        } catch {
            if isCurrent(client) { show(error) }
        }
    }

    public func launch(_ app: TVApp) async {
        guard mode == .network, let client else { return }
        do {
            try await client.launchApp(uri: app.uri)
        } catch {
            if isCurrent(client) { show(error) }
        }
    }

    public func loadInputs() async {
        guard mode == .network, let client else {
            inputs = []
            return
        }
        do {
            let list = try await client.externalInputs()
            if isCurrent(client) { inputs = list }
        } catch {
            guard isCurrent(client) else { return }
            inputs = []
            // Old firmware may lack the method: the sheet still offers HDMI keys.
            if (error as? BraviaError) != .unsupported { show(error) }
        }
    }

    public func switchInput(_ input: ExternalInput) async {
        guard mode == .network, let client else {
            if let port = input.hdmiPort, let key = RemoteKey.hdmi(port: port) {
                await press(key)
            }
            return
        }
        do {
            try await client.setPlayContent(uri: input.uri)
        } catch {
            guard isCurrent(client) else { return }
            if let port = input.hdmiPort, let key = RemoteKey.hdmi(port: port) {
                await press(key)
            } else {
                show(error)
            }
        }
    }

    // MARK: - IR bridge

    /// A Sony TV paired over Wi‑Fi: its codes work over IR as they are.
    private func migrateSonyRemoteIfNeeded() {
        if infrared.remote == nil, store.savedTV != nil {
            infrared.use(.sony(keymap: keymap))
        }
    }

    /// Switches to the BLE → IR bridge (no Wi‑Fi needed).
    public func useInfrared() {
        migrateSonyRemoteIfNeeded()
        mode = .infrared
        store.controlMode = .infrared
        banner = nil
        screen = infraredScreen
        if blaster.saved != nil { blaster.activate() }
    }

    private var infraredScreen: Screen {
        if blaster.saved == nil { return .blasterSetup }
        return infrared.remote == nil ? .irSetup : .remote
    }

    /// Pick another TV for the IR bridge.
    public func chooseTV() {
        banner = nil
        screen = .irSetup
    }

    public func finishIRSetup(_ remote: IRRemote) {
        infrared.use(remote)
        banner = Banner(text: String(localized: "Remote for “\(remote.displayName)” is ready", bundle: .module, comment: "Banner after IR setup. %@ is the TV or profile name."), isError: false)
        screen = .remote
    }

    /// Leaves the TV choice without changing it (only when a remote is already set up).
    public func cancelIRSetup() {
        guard infrared.remote != nil else { return }
        screen = .remote
    }

    /// Sends a signal during setup (code test, scan); errors are shown in the banner.
    @discardableResult
    public func sendIR(_ signal: BlasterSignal) async -> Bool {
        guard !isInBackground else { return false }
        blaster.activate()
        do {
            try await blaster.send(signal)
            return true
        } catch {
            if mode == .infrared { showBlaster(error) }
            return false
        }
    }

    public func startLocate() {
        guard let signals = infrared.locateSignals() else {
            show(String(localized: "Aiming needs both volume buttons or Mute.", bundle: .module, comment: "Error: the TV profile lacks the keys used for aiming the bridge."))
            return
        }
        blaster.activate()
        blaster.startLocate(up: signals.up, down: signals.down)
    }

    public func isAvailable(_ key: RemoteKey) -> Bool {
        mode == .network || infrared.isAvailable(key)
    }

    /// Back to Sony IP Control over Wi‑Fi.
    public func useNetwork() {
        blaster.deactivate()
        mode = .network
        store.controlMode = .network
        banner = nil
        if tv == nil {
            screen = .discovery
        } else if store.credentials.isConfigured {
            screen = .remote
            Task { await refresh() }
        } else {
            screen = .pairing
        }
    }

    public func pairBlaster(_ discovered: DiscoveredBlaster) {
        banner = nil
        blaster.pair(discovered)
    }

    public func forgetBlaster() {
        blaster.forget()
        banner = nil
        if mode == .infrared { screen = .blasterSetup }
    }

    /// After the bridge lost its bond: start the setup again (the user also forgets it in iOS Settings).
    public func repairBlaster() {
        forgetBlaster()
    }

    /// Reboots the bridge into its UF2 bootloader for a firmware update over USB.
    public func enterBlasterBootloader() async {
        do {
            try await blaster.enterBootloader()
            banner = Banner(text: String(localized: "The bridge is in firmware update mode. Connect it to a computer over USB.", bundle: .module, comment: "Banner after rebooting the bridge into its UF2 bootloader."), isError: false)
        } catch {
            show(error)
        }
    }

    /// The app went to the background: release the bridge so it can sleep.
    public func enterBackground() {
        isInBackground = true
        blaster.deactivate()
    }

    public func enterForeground() {
        isInBackground = false
    }

    @discardableResult
    private func pressInfrared(_ key: RemoteKey, isRepeat: Bool) async -> Bool {
        guard !isInBackground else { return false }
        guard let signal = infrared.signal(for: key, newPress: !isRepeat) else {
            if !isRepeat {
                show(Self.learnableKeys.contains(key)
                     ? String(localized: "No code for this button. You can learn it: ⋯ → Learn Buttons.", bundle: .module, comment: "Error: the TV profile has no code for this key. Learn Buttons is a menu item.")
                     : String(localized: "This TV doesn't have this button.", bundle: .module, comment: "Error: the key does not exist on this TV."))
            }
            return false
        }
        // A key press means the app is in the foreground.
        blaster.activate()
        do {
            try await blaster.send(signal, hold: isRepeat)
            return true
        } catch {
            if mode == .infrared { showBlaster(error) }
            return false
        }
    }

    private func showBlaster(_ error: Error) {
        if let error = error as? BlasterError, error == .needsRepair {
            banner = Banner(text: error.localizedDescription, isError: true, action: .repairBlaster)
        } else {
            show(error)
        }
    }

    /// Keys the learning screen offers (all buttons of the on-screen remote).
    public static let learnableKeys: Set<RemoteKey> = Set(RemoteKey.allCases)

    /// The first hold repeat goes out while the press is still on air, so the TV sees one continuous
    /// press (like a held physical remote) and applies its own auto-repeat. Over Wi‑Fi every repeat is a
    /// separate IRCC key, so a keyboard-like initial delay is used instead.
    public var holdDelay: Duration { isInfrared ? .milliseconds(100) : .milliseconds(400) }

    private func blasterBecameReady() {
        guard mode == .infrared, screen == .blasterSetup else { return }
        screen = infraredScreen
        banner = Banner(text: L10n.blasterConnected, isError: false)
    }

    // MARK: - Helpers

    /// Network results are dropped once the user switched to another TV or to the IR bridge.
    private func isCurrent(_ candidate: BraviaClient) -> Bool {
        mode == .network && client === candidate
    }

    /// Applies a change to the saved TV, but only if `client` still talks to it.
    private func updateTV(of client: BraviaClient, _ change: (inout SavedTV) -> Void) {
        guard isCurrent(client), var saved = tv else { return }
        change(&saved)
        tv = saved
        store.savedTV = saved
        keymap = IRCCKeymap(tvCodes: saved.irccCodes)
        infrared.refreshSony(keymap: keymap)
    }

    private func makeClient(for tv: SavedTV) {
        let token = UUID()
        clientToken = token
        refreshInFlight = nil
        client = BraviaClient(
            host: tv.host,
            credentials: store.credentials,
            clientID: store.clientID,
            transport: transport,
            onCredentialsChange: { [weak self] credentials in
                // Renewals from a replaced client (after repair/forget/select) are ignored.
                Task { @MainActor in
                    guard let self, self.clientToken == token else { return }
                    self.store.credentials = credentials
                }
            }
        )
    }

    private func show(_ text: String) {
        banner = Banner(text: text, isError: true)
    }

    private func show(_ error: Error) {
        if error is CancellationError { return }
        if let error = error as? BraviaError {
            switch error {
            case .unreachable, .localNetworkDenied:
                if screen == .remote { power = .offline }
            default:
                break
            }
            banner = Banner(
                text: error.localizedDescription,
                isError: true,
                action: (error == .unauthorized && screen == .remote) ? .repair : nil
            )
        } else {
            banner = Banner(text: error.localizedDescription, isError: true)
        }
    }
}
