import Foundation
@testable import BraviaKit

struct MockResponse {
    var status: Int = 200
    var body: Data = Data()
    var headers: [String: String] = [:]

    static func json(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> MockResponse {
        MockResponse(status: status, body: try! JSONSerialization.data(withJSONObject: object), headers: headers)
    }

    static func result(_ result: [Any]) -> MockResponse {
        .json(["result": result, "id": 1])
    }

    static func error(_ code: Int, _ message: String, status: Int = 200) -> MockResponse {
        .json(["error": [code, message], "id": 1], status: status)
    }

    static let ok = MockResponse(status: 200)
}

/// Records requests and answers them with a handler. Thread-safe.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var handler: (URLRequest) throws -> MockResponse

    init(handler: @escaping (URLRequest) throws -> MockResponse = { _ in .ok }) {
        self.handler = handler
    }

    func setHandler(_ handler: @escaping (URLRequest) throws -> MockResponse) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    private func record(_ request: URLRequest) -> (URLRequest) throws -> MockResponse {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(request)
        return handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let handler = record(request)
        let response = try handler(request)
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        )!
        return (response.body, http)
    }
}

extension URLRequest {
    var jsonBody: [String: Any]? {
        guard let body = httpBody else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    var rpcMethod: String? { jsonBody?["method"] as? String }

    var bodyString: String {
        httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    var path: String { url?.path ?? "" }

    var irccCode: String? {
        guard let start = bodyString.range(of: "<IRCCCode>"),
              let end = bodyString.range(of: "</IRCCCode>") else { return nil }
        return String(bodyString[start.upperBound..<end.lowerBound])
    }
}

/// Mutable clock for time-dependent logic.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = start
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}
