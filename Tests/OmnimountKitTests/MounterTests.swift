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

    func testPrepareMountPointRejectsSymlinkToDirectory() throws {
        let target = directory.appendingPathComponent("target")
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try Mounter.prepareMountPoint(link.path, isMountPoint: { _ in false }))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testPrepareMountPointRejectsDirectoryThatIsAlreadyAMountPoint() throws {
        XCTAssertThrowsError(try Mounter.prepareMountPoint(directory.path,
                                                           isMountPoint: { $0 == self.directory.path })) { error in
            guard case MountError.mountPointInUse(let path) = error else {
                return XCTFail("Expected mount point in use, got \(error)")
            }
            XCTAssertEqual(path, self.directory.path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    func testPrepareMountPointAcceptsExistingEmptyDirectoryThatIsNotAMountPoint() throws {
        let path = directory.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        XCTAssertFalse(try Mounter.prepareMountPoint(path.path))
        XCTAssertFalse(try Mounter.prepareMountPoint(path.path, isMountPoint: { _ in false }))
    }

    func testMountRefusesDeviceAlreadyInMountTable() {
        XCTAssertThrowsError(try Mounter.ensureDeviceNotMounted(
            devicePath: "/dev/disk99s1",
            currentMountPoint: { $0 == "/dev/disk99s1" ? "/Volumes/TEST" : nil })) { error in
            guard case MountError.alreadyMounted(device: "/dev/disk99s1", mountPoint: "/Volumes/TEST") = error else {
                return XCTFail("Expected already mounted, got \(error)")
            }
        }
        XCTAssertNoThrow(try Mounter.ensureDeviceNotMounted(devicePath: "/dev/disk99s1",
                                                            currentMountPoint: { _ in nil }))
    }

    private func partition(volumeName: String?) -> DiskPartition {
        DiskPartition(deviceIdentifier: "disk99s1", parentWholeDisk: "disk99",
                      content: "Linux Filesystem", volumeName: volumeName, size: 8192,
                      mountPoint: nil, isWholeDisk: false)
    }

    func testDotLabelsFallBackToDeviceIdentifier() {
        for name in [".", ".."] {
            XCTAssertEqual(Mounter.defaultMountPoint(partition: partition(volumeName: nil),
                                                     detection: DetectionResult(filesystem: .ext4, label: name)),
                           "/Volumes/disk99s1")
            XCTAssertEqual(Mounter.defaultMountPoint(partition: partition(volumeName: name),
                                                     detection: DetectionResult(filesystem: .ntfs)),
                           "/Volumes/disk99s1")
        }
        XCTAssertEqual(Mounter.defaultMountPoint(partition: partition(volumeName: nil),
                                                 detection: DetectionResult(filesystem: .ext4, label: "a/b")),
                       "/Volumes/a-b")
        XCTAssertEqual(Mounter.defaultMountPoint(partition: partition(volumeName: nil),
                                                 detection: DetectionResult(filesystem: .ext4, label: "...")),
                       "/Volumes/...")
    }

    func testCommaInVolnameCannotAddMountOptions() {
        for tool in [ExternalTool.fuse2fs, .ntfs3g] {
            let options = Mounter.fuseOptions(tool: tool, volname: "x,remove_hiberfile,ro",
                                              readOnly: false, forceWritable: false)
            XCTAssertFalse(options.joined(separator: ",").split(separator: ",").contains("remove_hiberfile"),
                           "\(tool): \(options)")
            XCTAssertFalse(options.joined(separator: ",").split(separator: ",").contains("ro"),
                           "\(tool): \(options)")
            XCTAssertTrue(options.contains("volname=x_remove_hiberfile_ro"), "\(tool): \(options)")
        }
        XCTAssertEqual(Mounter.fuseOptions(tool: .ntfs3g, volname: "DATA", readOnly: true, forceWritable: true),
                       ["local", "allow_other", "windows_names", "big_writes",
                        "remove_hiberfile", "ro", "volname=DATA"])
        XCTAssertEqual(Mounter.fuseOptions(tool: .fuse2fs, volname: "LINUX", readOnly: false, forceWritable: false),
                       ["local", "allow_other", "volname=LINUX"])
    }

    /// Divide una cadena -o como fuse_opt: "\" escapa el carácter siguiente
    /// y "," separa opciones (comprobado con libfuse-t 1.2.9).
    private func fuseOptSplit(_ joined: String) -> [String] {
        var options: [String] = [], current = "", escaped = false
        for character in joined {
            if escaped { current.append(character); escaped = false }
            else if character == "\\" { escaped = true }
            else if character == "," { options.append(current); current = "" }
            else { current.append(character) }
        }
        if escaped { current.append("\\") }
        options.append(current)
        return options
    }

    func testBackslashAndControlCharactersInVolnameCannotAbsorbOptions() {
        let labels = ["x\\", "a\\,b", "line\nbreak", "tab\there\u{7F}", "a\\b"]
        for tool in [ExternalTool.fuse2fs, .ntfs3g] {
            let expected = Mounter.fuseOptions(tool: tool, volname: "NAME", readOnly: true, forceWritable: false)
            for label in labels {
                let options = Mounter.fuseOptions(tool: tool, volname: label, readOnly: true, forceWritable: false)
                let parsed = fuseOptSplit(options.joined(separator: ","))
                XCTAssertTrue(parsed.contains("ro"), "\(tool) \(label.debugDescription): \(parsed)")
                XCTAssertEqual(parsed.count, expected.count, "\(tool) \(label.debugDescription): \(parsed)")
                XCTAssertEqual(parsed.filter { !$0.hasPrefix("volname=") }, expected.filter { !$0.hasPrefix("volname=") },
                               "\(tool) \(label.debugDescription): \(parsed)")
                let volname = parsed.first { $0.hasPrefix("volname=") } ?? ""
                XCTAssertFalse(volname.contains { $0 == "\\" || $0 == "," || $0.isNewline },
                               "\(tool) \(label.debugDescription): \(volname.debugDescription)")
                XCTAssertFalse(volname.unicodeScalars.contains { $0.properties.generalCategory == .control },
                               "\(tool) \(label.debugDescription): \(volname.debugDescription)")
            }
        }
        XCTAssertTrue(Mounter.fuseOptions(tool: .fuse2fs, volname: "x\\", readOnly: false, forceWritable: false)
                        .contains("volname=x_"))
        XCTAssertTrue(Mounter.fuseOptions(tool: .fuse2fs, volname: "a\\,b", readOnly: false, forceWritable: false)
                        .contains("volname=a__b"))
        XCTAssertTrue(Mounter.fuseOptions(tool: .fuse2fs, volname: "line\nbreak", readOnly: false, forceWritable: false)
                        .contains("volname=linebreak"))
        XCTAssertEqual(Mounter.fuseOptions(tool: .fuse2fs, volname: "\n\t", readOnly: true, forceWritable: false),
                       ["local", "allow_other", "ro"])
    }

    func testOrdinaryVolnamesAreUnchanged() {
        for label in ["My Disk", "Fotos Año 2024", "データ", "Резерв", "v1.2-final_copy", "...", "a=b"] {
            XCTAssertTrue(Mounter.fuseOptions(tool: .ntfs3g, volname: label, readOnly: false, forceWritable: false)
                            .contains("volname=\(label)"), label)
        }
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

    func testMountOutputParsing() {
        let output = """
        /dev/disk3s1s1 on / (apfs, sealed, local, read-only, journaled)
        /dev/disk4s10 on /Volumes/Other (msdos, local, nodev, nosuid)
        fuse-t:/LINUX on /Volumes/LINUX (nfs, nodev, nosuid, mounted by root)
        /dev/disk4s1 on /Volumes/Backup on USB (msdos, local, nodev, nosuid)
        /dev/disk5s1 on /Volumes/Data (2024) (fuse, local)
        malformed line without separator
        """
        XCTAssertEqual(Mounter.mountPoint(inMountOutput: output, devicePath: "/dev/disk4s1"),
                       "/Volumes/Backup on USB")
        XCTAssertEqual(Mounter.mountPoint(inMountOutput: output, devicePath: "/dev/disk4s10"),
                       "/Volumes/Other")
        XCTAssertEqual(Mounter.mountPoint(inMountOutput: output, devicePath: "/dev/disk5s1"),
                       "/Volumes/Data (2024)")
        XCTAssertEqual(Mounter.mountPoint(inMountOutput: output, devicePath: "/dev/disk3s1s1"), "/")
        XCTAssertNil(Mounter.mountPoint(inMountOutput: output, devicePath: "/dev/disk4"))
        XCTAssertNil(Mounter.mountPoint(inMountOutput: output, devicePath: "/dev/disk9s1"))
    }

    private func result(_ status: Int32) -> ShellResult {
        ShellResult(exitCode: status, stdout: "diagnostic output", stderr: "")
    }

    // MARK: - Punto de montaje derivado (FUSE-T)

    func testDerivedMountPointRequiresFuseTSource() {
        let candidate = "/Volumes/LINUX"
        let cases: [(isMountPoint: Bool, source: String?, expected: String?)] = [
            (true, "fuse-t:/LINUX", candidate),
            (true, "//user@server/share", nil),
            (true, "/dev/disk5s1", nil),
            (true, nil, nil),
            (false, "fuse-t:/LINUX", nil),
        ]
        for item in cases {
            XCTAssertEqual(Mounter.fuseTMountPoint(candidate,
                                                   isMountPoint: { _ in item.isMountPoint },
                                                   mountSource: { _ in item.source }),
                           item.expected, String(describing: item))
        }
    }

    func testMountSourceReadsTheMountedFilesystem() throws {
        let root = try XCTUnwrap(Mounter.mountSource("/"))
        XCTAssertFalse(root.isEmpty)
        XCTAssertFalse(root.hasPrefix("fuse-t:"))
        XCTAssertNil(Mounter.mountSource(directory.appendingPathComponent("missing").path))
        // Una carpeta normal no es un punto de montaje.
        XCTAssertNil(Mounter.fuseTMountPoint(directory.path))
    }
}
