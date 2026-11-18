import Foundation

public struct DiscoveredBlaster: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var rssi: Int

    public init(id: UUID, name: String, rssi: Int) {
        self.id = id
        self.name = name
        self.rssi = rssi
    }
}

public enum BlasterAvailability: Equatable, Sendable {
    case unknown, poweredOn, poweredOff, unauthorized, unsupported
}

public enum BlasterLinkError: Error, Equatable, Sendable {
    case notConnected
    /// Pairing was refused or cancelled, or the link could not be encrypted.
    case pairingFailed
    /// The bridge has lost its bond with this iPhone (e.g. its storage was erased).
    case peerRemovedPairing
    /// ATT application error from the bridge, see `BlasterRejection`.
    case rejected(UInt8)
    case timeout
    case failed(String)
}

public enum BlasterLinkEvent: Equatable, Sendable {
    case availability(BlasterAvailability)
    case discovered(DiscoveredBlaster)
    /// Connected, encrypted and the command characteristic is usable.
    case ready
    /// `nil` for a disconnect without an error.
    case disconnected(BlasterLinkError?)
    case battery(Int)
    case status(Data)
    /// A Capture characteristic notification (learning).
    case capture(Data)
    case firmware(String)
}

/// Bluetooth transport to the bridge. The CoreBluetooth implementation lives in the app target;
/// it must deliver events on the main actor.
@MainActor
public protocol BlasterLink: AnyObject {
    var onEvent: ((BlasterLinkEvent) -> Void)? { get set }
    /// Bytes per Command write (MTU − 3, at most 244); signals longer than that are fragmented.
    var maxWriteLength: Int { get }
    func startScan()
    func stopScan()
    /// Connects to a known bridge, waiting for it to appear if it is out of range.
    func connect(id: UUID)
    func disconnect()
    /// Write with response; throws `BlasterLinkError`.
    func write(_ data: Data) async throws
}

/// Used where Bluetooth is not wired up (tests of the network mode, previews).
@MainActor
public final class UnavailableBlasterLink: BlasterLink {
    public var onEvent: ((BlasterLinkEvent) -> Void)?
    public let maxWriteLength = 20

    public init() {}

    public func startScan() { onEvent?(.availability(.unsupported)) }
    public func stopScan() {}
    public func connect(id: UUID) { onEvent?(.availability(.unsupported)) }
    public func disconnect() {}
    public func write(_ data: Data) async throws { throw BlasterLinkError.notConnected }
}
