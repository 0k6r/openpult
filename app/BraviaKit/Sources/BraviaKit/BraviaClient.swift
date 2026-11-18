import Foundation

/// Talks to a Sony BRAVIA TV over its IP control interfaces:
/// REST JSON-RPC (`/sony/<service>`) and IRCC-IP (`/sony/IRCC`, SOAP).
public actor BraviaClient {
    public enum PairingStart: Equatable, Sendable {
        /// The TV now shows a PIN; call `completePairing(pin:)`.
        case pinShown
        /// The TV accepted the registration without a PIN.
        case paired
    }

    public nonisolated let host: String
    public nonisolated let clientID: String
    public private(set) var credentials: Credentials

    private let nickname: String
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date
    private let onCredentialsChange: (@Sendable (Credentials) -> Void)?

    private var requestID = 0
    private var irccPath = "/sony/IRCC"
    private var lastIRCCDate: Date?
    private var irccQueue: Task<Void, Never>?
    private var renewal: Task<Void, Error>?
    /// Set when the TV rejected the stored PIN: renewing again would only pop up
    /// new PINs on the TV screen, so the user has to pair again.
    private var renewalBlocked = false
    private var lastRenewalAttempt: Date?

    public static let defaultTimeout: TimeInterval = 4
    /// Device name the TV shows in its list of registered remotes. Not localized: the TV keeps it
    /// after the app language changes.
    public static let defaultNickname = "OpenPult (iPhone)"
    /// Cookie lives 14 days on the TV; renew well before that.
    static let cookieRenewAge: TimeInterval = 7 * 24 * 3600
    /// Some TVs ignore the first IRCC command after ~10 minutes of inactivity.
    static let irccIdleInterval: TimeInterval = 10 * 60
    static let renewalRetryInterval: TimeInterval = 60

    public init(
        host: String,
        credentials: Credentials = .none,
        clientID: String,
        nickname: String = BraviaClient.defaultNickname,
        transport: HTTPTransport = URLSessionTransport(),
        now: @escaping @Sendable () -> Date = { Date() },
        onCredentialsChange: (@Sendable (Credentials) -> Void)? = nil
    ) {
        self.host = host
        self.credentials = credentials
        self.clientID = clientID
        self.nickname = nickname
        self.transport = transport
        self.now = now
        self.onCredentialsChange = onCredentialsChange
    }

    /// Replaces credentials (e.g. a PSK typed by the user). Does not fire `onCredentialsChange`.
    public func updateCredentials(_ credentials: Credentials) {
        self.credentials = credentials
        renewalBlocked = false
    }

    // MARK: - Typed API

    /// Works without authentication; used for discovery.
    public func interfaceInformation(timeout: TimeInterval = defaultTimeout) async throws -> InterfaceInfo {
        let result = try await rpc("system", "getInterfaceInformation", timeout: timeout)
        guard let dict = result.first as? [String: Any] else { throw BraviaError.invalidResponse }
        return InterfaceInfo(
            productCategory: dict["productCategory"] as? String ?? "",
            productName: dict["productName"] as? String ?? "",
            modelName: dict["modelName"] as? String ?? "",
            interfaceVersion: dict["interfaceVersion"] as? String ?? ""
        )
    }

    public func powerStatus(timeout: TimeInterval = defaultTimeout) async throws -> PowerStatus {
        let result = try await rpc("system", "getPowerStatus", timeout: timeout)
        guard let status = (result.first as? [String: Any])?["status"] as? String else {
            throw BraviaError.invalidResponse
        }
        switch status {
        case "active": return .active
        case "standby": return .standby
        default: return .other(status)
        }
    }

    public func setPower(_ on: Bool) async throws {
        _ = try await rpc("system", "setPowerStatus", params: [["status": on]])
    }

    /// Requires the "private" auth level, so it doubles as a credentials check.
    public func systemInformation() async throws -> SystemInfo {
        let result = try await rpc("system", "getSystemInformation")
        guard let dict = result.first as? [String: Any] else { throw BraviaError.invalidResponse }
        let mac = dict["macAddr"] as? String
        return SystemInfo(
            model: dict["model"] as? String ?? "",
            name: dict["name"] as? String ?? "",
            macAddress: (mac?.isEmpty ?? true) ? nil : mac
        )
    }

    public func remoteControllerCodes() async throws -> [String: String] {
        let result = try await rpc("system", "getRemoteControllerInfo")
        return IRCCKeymap.parse(remoteControllerInfo: result)
    }

    /// MAC address for Wake-on-LAN from `getSystemSupportedFunction`.
    public func wakeOnLANMACAddress() async throws -> String? {
        let result = try await rpc("system", "getSystemSupportedFunction")
        guard let list = result.first as? [[String: Any]] else { return nil }
        let mac = list.first { ($0["option"] as? String)?.uppercased() == "WOL" }?["value"] as? String
        return (mac?.isEmpty ?? true) ? nil : mac
    }

    public func applications() async throws -> [TVApp] {
        let result = try await rpc("appControl", "getApplicationList")
        guard let list = result.first as? [[String: Any]] else { throw BraviaError.invalidResponse }
        return list.compactMap { item in
            guard let uri = item["uri"] as? String, !uri.isEmpty else { return nil }
            let title = (item["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? uri
            let icon = (item["icon"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
            return TVApp(title: title, uri: uri, iconURL: icon)
        }
    }

    public func launchApp(uri: String) async throws {
        _ = try await rpc("appControl", "setActiveApp", params: [["uri": uri]])
    }

    /// Types text into the TV's focused input field (version 1.0 takes a plain string).
    public func sendText(_ text: String) async throws {
        do {
            _ = try await rpc("appControl", "setTextForm", params: [text])
        } catch BraviaError.tv(let code, _) where code == 7 {
            throw BraviaError.keyboardInactive
        }
    }

    public func externalInputs() async throws -> [ExternalInput] {
        let result = try await rpc("avContent", "getCurrentExternalInputsStatus")
        guard let list = result.first as? [[String: Any]] else { throw BraviaError.invalidResponse }
        return list.compactMap { item in
            guard let uri = item["uri"] as? String, !uri.isEmpty else { return nil }
            return ExternalInput(
                uri: uri,
                title: item["title"] as? String ?? uri,
                label: item["label"] as? String ?? "",
                isConnected: item["connection"] as? Bool ?? false
            )
        }
    }

    public func setPlayContent(uri: String) async throws {
        _ = try await rpc("avContent", "setPlayContent", params: [["uri": uri]])
    }

    // MARK: - PIN pairing

    /// Step 1: ask the TV to show a PIN.
    public func startPairing() async throws -> PairingStart {
        let response = try await actRegister(pin: nil)
        switch response.status {
        case 401:
            return .pinShown
        case 200..<300:
            // Accepted without a PIN; without a cookie there is nothing to authenticate with.
            guard let cookie = response.cookie else { throw BraviaError.pairingRejected }
            renewalBlocked = false
            setCredentials(.pin(pin: "", cookie: cookie, issuedAt: now()))
            return .paired
        case 403, 404:
            throw BraviaError.pairingRejected
        default:
            throw BraviaError.from(code: response.status, message: "")
        }
    }

    /// Step 2: register with the PIN shown on screen and store the `auth` cookie.
    public func completePairing(pin rawPIN: String) async throws {
        let pin = rawPIN.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pin.isEmpty, pin.count <= 8, pin.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw BraviaError.invalidInput(String(
                localized: "Enter the digits shown on the TV screen.", bundle: .module,
                comment: "Error: the typed PIN is empty or not numeric."
            ))
        }
        let response = try await actRegister(pin: pin)
        switch response.status {
        case 200..<300:
            guard let cookie = response.cookie else { throw BraviaError.invalidResponse }
            renewalBlocked = false
            setCredentials(.pin(pin: pin, cookie: cookie, issuedAt: now()))
        case 401, 403:
            throw BraviaError.wrongPIN
        default:
            throw BraviaError.from(code: response.status, message: "")
        }
    }

    /// Renews the cookie if it is older than a week. Errors are ignored: the next
    /// request will retry renewal on 401/403. Attempts are spaced out so an offline
    /// TV doesn't slow down every refresh.
    public func renewIfNeeded() async {
        guard canRenew, case .pin(_, let cookie, let issuedAt) = credentials else { return }
        let isStale = cookie == nil || issuedAt.map { now().timeIntervalSince($0) > Self.cookieRenewAge } ?? true
        let recentlyTried = lastRenewalAttempt.map { now().timeIntervalSince($0) < Self.renewalRetryInterval } ?? false
        if isStale && !recentlyTried {
            try? await renewCookie()
        }
    }

    // MARK: - IRCC

    /// Sends a remote-control key. Commands are serialized so fast taps keep their order.
    public func sendIRCC(_ code: String) async throws {
        guard IRCC.isValidCode(code), !code.isEmpty else {
            throw BraviaError.invalidInput(String(localized: "Invalid button code.", bundle: .module, comment: "Error: malformed IRCC code."))
        }
        let previous = irccQueue
        let task = Task<Void, Error> {
            await previous?.value
            try await self.performIRCC(code)
        }
        irccQueue = Task { _ = await task.result }
        try await task.value
    }

    public func send(_ key: RemoteKey, keymap: IRCCKeymap) async throws {
        try await sendIRCC(keymap.code(for: key))
    }

    private func performIRCC(_ code: String) async throws {
        let isIdle = lastIRCCDate.map { now().timeIntervalSince($0) >= Self.irccIdleInterval } ?? true
        if isIdle {
            try await wakeIRCCHandler()
        }
        try await postIRCC(code, retryAuth: true, timeout: Self.defaultTimeout)
        lastIRCCDate = now()
    }

    /// Sends an empty IRCC code to wake the handler after inactivity. Any HTTP answer and
    /// a timeout (slow TV) are fine; only hard connection failures stop the real key.
    private func wakeIRCCHandler() async throws {
        let request = try irccRequest("", path: irccPath, timeout: 2)
        do {
            _ = try await transport.send(request)
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                return
            case .cancelled:
                throw CancellationError()
            default:
                throw BraviaError.from(urlError: error)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return
        }
    }

    private func postIRCC(_ code: String, retryAuth: Bool, timeout: TimeInterval) async throws {
        let usedCredentials = credentials
        var status = try await rawIRCC(code, path: irccPath, timeout: timeout)
        if status == 404 {
            // Some models only answer on the lowercase path (or vice versa).
            let alternate = irccPath == "/sony/IRCC" ? "/sony/ircc" : "/sony/IRCC"
            let alternateStatus = try await rawIRCC(code, path: alternate, timeout: timeout)
            if alternateStatus != 404 {
                irccPath = alternate
                status = alternateStatus
            }
        }
        switch status {
        case 200..<300:
            return
        case 401, 403:
            guard retryAuth else { throw BraviaError.unauthorized }
            try await reauthenticate(after: usedCredentials)
            try await postIRCC(code, retryAuth: false, timeout: timeout)
        case 404:
            throw BraviaError.unsupported
        case 500:
            throw BraviaError.keyRejected
        default:
            throw BraviaError.tv(code: status, message: "")
        }
    }

    private func rawIRCC(_ code: String, path: String, timeout: TimeInterval) async throws -> Int {
        let (_, response) = try await perform(try irccRequest(code, path: path, timeout: timeout))
        return response.statusCode
    }

    private func irccRequest(_ code: String, path: String, timeout: TimeInterval) throws -> URLRequest {
        var request = URLRequest(url: try url(path), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(IRCC.soapAction, forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(IRCC.envelope(code: code).utf8)
        applyAuth(to: &request)
        return request
    }

    // MARK: - Transport helpers

    func rpc(
        _ service: String,
        _ method: String,
        params: [Any] = [],
        version: String = "1.0",
        timeout: TimeInterval = defaultTimeout,
        retryAuth: Bool = true
    ) async throws -> [Any] {
        requestID += 1
        var request = URLRequest(url: try url("/sony/\(service)"), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONRPC.body(method: method, params: params, id: requestID, version: version)
        let usedCredentials = credentials
        applyAuth(to: &request)
        let (data, response) = try await perform(request)
        do {
            return try JSONRPC.parse(data: data, status: response.statusCode)
        } catch BraviaError.unauthorized where retryAuth {
            try await reauthenticate(after: usedCredentials)
            return try await rpc(service, method, params: params, version: version, timeout: timeout, retryAuth: false)
        }
    }

    private var canRenew: Bool {
        guard !renewalBlocked, case .pin(let pin, _, _) = credentials, !pin.isEmpty else { return false }
        return true
    }

    /// Called after a 401/403. If another request already renewed the cookie while this
    /// one was in flight, just retry; otherwise renew once (PIN credentials only).
    private func reauthenticate(after usedCredentials: Credentials) async throws {
        if credentials != usedCredentials, credentials.isConfigured {
            return
        }
        guard canRenew else { throw BraviaError.unauthorized }
        try await renewCookie()
    }

    private func renewCookie() async throws {
        if let renewal {
            return try await renewal.value
        }
        let task = Task<Void, Error> { try await self.performRenewal() }
        renewal = task
        defer { renewal = nil }
        try await task.value
    }

    private func performRenewal() async throws {
        guard case .pin(let pin, _, _) = credentials, !pin.isEmpty else {
            throw BraviaError.unauthorized
        }
        lastRenewalAttempt = now()
        let response = try await actRegister(pin: pin)
        if response.status == 401 || response.status == 403 {
            renewalBlocked = true
            throw BraviaError.unauthorized
        }
        guard (200..<300).contains(response.status), let cookie = response.cookie else {
            throw BraviaError.unauthorized
        }
        setCredentials(.pin(pin: pin, cookie: cookie, issuedAt: now()))
    }

    private func actRegister(pin: String?) async throws -> (status: Int, cookie: String?) {
        requestID += 1
        var request = URLRequest(url: try url("/sony/accessControl"), timeoutInterval: Self.defaultTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        let params: [Any] = [
            ["clientid": clientID, "nickname": nickname, "level": "private"],
            [["value": "yes", "function": "WOL"]],
        ]
        request.httpBody = try JSONRPC.body(method: "actRegister", params: params, id: requestID, version: "1.0")
        if let pin {
            let token = Data(":\(pin)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await perform(request)
        var status = response.statusCode
        if (200..<300).contains(status),
           let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let error = JSONRPC.errorPair(in: dict) {
            status = error.code
        }
        return (status, Self.authCookie(from: response))
    }

    private func setCredentials(_ new: Credentials) {
        credentials = new
        onCredentialsChange?(new)
    }

    private func applyAuth(to request: inout URLRequest) {
        switch credentials {
        case .none:
            break
        case .psk(let key):
            request.setValue(key, forHTTPHeaderField: "X-Auth-PSK")
        case .pin(_, let cookie, _):
            if let cookie, !cookie.isEmpty {
                request.setValue("auth=\(cookie)", forHTTPHeaderField: "Cookie")
            }
        }
    }

    private func url(_ path: String) throws -> URL {
        guard let url = URL(string: "http://\(host)\(path)"), url.host != nil else {
            throw BraviaError.invalidInput(String(
                localized: "Invalid TV address: \(host)", bundle: .module, comment: "Error: %@ is the host the user typed."
            ))
        }
        return url
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request)
        } catch let error as BraviaError {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw BraviaError.from(urlError: error)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw BraviaError.unreachable
        }
    }

    /// Extracts the `auth` cookie value. The TV's `Set-Cookie` has a non-RFC `Expires`,
    /// and several headers may be folded into one comma-separated value.
    static func authCookie(from response: HTTPURLResponse) -> String? {
        for (key, value) in response.allHeaderFields {
            guard let name = key as? String, name.caseInsensitiveCompare("Set-Cookie") == .orderedSame,
                  let header = value as? String else { continue }
            let parts = header.components(separatedBy: CharacterSet(charactersIn: ";,"))
            for part in parts {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("auth=") {
                    let cookie = String(trimmed.dropFirst("auth=".count))
                    if !cookie.isEmpty { return cookie }
                }
            }
        }
        return nil
    }
}
