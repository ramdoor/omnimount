import XCTest
@testable import OmnimountKit

/// Solo ficheros temporales y comandos simulados: nunca monta ni abre dispositivos.
final class MounterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("omnimount-mounter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testWriteProbePreservesExistingFileAndLeavesNoTemporaryFiles() throws {
        let existing = directory.appendingPathComponent(".omnimount-writetest")
        let contents = Data("user data that must not be truncated".utf8)
        try contents.write(to: existing)

        XCTAssertFalse(Mounter.isMountReadOnly(directory.path))

        XCTAssertEqual(try Data(contentsOf: existing), contents)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path),
                       [existing.lastPathComponent])
    }

    func testWriteProbePreservesExistingSymlinkAndItsTarget() throws {
        let target = directory.appendingPathComponent("target")
        let link = directory.appendingPathComponent(".omnimount-writetest")
        let contents = Data("keep this target".utf8)
        try contents.write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertFalse(Mounter.isMountReadOnly(directory.path))

        XCTAssertEqual(try Data(contentsOf: target), contents)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
    }

    func testWriteProbeTreatsUncreatablePathAsNotWritable() {
        XCTAssertTrue(Mounter.isMountReadOnly(directory.appendingPathComponent("missing").path))
    }

    func testFailureCleanupPreservesPreexistingEmptyDirectory() throws {
        let created = try Mounter.prepareMountPoint(directory.path)
        XCTAssertFalse(created)

        Mounter.cleanupMountPoint(directory.path, createdByUs: created)

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    func testFailureCleanupRemovesOnlyNewEmptyDirectory() throws {
        let path = directory.appendingPathComponent("nested/mount").path
        let created = try Mounter.prepareMountPoint(path)
        XCTAssertTrue(created)

        Mounter.cleanupMountPoint(path, createdByUs: created)

        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("nested").path))
    }

    func testFailureCleanupDoesNotDeleteFilesAddedToNewDirectory() throws {
        let path = directory.appendingPathComponent("mount")
        let created = try Mounter.prepareMountPoint(path.path)
        let file = path.appendingPathComponent("keep")
        let contents = Data("new data".utf8)
        try contents.write(to: file)

        Mounter.cleanupMountPoint(path.path, createdByUs: created)

        XCTAssertEqual(try Data(contentsOf: file), contents)
    }

    func testPrepareMountPointRejectsExistingFileWithoutChangingIt() throws {
        let file = directory.appendingPathComponent("file")
        let contents = Data("existing file".utf8)
        try contents.write(to: file)

        XCTAssertThrowsError(try Mounter.prepareMountPoint(file.path))
        XCTAssertEqual(try Data(contentsOf: file), contents)
    }

    func testReadOnlyExtMountSkipsRepairAndToolLookup() throws {
        try Mounter.preflightExtMount(devicePath: directory.appendingPathComponent("image").path,
                                      deviceIdentifier: "image", readOnly: true,
                                      findTool: { _ in XCTFail("Read-only must not look for repair tool"); return nil },
                                      run: { _, _ in XCTFail("Read-only must not repair"); return self.result(0) })
    }

    func testWritableExtMountRequiresE2fsck() {
        XCTAssertThrowsError(try Mounter.preflightExtMount(
            devicePath: directory.appendingPathComponent("image").path,
            deviceIdentifier: "image", readOnly: false,
            findTool: { _ in nil },
            run: { _, _ in XCTFail("Missing tool must stop repair"); return self.result(0) })) { error in
            guard case MountError.toolMissing(.e2fsck) = error else {
                return XCTFail("Expected missing e2fsck, got \(error)")
            }
        }
    }

    func testWritableExtMountAcceptsOnlyCleanOrCorrectedExit() throws {
        let image = directory.appendingPathComponent("image").path
        for status: Int32 in [0, 1] {
            try Mounter.preflightExtMount(devicePath: image, deviceIdentifier: "image", readOnly: false,
                                          findTool: { tool in
                                              XCTAssertEqual(tool, .e2fsck)
                                              return "stub-e2fsck"
                                          }, run: { executable, arguments in
                                              XCTAssertEqual(executable, "stub-e2fsck")
                                              XCTAssertEqual(arguments, ["-p", image])
                                              return self.result(status)
                                          })
        }
        for status: Int32 in [-1, 2, 3, 4, 5, 8, 16, 32, 128] {
            XCTAssertThrowsError(try Mounter.preflightExtMount(
                devicePath: image, deviceIdentifier: "image", readOnly: false,
                findTool: { _ in "stub-e2fsck" }, run: { _, _ in self.result(status) })) { error in
                guard case MountError.ext4NeedsRepair("image", let detail) = error else {
                    return XCTFail("Expected unsafe preflight for \(status), got \(error)")
                }
                XCTAssertTrue(detail.contains("exit \(status)"))
            }
        }
    }

    func testWritableExtMountRejectsSignalOneInsteadOfTreatingItAsRepair() {
        XCTAssertThrowsError(try Mounter.preflightExtMount(
            devicePath: directory.appendingPathComponent("image").path,
            deviceIdentifier: "image", readOnly: false,
            findTool: { _ in "stub-e2fsck" },
            run: { _, _ in ShellResult(exitCode: 1, stdout: "", stderr: "", terminatedBySignal: true) })) { error in
            guard case MountError.ext4NeedsRepair(_, let detail) = error else {
                return XCTFail("Expected signal to block mount, got \(error)")
            }
            XCTAssertTrue(detail.contains("signal 1"))
        }
    }

    func testNtfsRepairRequiresToolBeforeUnmounting() {
        XCTAssertThrowsError(try Mounter.prepareNtfsForWriting(
            devicePath: "temporary-image", mountPoint: directory.path,
            findTool: { _ in nil },
            unmount: { _ in XCTFail("Do not unmount when tool is missing") },
            isMounted: { _ in true },
            run: { _, _ in XCTFail("Do not run missing tool"); return self.result(0) })) { error in
            guard case MountError.toolMissing(.ntfsfix) = error else {
                return XCTFail("Expected missing ntfsfix, got \(error)")
            }
        }
    }

    func testNtfsRepairStopsOnUnmountFailure() {
        XCTAssertThrowsError(try Mounter.prepareNtfsForWriting(
            devicePath: "temporary-image", mountPoint: directory.path,
            findTool: { _ in "stub-ntfsfix" },
            unmount: { _ in throw MountError.unmountFailed("busy") },
            isMounted: { _ in true },
            run: { _, _ in XCTFail("Never repair after failed unmount"); return self.result(0) })) { error in
            guard case MountError.unmountFailed("busy") = error else {
                return XCTFail("Expected original unmount failure, got \(error)")
            }
        }
    }

    func testNtfsRepairStopsIfUnmountReportsSuccessButVolumeRemainsMounted() {
        XCTAssertThrowsError(try Mounter.prepareNtfsForWriting(
            devicePath: "temporary-image", mountPoint: directory.path,
            findTool: { _ in "stub-ntfsfix" }, unmount: { _ in }, isMounted: { _ in true },
            run: { _, _ in XCTFail("Never repair mounted volume"); return self.result(0) })) { error in
            guard case MountError.unmountFailed = error else {
                return XCTFail("Expected mount still present failure, got \(error)")
            }
        }
    }

    func testNtfsRepairRunsOnlyAfterConfirmedUnmount() throws {
        var mounted = true
        var commands: [String] = []
        try Mounter.prepareNtfsForWriting(
            devicePath: "temporary-image", mountPoint: directory.path,
            findTool: { tool in XCTAssertEqual(tool, .ntfsfix); return "stub-ntfsfix" },
            unmount: { path in
                XCTAssertEqual(path, self.directory.path)
                commands.append("unmount")
                mounted = false
            },
            isMounted: { _ in mounted },
            run: { executable, arguments in
                XCTAssertFalse(mounted)
                XCTAssertEqual(executable, "stub-ntfsfix")
                XCTAssertEqual(arguments, ["-d", "temporary-image"])
                commands.append("ntfsfix")
                return self.result(0)
            })
        XCTAssertEqual(commands, ["unmount", "ntfsfix"])
    }

    func testNtfsRepairFailurePreventsContinuingToRemount() {
        for result in [result(1), ShellResult(exitCode: 1, stdout: "", stderr: "", terminatedBySignal: true)] {
            XCTAssertThrowsError(try Mounter.prepareNtfsForWriting(
                devicePath: "temporary-image", mountPoint: nil,
                findTool: { _ in "stub-ntfsfix" },
                unmount: { _ in XCTFail("Already unmounted") },
                isMounted: { _ in XCTFail("No mount point"); return false },
                run: { _, _ in result })) { error in
                guard case MountError.fsckFailed = error else {
                    return XCTFail("Expected repair failure, got \(error)")
                }
            }
        }
    }

    private var hibernationOutput: String {
        """
        Mounting volume... FAILED
        Attempting to correct errors...
        Processing $MFT and $MFTMirr...
        Reading $MFT... OK
        Reading $MFTMirr... OK
        Comparing $MFTMirr to $MFT... OK
        Processing of $MFT and $MFTMirr completed successfully.
        Setting required flags on partition... OK
        Going to empty the journal ($LogFile)... OK
        """
    }

    private var hibernationError: String {
        """
        Windows is hibernated, refused to mount.
        Windows is hibernated, refused to mount.
        Remount failed: Operation not permitted
        """
    }

    func testNtfsHibernationOnlyCanContinueToExplicitRemoveHiberfile() throws {
        try Mounter.prepareNtfsForWriting(
            devicePath: "temporary-image", mountPoint: nil,
            findTool: { _ in "stub-ntfsfix" },
            run: { _, _ in ShellResult(exitCode: 1, stdout: self.hibernationOutput,
                                        stderr: self.hibernationError) })
    }

    func testNtfsHibernationDoesNotHideAdditionalErrorsOrMissingMftCheck() {
        for result in [
            ShellResult(exitCode: 1, stdout: hibernationOutput,
                        stderr: hibernationError + "\nFailed to read $MFT: I/O error"),
            ShellResult(exitCode: 1, stdout: hibernationOutput + "\nFailed to repair volume",
                        stderr: hibernationError),
            ShellResult(exitCode: 1, stdout: "", stderr: hibernationError),
        ] {
            XCTAssertThrowsError(try Mounter.prepareNtfsForWriting(
                devicePath: "temporary-image", mountPoint: nil,
                findTool: { _ in "stub-ntfsfix" }, run: { _, _ in result }))
        }
    }

    func testNtfsHibernationDiagnosticDoesNotHideSignalOrOtherExitCode() {
        for result in [
            ShellResult(exitCode: 1, stdout: hibernationOutput,
                        stderr: hibernationError, terminatedBySignal: true),
            ShellResult(exitCode: 2, stdout: hibernationOutput, stderr: hibernationError),
        ] {
            XCTAssertThrowsError(try Mounter.prepareNtfsForWriting(
                devicePath: "temporary-image", mountPoint: nil,
                findTool: { _ in "stub-ntfsfix" }, run: { _, _ in result }))
        }
    }

    func testQuotaRepairRequiresBothToolsBeforeChangingFilesystem() {
        for missing in [ExternalTool.tune2fs, .e2fsck] {
            XCTAssertThrowsError(try Mounter.repairExtQuota(
                devicePath: "temporary-image",
                findTool: { $0 == missing ? nil : "stub-\($0.rawValue)" },
                run: { _, _ in XCTFail("No mutation with missing tool"); return self.result(0) })) { error in
                guard case MountError.toolMissing(let tool) = error else {
                    return XCTFail("Expected missing tool, got \(error)")
                }
                XCTAssertEqual(tool, missing)
            }
        }
    }

    func testQuotaRepairStopsIfTune2fsFails() {
        XCTAssertThrowsError(try Mounter.repairExtQuota(
            devicePath: "temporary-image", findTool: { "stub-\($0.rawValue)" },
            run: { executable, _ in
                XCTAssertEqual(executable, "stub-tune2fs", "Do not continue to fsck after failed tune2fs")
                return self.result(1)
            })) { error in
            guard case MountError.mountFailed(tool: "tune2fs", stderr: _) = error else {
                return XCTFail("Expected tune2fs failure, got \(error)")
            }
        }
    }

    func testQuotaRepairRunsTune2fsThenFsckAndAcceptsNormalZeroOrOne() throws {
        for status: Int32 in [0, 1] {
            var commands: [String] = []
            try Mounter.repairExtQuota(devicePath: "temporary-image", findTool: { "stub-\($0.rawValue)" },
                                       run: { executable, arguments in
                                           commands.append(executable)
                                           if executable == "stub-tune2fs" {
                                               XCTAssertEqual(arguments, ["-O", "^quota,^project", "temporary-image"])
                                               return self.result(0)
                                           }
                                           XCTAssertEqual(arguments, ["-fy", "temporary-image"])
                                           return self.result(status)
                                       })
            XCTAssertEqual(commands, ["stub-tune2fs", "stub-e2fsck"])
        }
    }

    func testQuotaRepairRejectsRebootRequiredErrorsAndSignalOne() {
        let failures = [2, 3, 4, 8].map { result(Int32($0)) }
            + [ShellResult(exitCode: 1, stdout: "", stderr: "", terminatedBySignal: true)]
        for check in failures {
            XCTAssertThrowsError(try Mounter.repairExtQuota(
                devicePath: "temporary-image", findTool: { "stub-\($0.rawValue)" },
                run: { executable, _ in executable == "stub-tune2fs" ? self.result(0) : check })) { error in
                guard case MountError.fsckFailed = error else {
                    return XCTFail("Expected unsafe fsck failure, got \(error)")
                }
            }
        }
    }

    private func result(_ status: Int32) -> ShellResult {
        ShellResult(exitCode: status, stdout: "diagnostic output", stderr: "")
    }
}
