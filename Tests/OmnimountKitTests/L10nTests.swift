import XCTest
@testable import OmnimountKit

/// Cada `L10n.t` del código apunta a una clave del catálogo, con el mismo
/// número de `%@` en inglés y en español. `OMNIMOUNT_LANG` fuerza el idioma.
final class L10nTests: XCTestCase {

    override func tearDown() {
        unsetenv("OMNIMOUNT_LANG")
        super.tearDown()
    }

    func testLanguageOverrideAndPlaceholders() {
        setenv("OMNIMOUNT_LANG", "en", 1)
        XCTAssertEqual(L10n.t("app.common.cancel"), "Cancel")
        XCTAssertEqual(L10n.t("error.mount.unmount", "busy"), "Could not unmount: busy")
        XCTAssertEqual(
            L10n.t("error.mount.unmount", "100% %@ leftover"),
            "Could not unmount: 100% %@ leftover")
        XCTAssertEqual(L10n.t("retro.pi.name"), "Raspberry Pi (generic)")

        setenv("OMNIMOUNT_LANG", "es", 1)
        XCTAssertEqual(L10n.t("app.common.cancel"), "Cancelar")
        XCTAssertEqual(L10n.t("error.mount.unmount", "busy"), "No se pudo desmontar: busy")
        XCTAssertEqual(L10n.t("retro.pi.name"), "Raspberry Pi (genérico)")
        XCTAssertEqual(L10n.t("missing.key.example"), "missing.key.example")

        setenv("OMNIMOUNT_LANG", "fr", 1)
        XCTAssertEqual(L10n.t("app.common.cancel"), "Cancel")
    }

    func testCatalogShapeAndPlaceholders() {
        let keyPattern = #"^(app|cli|error|disk|retro)\.[a-z][A-Za-z0-9]*\.[a-z][A-Za-z0-9]*$"#
        for (key, text) in L10nTable.entries {
            XCTAssertNotNil(key.range(of: keyPattern, options: .regularExpression), key)
            XCTAssertFalse(text.en.isEmpty, key)
            XCTAssertFalse(text.es.isEmpty, key)
            XCTAssertEqual(placeholderCount(text.es), placeholderCount(text.en), key)
        }
    }

    func testEveryCallSiteUsesACatalogKey() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let keys = try callSiteKeys(in: sources)
        let catalog = Set(L10nTable.entries.keys)
        let missing = keys.subtracting(catalog).sorted()
        let unused = catalog.subtracting(keys).sorted()
        XCTAssertTrue(missing.isEmpty, "Missing catalog entries:\n\(missing.joined(separator: "\n"))")
        XCTAssertTrue(unused.isEmpty, "Unused catalog entries:\n\(unused.joined(separator: "\n"))")
    }

    private func placeholderCount(_ text: String) -> Int {
        var count = 0
        var rest = Substring(text)
        while let range = rest.range(of: "%@") {
            count += 1
            rest = rest[range.upperBound...]
        }
        return count
    }

    private func callSiteKeys(in sources: URL) throws -> Set<String> {
        let pattern = #"L10n\.t\(\s*"((?:\\.|[^"\\])*)""#
        let regex = try NSRegularExpression(pattern: pattern)
        var keys: Set<String> = []
        guard let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            XCTFail("Could not read \(sources.path)")
            return []
        }
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let ns = text as NSString
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                var raw = ns.substring(with: match.range(at: 1))
                raw = raw.replacingOccurrences(of: "\\\\", with: "\\")
                raw = raw.replacingOccurrences(of: "\\\"", with: "\"")
                raw = raw.replacingOccurrences(of: "\\n", with: "\n")
                keys.insert(raw)
            }
        }
        return keys
    }
}
