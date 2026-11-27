import XCTest
@testable import OmnimountKit

/// Preparación del destino antes de formatear, con operaciones simuladas:
/// nunca ejecuta diskutil, mount ni mkfs.
final class FormatterTests: XCTestCase {
    private let partition = DiskPartition(
        deviceIdentifier: "disk99s1", parentWholeDisk: "disk99",
        content: "Linux Filesystem", volumeName: "TEST", size: 8192,
        mountPoint: nil, isWholeDisk: false)

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

    func testUnmountedPartitionIsNotReportedAsStillMounted() throws {
        var ops = operations()
        var diskutilArguments: [[String]] = []
        ops.runDiskutil = { arguments in
            diskutilArguments.append(arguments)
            return ShellResult(exitCode: 1, stdout: "", stderr: "disk99s1 was already unmounted\n")
        }
        try Formatter.prepareTarget(partition, operations: ops)
        XCTAssertEqual(diskutilArguments, [["unmount", "disk99s1"]])
    }

    func testFuseUnmountFailureStopsFormat() {
        var ops = operations()
        ops.currentMountPoint = { _ in "/Volumes/TEST" }
        ops.unmount = { _ in throw MountError.unmountFailed("Resource busy") }
        ops.runDiskutil = { _ in
            XCTFail("Must stop after a failed unmount")
            return ShellResult(exitCode: 0, stdout: "", stderr: "")
        }
        XCTAssertThrowsError(try Formatter.prepareTarget(partition, operations: ops)) { error in
            guard case MountError.unmountFailed("Resource busy") = error else {
                return XCTFail("Expected the original unmount failure, got \(error)")
            }
        }
    }

    func testLabelOnlyFuseMountIsRefusedWithoutUnmounting() {
        var ops = operations()
        ops.possibleFuseMountPoint = { _ in "/Volumes/TEST" }
        ops.runDiskutil = { _ in
            XCTFail("Must stop before diskutil if a label-only FUSE mount exists")
            return ShellResult(exitCode: 0, stdout: "", stderr: "")
        }
        XCTAssertThrowsError(try Formatter.prepareTarget(partition, operations: ops)) { error in
            guard case FormatError.unmountFailed = error else {
                return XCTFail("Expected a format unmount error, got \(error)")
            }
        }
    }

    func testVolumeStillMountedAfterUnmountStopsFormat() {
        var ops = operations()
        ops.externalDisks = { [self.disk(mountPoint: "/Volumes/TEST")] }
        ops.unmount = { _ in } // Un comando que informa éxito no prueba el desmontaje.
        XCTAssertThrowsError(try Formatter.prepareTarget(partition, operations: ops)) { error in
            guard case FormatError.unmountFailed = error else {
                return XCTFail("Expected a format unmount error, got \(error)")
            }
        }
    }

    func testDiskEnumerationFailureStopsFormat() {
        var ops = operations()
        ops.externalDisks = { throw DiskListerError.badPlist }
        ops.runDiskutil = { _ in
            XCTFail("A disk enumeration failure must stop preparation")
            return ShellResult(exitCode: 0, stdout: "", stderr: "")
        }
        XCTAssertThrowsError(try Formatter.prepareTarget(partition, operations: ops)) { error in
            guard case DiskListerError.badPlist = error else {
                return XCTFail("Expected the enumeration error, got \(error)")
            }
        }
    }
}
