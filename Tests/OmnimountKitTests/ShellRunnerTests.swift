import XCTest
@testable import OmnimountKit

final class ShellRunnerTests: XCTestCase {
    func testCapturesBothLargeStreamsWithoutBlocking() throws {
        // La alarma mata al hijo si reaparece el bloqueo de pipes, de modo que
        // el test falla por salida incompleta sin dejar la suite colgada.
        let script = """
        import signal, sys
        signal.alarm(5)
        sys.stdout.buffer.write(b'O' * 262144)
        sys.stdout.buffer.flush()
        sys.stderr.buffer.write(b'E' * 262144)
        sys.stderr.buffer.flush()
        signal.alarm(0)
        sys.exit(23)
        """

        let result = try ShellRunner.run("/usr/bin/python3", ["-c", script])

        XCTAssertEqual(result.exitCode, 23)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.stdout, String(repeating: "O", count: 262_144))
        XCTAssertEqual(result.stderr, String(repeating: "E", count: 262_144))
    }

    func testSuccessfulCommandPreservesArgumentsAndBothStreams() throws {
        let text = "argumento con espacios, acento á y $literal"
        let result = try ShellRunner.run("/bin/sh", [
            "-c", "printf '%s' \"$1\"; printf 'diagnóstico' >&2", "test", text,
        ])

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, text)
        XCTAssertEqual(result.stderr, "diagnóstico")
    }

    func testLaunchFailureIncludesExecutablePath() {
        let missing = NSTemporaryDirectory() + "omnimount-missing-\(UUID().uuidString)"

        XCTAssertThrowsError(try ShellRunner.run(missing, [])) { error in
            guard case ShellError.launchFailed(let executable, _) = error else {
                return XCTFail("Expected launchFailed, got \(error)")
            }
            XCTAssertEqual(executable, missing)
            XCTAssertTrue(error.localizedDescription.contains(missing))
        }
    }

    func testDistinguishesSignalOneFromExitOne() throws {
        let exited = try ShellRunner.run("/bin/sh", ["-c", "exit 1"])
        let signaled = try ShellRunner.run("/bin/sh", ["-c", "kill -HUP $$"])

        XCTAssertEqual(exited.exitCode, 1)
        XCTAssertFalse(exited.terminatedBySignal)
        XCTAssertEqual(signaled.exitCode, 1)
        XCTAssertTrue(signaled.terminatedBySignal)
        XCTAssertFalse(signaled.succeeded)
    }
}
