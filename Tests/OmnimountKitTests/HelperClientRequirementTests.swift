import Security
import XCTest
@testable import OmnimountKit

final class HelperClientRequirementTests: XCTestCase {

    private func compile(_ text: String) -> SecRequirement? {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    func testRequirementCompilesAndPinsIdentifiers() throws {
        let text = try XCTUnwrap(HelperClientRequirement.clientRequirement(teamIdentifier: "ABCDE12345"))
        XCTAssertEqual(text, "anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\""
                       + " and (identifier \"org.omnimount.app\" or identifier \"org.omnimount.helper-integration\")")
        XCTAssertNotNil(compile(text))
    }

    func testTeamRequirementCompiles() throws {
        let text = try XCTUnwrap(HelperClientRequirement.teamRequirement(teamIdentifier: "Z9Y8X7W6V5"))
        XCTAssertNotNil(compile(text))
        XCTAssertFalse(text.contains("identifier"))
    }

    func testMissingOrMalformedTeamIdentifierYieldsNoRequirement() {
        for team in [nil, "", "ABCDE1234", "ABCDE123456", "abcde12345", "ABCDE\"1234", "ABCDE 1234", "ÁBCDE12345"] as [String?] {
            XCTAssertNil(HelperClientRequirement.clientRequirement(teamIdentifier: team), String(describing: team))
            XCTAssertNil(HelperClientRequirement.teamRequirement(teamIdentifier: team), String(describing: team))
        }
    }

    func testRequirementRejectsTestRunnerBinary() throws {
        // El ejecutable de las pruebas no está firmado por ningún equipo.
        let text = try XCTUnwrap(HelperClientRequirement.clientRequirement(teamIdentifier: "ABCDE12345"))
        let requirement = try XCTUnwrap(compile(text))
        var code: SecCode?
        XCTAssertEqual(SecCodeCopySelf([], &code), errSecSuccess)
        let selfCode = try XCTUnwrap(code)
        XCTAssertNotEqual(SecCodeCheckValidity(selfCode, [], requirement), errSecSuccess)
    }
}
