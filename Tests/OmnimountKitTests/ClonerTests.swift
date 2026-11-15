import XCTest
@testable import OmnimountKit

/// Exercises the copy engine using ordinary temporary files, never disk devices.
final class ClonerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("omnimount-cloner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func copy(_ source: Data, expectedBytes: Int64,
                      existingDestination: Data = Data(),
                      progress: (CloneProgress) -> Void = { _ in }) throws -> Data {
        let sourceURL = directory.appendingPathComponent("source.img")
        let destinationURL = directory.appendingPathComponent("destination.img")
        try source.write(to: sourceURL)
        try existingDestination.write(to: destinationURL)
        let input = try FileHandle(forReadingFrom: sourceURL)
        let output = try FileHandle(forWritingTo: destinationURL)
        defer {
            try? input.close()
            try? output.close()
        }
        try Cloner.copyStream(from: input, to: output, totalBytes: expectedBytes,
                              progress: progress)
        return try Data(contentsOf: destinationURL)
    }

    func testRejectsUnexpectedEOFInsteadOfReportingSuccess() throws {
        let source = Data(repeating: 0x3c, count: 8192)
        var progress: [CloneProgress] = []
        XCTAssertThrowsError(try copy(source, expectedBytes: 16384) { progress.append($0) }) {
            guard case CloneError.ioError = $0 else {
                return XCTFail("Expected an I/O error, got \($0)")
            }
        }
        XCTAssertFalse(progress.contains { $0.fraction >= 1 })
    }

    func testCopiesOnlyExpectedBytesIfSourceIsLonger() throws {
        let expected = 4 * 1024 * 1024 + 17
        let source = Data(repeating: 0xa5, count: expected + 1024)
        var progress: [CloneProgress] = []
        let result = try copy(source, expectedBytes: Int64(expected)) { progress.append($0) }
        XCTAssertEqual(result, source.prefix(expected))
        XCTAssertEqual(progress.last?.bytesCopied, Int64(expected))
        XCTAssertTrue(progress.allSatisfy { $0.fraction <= 1 })
    }

    func testCopiesMultipleChunksWithoutChangingBytes() throws {
        let source = Data((0..<(8 * 1024 * 1024 + 31)).map { UInt8(truncatingIfNeeded: $0) })
        var progress: [CloneProgress] = []
        XCTAssertEqual(try copy(source, expectedBytes: Int64(source.count)) {
            progress.append($0)
        }, source)
        XCTAssertEqual(progress.last?.bytesCopied, Int64(source.count))
        XCTAssertEqual(progress.last?.fraction, 1)
        XCTAssertTrue(zip(progress, progress.dropFirst()).allSatisfy {
            $0.bytesCopied <= $1.bytesCopied
        })
    }

    func testRestoreStyleCopyPreservesTargetBeyondImage() throws {
        let source = Data(repeating: 0x41, count: 4096)
        let destination = Data(repeating: 0x7e, count: 8192)
        let result = try copy(source, expectedBytes: Int64(source.count),
                              existingDestination: destination)
        XCTAssertEqual(result.prefix(source.count), source)
        XCTAssertEqual(result.suffix(4096), destination.suffix(4096))
        XCTAssertEqual(result.count, destination.count)
    }

    func testEmptyRestoreImageIsRejectedBeforePreparingTarget() throws {
        let image = directory.appendingPathComponent("empty.img")
        try Data().write(to: image)
        XCTAssertThrowsError(try Cloner.restoreImageSize(at: image.path)) {
            guard case CloneError.ioError = $0 else {
                return XCTFail("Expected an I/O error, got \($0)")
            }
        }
    }

    func testNonemptyRestoreImageReportsExactSize() throws {
        let image = directory.appendingPathComponent("restore.img")
        try Data(repeating: 0x42, count: 4097).write(to: image)
        XCTAssertEqual(try Cloner.restoreImageSize(at: image.path), 4097)
    }

    private func disk(mountPoint: String? = nil) -> ExternalDisk {
        ExternalDisk(deviceIdentifier: "disk99", size: 8192, mediaName: "Test disk",
                     partitions: [DiskPartition(
                        deviceIdentifier: "disk99s1", parentWholeDisk: "disk99",
                        content: "Linux Filesystem", volumeName: "TEST", size: 8192,
                        mountPoint: mountPoint, isWholeDisk: false)])
    }

    private func operations() -> Cloner.UnmountOperations {
        Cloner.UnmountOperations(
            externalDisks: { [self.disk()] },
            currentMountPoint: { _ in nil },
            possibleFuseMountPoint: { _ in nil },
            unmount: { _ in XCTFail("Unexpected unmount") },
            runDiskutil: { _ in ShellResult(exitCode: 0, stdout: "", stderr: "") })
    }

    func testPartitionUnmountFailureStopsRawPreparation() throws {
        var ops = operations()
        ops.runDiskutil = { arguments in
            XCTAssertEqual(arguments, ["unmount", "disk99s1"])
            return ShellResult(exitCode: 1, stdout: "", stderr: "device busy")
        }
        XCTAssertThrowsError(try Cloner.unmountTarget("disk99s1", operations: ops)) {
            guard case CloneError.unmountFailed(let message) = $0 else {
                return XCTFail("Expected an unmount error, got \($0)")
            }
            XCTAssertEqual(message, "device busy")
        }
    }

    func testAlreadyUnmountedDiagnosticAllowsVerifiedUnmountedPartition() throws {
        var ops = operations()
        var enumerations = 0
        ops.externalDisks = { enumerations += 1; return [self.disk()] }
        ops.runDiskutil = { _ in
            ShellResult(exitCode: 1, stdout: "", stderr: "disk99s1 was already unmounted\n")
        }
        try Cloner.unmountTarget("disk99s1", operations: ops)
        XCTAssertEqual(enumerations, 2)
    }

    func testAlreadyUnmountedDiagnosticCannotHideMountedVolume() throws {
        var ops = operations()
        ops.externalDisks = { [self.disk(mountPoint: "/Volumes/TEST")] }
        ops.unmount = { _ in }
        ops.runDiskutil = { _ in
            ShellResult(exitCode: 1, stdout: "", stderr: "disk99s1 was already unmounted\n")
        }
        XCTAssertThrowsError(try Cloner.unmountTarget("disk99s1", operations: ops))
    }

    func testAlreadyUnmountedDiagnosticDoesNotSuppressOtherFailures() throws {
        for result in [
            ShellResult(exitCode: 1, stdout: "", stderr: "disk99s1 was already unmounted\ndevice busy"),
            ShellResult(exitCode: 1, stdout: "", stderr: "disk98s1 was already unmounted"),
            ShellResult(exitCode: 1, stdout: "", stderr: "disk99s1 was already unmounted", terminatedBySignal: true)
        ] {
            var ops = operations()
            ops.runDiskutil = { _ in result }
            XCTAssertThrowsError(try Cloner.unmountTarget("disk99s1", operations: ops))
        }
    }

    func testRawSizeIncludesPartitionTailOutsideMountedFilesystem() throws {
        XCTAssertEqual(try Cloner.deviceSize(from: ["IOKitSize": 134217728,
                                                    "Size": 134217728,
                                                    "TotalSize": 132136448],
                                            identifier: "disk99s1"), 134217728)
        XCTAssertEqual(try Cloner.deviceSize(from: ["Size": 134217728,
                                                    "TotalSize": 132136448],
                                            identifier: "disk99s1"), 134217728)
        XCTAssertEqual(try Cloner.deviceSize(from: ["TotalSize": 8192],
                                            identifier: "disk99"), 8192)
    }

    func testAmbiguousFuseMountStopsWithoutUnmountingByLabel() throws {
        var ops = operations()
        ops.possibleFuseMountPoint = { _ in self.directory.appendingPathComponent("TEST").path }
        ops.runDiskutil = { _ in
            XCTFail("Must stop before diskutil if a label-only FUSE mount exists")
            return ShellResult(exitCode: 0, stdout: "", stderr: "")
        }
        XCTAssertThrowsError(try Cloner.unmountTarget("disk99", operations: ops)) {
            guard case CloneError.unmountFailed = $0 else {
                return XCTFail("Expected an unmount error, got \($0)")
            }
        }
    }

    func testKnownMountIsUnmountedAndDiskStateRechecked() throws {
        let point = directory.appendingPathComponent("known-mount").path
        var mounted = true
        var enumerations = 0
        var diskutilCalled = false
        var ops = operations()
        ops.externalDisks = {
            enumerations += 1
            return [self.disk(mountPoint: mounted ? point : nil)]
        }
        ops.currentMountPoint = { _ in mounted ? point : nil }
        ops.unmount = {
            XCTAssertEqual($0, point)
            mounted = false
        }
        ops.runDiskutil = { arguments in
            XCTAssertFalse(mounted)
            XCTAssertEqual(arguments, ["unmountDisk", "disk99"])
            diskutilCalled = true
            return ShellResult(exitCode: 0, stdout: "", stderr: "")
        }
        try Cloner.unmountTarget("disk99", operations: ops)
        XCTAssertTrue(diskutilCalled)
        XCTAssertEqual(enumerations, 2)
    }

    func testSuccessfulDiskutilCannotHideAStillMountedVolume() throws {
        let point = directory.appendingPathComponent("still-mounted").path
        var ops = operations()
        ops.externalDisks = { [self.disk(mountPoint: point)] }
        ops.unmount = { _ in } // A command reporting success is not proof of unmount.
        XCTAssertThrowsError(try Cloner.unmountTarget("disk99s1", operations: ops))
    }

    func testMissingExternalTargetStopsBeforeRunningCommands() throws {
        var ops = operations()
        ops.externalDisks = { [] }
        ops.runDiskutil = { _ in
            XCTFail("Unknown or internal targets must not be prepared for raw access")
            return ShellResult(exitCode: 0, stdout: "", stderr: "")
        }
        XCTAssertThrowsError(try Cloner.unmountTarget("disk99", operations: ops))
    }

    func testDiskEnumerationErrorIsNotIgnored() throws {
        var ops = operations()
        ops.externalDisks = { throw DiskListerError.badPlist }
        ops.runDiskutil = { _ in
            XCTFail("A disk enumeration failure must stop preparation")
            return ShellResult(exitCode: 0, stdout: "", stderr: "")
        }
        XCTAssertThrowsError(try Cloner.unmountTarget("disk99", operations: ops))
    }
}
