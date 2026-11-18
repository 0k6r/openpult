import XCTest
@testable import BraviaKit

/// SwiftPM compiles Resources/Localizable.xcstrings into en.lproj / ru.lproj. These tests read a language's
/// table directly, so they pass whatever the system language is. Completeness of the catalog itself is
/// checked by tools/l10n/check_catalogs.py.
final class LocalizationTests: XCTestCase {
    private func table(_ language: String) throws -> Bundle {
        let path = try XCTUnwrap(Bundle.module.path(forResource: language, ofType: "lproj"), "\(language).lproj is not bundled")
        return try XCTUnwrap(Bundle(path: path))
    }

    private func format(_ key: String, _ language: String, _ count: Int) throws -> String {
        let format = try table(language).localizedString(forKey: key, value: nil, table: nil)
        return String(format: format, locale: Locale(identifier: language), count)
    }

    func testEnglishIsTheSourceLanguage() {
        XCTAssertEqual(Bundle.module.developmentLocalization, "en")
        XCTAssertTrue(Bundle.module.localizations.contains("ru"))
    }

    func testRussianTableIsBundled() throws {
        let ru = try table("ru")
        XCTAssertEqual(ru.localizedString(forKey: "IR bridge connected", value: nil, table: nil), "ИК-приставка подключена")
        XCTAssertEqual(ru.localizedString(forKey: "TV error (%lld): %@.", value: nil, table: nil), "Ошибка телевизора (%lld): %@.")
    }

    func testPluralForms() throws {
        let key = "Updated codes for %lld buttons"
        XCTAssertEqual(try format(key, "en", 0), "Updated codes for 0 buttons")
        XCTAssertEqual(try format(key, "en", 1), "Updated codes for 1 button")
        XCTAssertEqual(try format(key, "en", 112), "Updated codes for 112 buttons")
        // Russian: one (1, 21), few (2–4, 22), many (0, 5–20, 25, 112).
        for (count, noun) in [(0, "кнопок"), (1, "кнопки"), (2, "кнопок"), (5, "кнопок"), (11, "кнопок"),
                              (21, "кнопки"), (22, "кнопок"), (25, "кнопок"), (112, "кнопок")] {
            XCTAssertEqual(try format(key, "ru", count), "Обновлены коды для \(count) \(noun)")
        }
    }

    func testEveryErrorHasADescription() {
        let bravia: [BraviaError] = [
            .unreachable, .localNetworkDenied, .unauthorized, .wrongPIN, .pairingRejected, .displayOff,
            .keyboardInactive, .unsupported, .keyRejected, .invalidResponse,
        ]
        let blaster: [BlasterError] = [
            .bluetoothOff, .bluetoothDenied, .bluetoothUnsupported, .notPaired, .unreachable, .pairingFailed,
            .needsRepair, .busy, .rejected, .firmwareTooOld, .unsupportedSignal, .noReceiver, .learnTimeout,
            .learnInterrupted, .notSupportedByBoard, .nothingToHold,
        ]
        let descriptions = bravia.map(\.errorDescription) + blaster.map(\.errorDescription)
        for (index, description) in descriptions.enumerated() {
            XCTAssertFalse(description?.isEmpty ?? true, "error #\(index) has no description")
        }
        XCTAssertEqual(Set(descriptions).count, descriptions.count, "two errors share a description")
    }

    func testErrorsWithDetailsKeepTheDetails() {
        let tv = BraviaError.tv(code: 7, message: "Illegal State").errorDescription ?? ""
        XCTAssertTrue(tv.contains("7") && tv.contains("Illegal State"), tv)
        XCTAssertFalse((BraviaError.tv(code: 7, message: "").errorDescription ?? "").isEmpty)
        let failed = BlasterError.failed("GATT 133").errorDescription ?? ""
        XCTAssertTrue(failed.contains("GATT 133"), failed)
    }

    func testDefaultNicknameIsNotLocalized() async throws {
        let transport = MockTransport { _ in .error(401, "Unauthorized", status: 401) }
        let client = BraviaClient(host: "192.168.1.50", clientID: "Pult:TEST", transport: transport)

        let start = try await client.startPairing()

        XCTAssertEqual(start, .pinShown)
        let params = try XCTUnwrap(transport.requests.first?.jsonBody?["params"] as? [Any])
        let registration = try XCTUnwrap(params.first as? [String: Any])
        XCTAssertEqual(registration["nickname"] as? String, "OpenPult (iPhone)")
    }
}
