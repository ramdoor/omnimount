import XCTest
@testable import OmnimountKit

final class ScriptQuotingTests: XCTestCase {
    /// Valores con todo lo que el shell o AppleScript podrían interpretar.
    private let samples = [
        "plain",
        "/Applications/My Apps/Omnimount.app/Contents/MacOS",
        "it's",
        "''",
        #"double "quoted""#,
        "$(echo substituted)",
        "`echo backtick`",
        "a; echo second",
        "a && b || c | d > e < f",
        #"back\slash\"#,
        "$HOME ${PATH} * ? [x] ~",
        "line1\nline2",
        "acentuado á ñ 💾",
        "",
    ]

    func testPosixQuoteRoundTripsThroughSh() throws {
        for value in samples {
            let script = "printf '%s' " + ScriptQuoting.posixShellQuote(value)
            let result = try ShellRunner.run("/bin/sh", ["-c", script])
            XCTAssertTrue(result.succeeded, value)
            XCTAssertEqual(result.stdout, value, value)
        }
    }

    func testShellCommandKeepsEachArgumentAndEnvironmentValueIntact() throws {
        for value in samples where !value.isEmpty {
            let command = ScriptQuoting.shellCommand(
                "/bin/sh", ["-c", #"printf '%s|%s|%s' "$OM_TEST_VAR" "$0" "$1""#, value, "disk9s1"],
                environment: [("OM_TEST_VAR", value)])
            let result = try ShellRunner.run("/bin/sh", ["-c", command])
            XCTAssertTrue(result.succeeded, value)
            XCTAssertEqual(result.stdout, "\(value)|\(value)|disk9s1", value)
        }
    }

    /// Mismas dos capas que el respaldo con osascript: orden de shell dentro
    /// de una cadena AppleScript de `do shell script` (sin privilegios aquí).
    func testQuotedCommandRoundTripsThroughOsascript() throws {
        for value in samples where !value.contains("\n") {
            let command = "printf '%s' " + ScriptQuoting.posixShellQuote(value)
            let script = "do shell script " + ScriptQuoting.appleScriptStringLiteral(command)
            let result = try ShellRunner.run("/usr/bin/osascript", ["-e", script])
            XCTAssertTrue(result.succeeded, "\(value): \(result.stderr)")
            XCTAssertEqual(result.stdout.trimmingCharacters(in: .newlines), value, value)
        }
    }

    func testAppleScriptLiteralRoundTrips() throws {
        for value in samples where !value.contains("\n") {
            let script = "return " + ScriptQuoting.appleScriptStringLiteral(value)
            let result = try ShellRunner.run("/usr/bin/osascript", ["-e", script])
            XCTAssertTrue(result.succeeded, "\(value): \(result.stderr)")
            XCTAssertEqual(result.stdout.trimmingCharacters(in: .newlines), value, value)
        }
    }
}
