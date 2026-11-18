import Foundation

/// Sony's JSON-RPC envelope: `{"method", "id", "params", "version"}`.
enum JSONRPC {
    static func body(method: String, params: [Any], id: Int, version: String) throws -> Data {
        let object: [String: Any] = [
            "method": method,
            "id": id,
            "params": params,
            "version": version,
        ]
        guard JSONSerialization.isValidJSONObject(object) else {
            throw BraviaError.invalidInput(String(
                localized: "Invalid request parameters.", bundle: .module,
                comment: "Error: a JSON-RPC request could not be encoded."
            ))
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Returns `result` or throws a `BraviaError` built from `error: [code, message]`
    /// or from the HTTP status code.
    static func parse(data: Data, status: Int) throws -> [Any] {
        let object = try? JSONSerialization.jsonObject(with: data)
        if let dict = object as? [String: Any] {
            if let error = errorPair(in: dict) {
                throw BraviaError.from(code: error.code, message: error.message)
            }
            if (200..<300).contains(status), let result = dict["result"] as? [Any] {
                return result
            }
        }
        if (200..<300).contains(status) {
            throw BraviaError.invalidResponse
        }
        throw BraviaError.from(code: status, message: HTTPURLResponse.localizedString(forStatusCode: status))
    }

    static func errorPair(in dict: [String: Any]) -> (code: Int, message: String)? {
        guard let error = dict["error"] as? [Any], let code = error.first as? Int else { return nil }
        let message = error.count > 1 ? (error[1] as? String ?? "") : ""
        return (code, message)
    }
}
