import XCTest
@testable import OmnimountKit

/// Exercises the copy engine using ordinary temporary files, never disk devices.
final class ClonerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        // En /private/tmp (no en el TMPDIR del usuario, que es 0700) para que
        // las pruebas con otro usuario puedan atravesar las carpetas padre.
        directory = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("omnimount-cloner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(directory.path, 0o755), 0)
    }

    override func tearDownWithError() throws {
        // Devolver permisos para poder borrar carpetas de solo lectura.
        if let items = FileManager.default.enumerator(atPath: directory.path) {
            for case let item as String in items {
                _ = chmod(directory.appendingPathComponent(item).path, 0o755)
            }
        }
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
        XCTAssertThrowsError(try Cloner.openRestoreImage(image.path, access: nil)) {
            guard case CloneError.ioError = $0 else {
                return XCTFail("Expected an I/O error, got \($0)")
            }
        }
    }

    func testNonemptyRestoreImageReportsExactSize() throws {
        let image = directory.appendingPathComponent("restore.img")
        try Data(repeating: 0x42, count: 4097).write(to: image)
        XCTAssertEqual(try Cloner.openRestoreImage(image.path, access: nil).size, 4097)
    }

    // MARK: - Validación de la restauración

    func testRestoreRejectsImageNotMultipleOfBlockSize() {
        for (size, block) in [(Int64(4097), 512), (Int64(4097), 4096), (Int64(6144), 4096)] {
            XCTAssertThrowsError(try Cloner.validateRestore(
                imageSize: size, targetInfo: ["IOKitSize": 1_048_576, "DeviceBlockSize": block],
                identifier: "disk99")) {
                guard case CloneError.ioError(let message) = $0 else {
                    return XCTFail("Expected an I/O error for \(size)/\(block), got \($0)")
                }
                XCTAssertTrue(message.contains(String(size)) && message.contains(String(block)), message)
            }
        }
    }

    func testRestoreWithoutReportedBlockSizeChecksSectorAlignment() {
        XCTAssertThrowsError(try Cloner.validateRestore(imageSize: 4097, targetInfo: ["IOKitSize": 1_048_576],
                                                        identifier: "disk99"))
        XCTAssertNoThrow(try Cloner.validateRestore(imageSize: 4608, targetInfo: ["IOKitSize": 1_048_576],
                                                    identifier: "disk99"))
    }

    func testRestoreAcceptsAlignedImageThatFits() {
        XCTAssertNoThrow(try Cloner.validateRestore(
            imageSize: 8192, targetInfo: ["IOKitSize": 8192, "DeviceBlockSize": 4096], identifier: "disk99"))
        XCTAssertNoThrow(try Cloner.validateRestore(
            imageSize: 1536, targetInfo: ["IOKitSize": 1_048_576, "DeviceBlockSize": 512], identifier: "disk99"))
    }

    func testRestoreRejectsImageLargerThanTarget() {
        XCTAssertThrowsError(try Cloner.validateRestore(
            imageSize: 16384, targetInfo: ["IOKitSize": 8192, "DeviceBlockSize": 512], identifier: "disk99")) {
            guard case CloneError.imageLargerThanTarget(image: 16384, target: 8192) = $0 else {
                return XCTFail("Expected image larger than target, got \($0)")
            }
        }
    }

    // MARK: - Escritura de la imagen

    private func writeImage(_ source: Data, totalBytes: Int64, to image: URL,
                            owner: ImageOwner? = nil, access: CallerAccess? = nil) throws {
        let destination = try ImageDestination.open(image.path, owner: owner, access: access)
        try writeImage(source, totalBytes: totalBytes, to: destination)
    }

    private func writeImage(_ source: Data, totalBytes: Int64, to destination: ImageDestination) throws {
        let sourceURL = directory.appendingPathComponent("raw-source")
        try source.write(to: sourceURL)
        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }
        try destination.checkExistingImage()
        try Cloner.writeImage(from: input, totalBytes: totalBytes, to: destination, progress: { _ in })
    }

    private func partial(_ image: URL) -> URL {
        URL(fileURLWithPath: image.path + ".partial")
    }

    private func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    func testPartialImagePathIsImagePathPlusSuffix() {
        XCTAssertEqual(Cloner.partialImagePath(for: "/Users/me/Backups/card.img"),
                       "/Users/me/Backups/card.img.partial")
    }

    func testFailedImageWriteLeavesNoFileAtFinalPath() throws {
        let image = directory.appendingPathComponent("clone.img")
        XCTAssertThrowsError(try writeImage(Data(repeating: 0x11, count: 8192), totalBytes: 16384, to: image)) {
            guard case CloneError.ioError = $0 else { return XCTFail("Expected an I/O error, got \($0)") }
        }
        XCTAssertFalse(exists(image), "A failed clone must not leave an image at the final path")
        XCTAssertFalse(exists(partial(image)), "A failed clone must remove its partial file")
    }

    func testFailedImageWritePreservesExistingImage() throws {
        let image = directory.appendingPathComponent("clone.img")
        let previous = Data(repeating: 0x5a, count: 4096)
        try previous.write(to: image)
        XCTAssertThrowsError(try writeImage(Data(repeating: 0x11, count: 8192), totalBytes: 16384, to: image))
        XCTAssertEqual(try Data(contentsOf: image), previous)
        XCTAssertFalse(exists(partial(image)))
    }

    func testSuccessfulImageWriteReplacesExistingRegularFile() throws {
        let image = directory.appendingPathComponent("clone.img")
        try Data(repeating: 0x5a, count: 16384).write(to: image)
        let source = Data((0..<8192).map { UInt8(truncatingIfNeeded: $0) })
        try writeImage(source, totalBytes: Int64(source.count), to: image)
        XCTAssertEqual(try Data(contentsOf: image), source)
        XCTAssertFalse(exists(partial(image)))
    }

    func testImageWriteAppliesOwnerAndMode() throws {
        let image = directory.appendingPathComponent("clone.img")
        let owner = ImageOwner(uid: getuid(), gid: getgid())
        try writeImage(Data(repeating: 0x22, count: 4096), totalBytes: 4096, to: image, owner: owner)
        var info = stat()
        XCTAssertEqual(lstat(image.path, &info), 0)
        XCTAssertEqual(info.st_uid, owner.uid)
        XCTAssertEqual(info.st_gid, owner.gid)
        XCTAssertEqual(info.st_mode & 0o7777, 0o644)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFREG)
    }

    func testStalePartialRegularFileIsReplaced() throws {
        let image = directory.appendingPathComponent("clone.img")
        try Data("left over".utf8).write(to: partial(image))
        let source = Data(repeating: 0x33, count: 4096)
        try writeImage(source, totalBytes: 4096, to: image)
        XCTAssertEqual(try Data(contentsOf: image), source)
        XCTAssertFalse(exists(partial(image)))
    }

    func testStalePartialSymlinkIsRefusedAndKept() throws {
        let image = directory.appendingPathComponent("clone.img")
        let target = directory.appendingPathComponent("unrelated")
        let targetContents = Data("unrelated file".utf8)
        try targetContents.write(to: target)
        try FileManager.default.createSymbolicLink(at: partial(image), withDestinationURL: target)

        XCTAssertThrowsError(try writeImage(Data(repeating: 0x33, count: 4096), totalBytes: 4096, to: image)) {
            guard case CloneError.stalePartial(let path) = $0 else {
                return XCTFail("Expected stalePartial, got \($0)")
            }
            XCTAssertEqual(path, self.partial(image).path)
        }
        XCTAssertFalse(exists(image))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: partial(image).path), target.path)
        XCTAssertEqual(try Data(contentsOf: target), targetContents)
    }

    func testFreeSpaceArithmeticDoesNotOverflow() {
        XCTAssertEqual(ImageDestination.freeBytes(availableBlocks: 0, blockSize: 4096), 0)
        XCTAssertEqual(ImageDestination.freeBytes(availableBlocks: 1000, blockSize: 4096), 4_096_000)
        XCTAssertEqual(ImageDestination.freeBytes(availableBlocks: UInt64(Int64.max) / 4096, blockSize: 4096),
                       Int64.max / 4096 * 4096)
        // Producto mayor que Int64.max, desbordamiento de UInt64 y valores máximos.
        XCTAssertEqual(ImageDestination.freeBytes(availableBlocks: UInt64(Int64.max) / 4096 + 1, blockSize: 4096), .max)
        XCTAssertEqual(ImageDestination.freeBytes(availableBlocks: UInt64.max / 2, blockSize: 4), .max)
        XCTAssertEqual(ImageDestination.freeBytes(availableBlocks: .max, blockSize: .max), .max)
        XCTAssertEqual(ImageDestination.freeBytes(availableBlocks: UInt64(Int64.max) + 1, blockSize: 1), .max)
    }

    func testFreeSpaceOfOpenedFolderIsReported() throws {
        let destination = try ImageDestination.open(directory.appendingPathComponent("clone.img").path,
                                                    owner: nil, access: nil)
        XCTAssertGreaterThan(try XCTUnwrap(destination.freeBytes()), 0)
    }

    func testImageDestinationAcceptsMissingOrRegularFile() throws {
        let image = directory.appendingPathComponent("clone.img")
        try ImageDestination.open(image.path, owner: nil, access: nil).checkExistingImage()
        try Data("old".utf8).write(to: image)
        try ImageDestination.open(image.path, owner: nil, access: nil).checkExistingImage()
    }

    func testImageDestinationRejectsSymlinkAndDirectory() throws {
        let target = directory.appendingPathComponent("target")
        let link = directory.appendingPathComponent("link.img")
        let contents = Data("keep".utf8)
        try contents.write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let folder = directory.appendingPathComponent("folder.img")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)

        for path in [link.path, folder.path] {
            for access in [nil, me] as [CallerAccess?] {
                XCTAssertThrowsError(try ImageDestination.open(path, owner: nil, access: access).checkExistingImage()) {
                    guard case CloneError.notRegularFile(path) = $0 else {
                        return XCTFail("Expected notRegularFile(\(path)), got \($0)")
                    }
                }
            }
        }
        XCTAssertEqual(try Data(contentsOf: target), contents)
    }

    // MARK: - Destino y origen con la identidad de quien lo pide

    /// El usuario que ejecuta las pruebas.
    private var me: CallerAccess {
        CallerAccess(uid: getuid(), gid: getgid(), isMember: { _ in false })
    }

    /// Otro usuario, sin grupos en común.
    private let other = CallerAccess(uid: 4242, gid: 4242, isMember: { _ in false })

    private func folder(_ name: String, mode: mode_t, in parent: URL? = nil) throws -> URL {
        let url = (parent ?? directory).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(url.path, mode), 0)
        return url
    }

    @discardableResult
    private func file(_ url: URL, mode: mode_t, contents: Data = Data(repeating: 0x5a, count: 4096)) throws -> URL {
        try contents.write(to: url)
        XCTAssertEqual(chmod(url.path, mode), 0)
        return url
    }

    func testRootCallerUsesTheSamePathAsTheCLI() throws {
        try XCTSkipIf(getuid() == 0, "Needs a non-root user to compare with root")
        XCTAssertNil(CallerAccess(checking: ImageOwner(uid: 0, gid: 0)))
        XCTAssertNotNil(CallerAccess(checking: ImageOwner(uid: getuid(), gid: getgid())))
    }

    func testCallerGroupsMatchTheProcessGroups() {
        // Los grupos suplementarios con los que corre este proceso salen de
        // la misma base de usuarios que consulta getgrouplist.
        let count = getgroups(0, nil)
        var processGroups = [gid_t](repeating: 0, count: Int(max(count, 0)))
        XCTAssertEqual(getgroups(count, &processGroups), count)
        let groups = CallerAccess.groups(of: getuid(), primary: getgid())
        XCTAssertTrue(Set(processGroups).isSubset(of: groups),
                      "missing \(Set(processGroups).subtracting(groups).sorted())")
        // Un uid sin usuario solo tiene su grupo principal.
        XCTAssertEqual(CallerAccess.groups(of: 4_000_000, primary: 4242), [4242])
    }

    /// Todas las combinaciones de modo, para propietario, miembro del grupo,
    /// otro usuario, root y volúmenes con la propiedad ignorada.
    func testAccessRuleForEveryMode() {
        let needs: [CallerAccess.Need] = [.read, .write, .search, [.write, .search], [.read, .write, .search]]
        let member = CallerAccess(uid: 501, gid: 20, isMember: { $0 == 80 })
        let root = CallerAccess(uid: 0, gid: 0, isMember: { _ in false })
        for mode in mode_t(0)...mode_t(0o777) {
            for need in needs {
                let bits = need.rawValue
                let ownerBits = (mode >> 6) & bits == bits
                let groupBits = (mode >> 3) & bits == bits
                let otherBits = mode & bits == bits
                let label = "mode \(String(mode, radix: 8)) need \(bits)"
                // Propietario: solo cuentan sus bits.
                XCTAssertEqual(member.permits(need, mode: mode, owner: 501, group: 0, ignoresOwnership: false),
                               ownerBits, label)
                // Grupo principal y grupo suplementario.
                XCTAssertEqual(member.permits(need, mode: mode, owner: 1, group: 20, ignoresOwnership: false),
                               groupBits, label)
                XCTAssertEqual(member.permits(need, mode: mode, owner: 1, group: 80, ignoresOwnership: false),
                               groupBits, label)
                // Sin pertenencia: hacen falta los bits de grupo y los de otros.
                XCTAssertEqual(member.permits(need, mode: mode, owner: 1, group: 99, ignoresOwnership: false),
                               groupBits && otherBits, label)
                XCTAssertTrue(member.permits(need, mode: mode, owner: 1, group: 99, ignoresOwnership: true), label)
                XCTAssertTrue(root.permits(need, mode: mode, owner: 1, group: 99, ignoresOwnership: false), label)
            }
        }
    }

    func testDestinationRefusesFolderCallerCannotWrite() throws {
        let readOnly = try folder("read-only", mode: 0o555)
        let shared = try folder("shared", mode: 0o755)
        for (url, access) in [(readOnly, me), (shared, other)] {
            let image = url.appendingPathComponent("clone.img")
            XCTAssertThrowsError(try ImageDestination.open(image.path, owner: nil, access: access)) {
                guard case CloneError.folderAccess(url.path) = $0 else {
                    return XCTFail("Expected folderAccess(\(url.path)), got \($0)")
                }
            }
        }
    }

    func testDestinationRefusesFolderInsideOneCallerCannotSearch() throws {
        let closed = try folder("closed", mode: 0o700)
        let open = try folder("open", mode: 0o777, in: closed)
        XCTAssertThrowsError(try ImageDestination.open(open.appendingPathComponent("clone.img").path,
                                                       owner: nil, access: other)) {
            guard case CloneError.folderAccess = $0 else { return XCTFail("Expected folderAccess, got \($0)") }
        }
        XCTAssertEqual(chmod(closed.path, 0o755), 0)
        XCTAssertNoThrow(try ImageDestination.open(open.appendingPathComponent("clone.img").path,
                                                   owner: nil, access: other))
    }

    func testDestinationRefusesMissingFolderAndRelativePathForCaller() {
        for path in [directory.appendingPathComponent("missing/clone.img").path, "relative/clone.img"] {
            XCTAssertThrowsError(try ImageDestination.open(path, owner: nil, access: me)) {
                guard case CloneError.folderAccess = $0 else { return XCTFail("Expected folderAccess, got \($0)") }
            }
        }
    }

    func testDestinationRejectsEmptyAndDotNames() {
        for path in ["", ".", "..", directory.path + "/", directory.path + "/.", directory.path + "/.."] {
            for access in [nil, me] as [CallerAccess?] {
                XCTAssertThrowsError(try ImageDestination.open(path, owner: nil, access: access)) {
                    guard case CloneError.badName(path) = $0 else {
                        return XCTFail("Expected badName(\(path)), got \($0)")
                    }
                }
            }
        }
    }

    func testDestinationResolvesSymlinkedFolderBeforeChecking() throws {
        let readOnly = try folder("read-only", mode: 0o555)
        let writable = try folder("writable", mode: 0o755)
        let toReadOnly = directory.appendingPathComponent("to-read-only")
        let toWritable = directory.appendingPathComponent("to-writable")
        try FileManager.default.createSymbolicLink(at: toReadOnly, withDestinationURL: readOnly)
        try FileManager.default.createSymbolicLink(at: toWritable, withDestinationURL: writable)

        XCTAssertThrowsError(try ImageDestination.open(toReadOnly.appendingPathComponent("clone.img").path,
                                                       owner: nil, access: me))
        let source = Data(repeating: 0x44, count: 4096)
        try writeImage(source, totalBytes: 4096, to: toWritable.appendingPathComponent("clone.img"), access: me)
        XCTAssertEqual(try Data(contentsOf: writable.appendingPathComponent("clone.img")), source)
    }

    func testImageIsRenamedWithinOpenedFolder() throws {
        let original = try folder("original", mode: 0o755)
        let moved = directory.appendingPathComponent("moved")
        let destination = try ImageDestination.open(original.appendingPathComponent("clone.img").path,
                                                    owner: nil, access: me)
        try FileManager.default.moveItem(at: original, to: moved)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)

        let source = Data(repeating: 0x55, count: 4096)
        try writeImage(source, totalBytes: 4096, to: destination)
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("clone.img")), source)
        XCTAssertFalse(exists(original.appendingPathComponent("clone.img")))
        XCTAssertFalse(exists(original.appendingPathComponent("clone.img.partial")))
    }

    func testExistingImageOfAnotherUserIsRefusedInStickyFolder() throws {
        let sticky = try folder("sticky", mode: 0o1777)
        let image = try file(sticky.appendingPathComponent("clone.img"), mode: 0o666)
        XCTAssertThrowsError(try writeImage(Data(repeating: 0x66, count: 4096), totalBytes: 4096,
                                            to: image, access: other)) {
            guard case CloneError.notYours(image.path) = $0 else {
                return XCTFail("Expected notYours, got \($0)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: image), Data(repeating: 0x5a, count: 4096))
        XCTAssertFalse(exists(partial(image)))
    }

    func testExistingImageOfAnotherUserIsReplacedInWritableFolder() throws {
        let shared = try folder("shared", mode: 0o777)
        let image = try file(shared.appendingPathComponent("clone.img"), mode: 0o644)
        let source = Data(repeating: 0x66, count: 4096)
        try writeImage(source, totalBytes: 4096, to: image, access: other)
        XCTAssertEqual(try Data(contentsOf: image), source)
    }

    func testExistingImageOfCallerIsReplaced() throws {
        let image = try file(directory.appendingPathComponent("clone.img"), mode: 0o644)
        let source = Data(repeating: 0x67, count: 4096)
        try writeImage(source, totalBytes: 4096, to: image, access: me)
        XCTAssertEqual(try Data(contentsOf: image), source)
    }

    func testStalePartialOfAnotherUserIsRefusedAndKeptInStickyFolder() throws {
        let sticky = try folder("sticky", mode: 0o1777)
        let image = sticky.appendingPathComponent("clone.img")
        try file(partial(image), mode: 0o666, contents: Data("someone else".utf8))
        XCTAssertThrowsError(try writeImage(Data(repeating: 0x68, count: 4096), totalBytes: 4096,
                                            to: image, access: other)) {
            guard case CloneError.stalePartial = $0 else { return XCTFail("Expected stalePartial, got \($0)") }
        }
        XCTAssertEqual(try Data(contentsOf: partial(image)), Data("someone else".utf8))
        XCTAssertFalse(exists(image))
    }

    func testStalePartialOfAnotherUserIsReplacedInWritableFolder() throws {
        let shared = try folder("shared", mode: 0o777)
        let image = shared.appendingPathComponent("clone.img")
        try file(partial(image), mode: 0o644, contents: Data("earlier".utf8))
        let source = Data(repeating: 0x68, count: 4096)
        try writeImage(source, totalBytes: 4096, to: image, access: other)
        XCTAssertEqual(try Data(contentsOf: image), source)
        XCTAssertFalse(exists(partial(image)))
    }

    func testStickyFolderOwnedByCallerAllowsReplacement() throws {
        // La carpeta (y el fichero) son del usuario que ejecuta las pruebas.
        let sticky = try folder("own-sticky", mode: 0o1777)
        let image = try file(sticky.appendingPathComponent("clone.img"), mode: 0o644)
        try file(partial(image), mode: 0o644, contents: Data("earlier".utf8))
        let source = Data(repeating: 0x6a, count: 4096)
        try writeImage(source, totalBytes: 4096, to: image, access: me)
        XCTAssertEqual(try Data(contentsOf: image), source)
    }

    /// Todas las combinaciones de modo de la carpeta y de propietarios.
    func testReplaceRuleForEveryFolderMode() {
        let caller = CallerAccess(uid: 501, gid: 20, isMember: { _ in false })
        let root = CallerAccess(uid: 0, gid: 0, isMember: { _ in false })
        for mode in mode_t(0)...mode_t(0o7777) {
            let sticky = mode & S_ISVTX != 0
            for fileOwner: uid_t in [501, 777] {
                for folderOwner: uid_t in [501, 777] {
                    let label = "mode \(String(mode, radix: 8)) file \(fileOwner) folder \(folderOwner)"
                    XCTAssertEqual(caller.mayReplace(fileOwner: fileOwner, directoryMode: mode,
                                                     directoryOwner: folderOwner, ignoresOwnership: false),
                                   !sticky || fileOwner == 501 || folderOwner == 501, label)
                    XCTAssertTrue(caller.mayReplace(fileOwner: fileOwner, directoryMode: mode,
                                                    directoryOwner: folderOwner, ignoresOwnership: true), label)
                    XCTAssertTrue(root.mayReplace(fileOwner: fileOwner, directoryMode: mode,
                                                  directoryOwner: folderOwner, ignoresOwnership: false), label)
                }
            }
        }
    }

    func testStalePartialOfCallerIsReplaced() throws {
        let image = directory.appendingPathComponent("clone.img")
        try file(partial(image), mode: 0o644, contents: Data("earlier".utf8))
        let source = Data(repeating: 0x69, count: 4096)
        try writeImage(source, totalBytes: 4096, to: image, access: me)
        XCTAssertEqual(try Data(contentsOf: image), source)
        XCTAssertFalse(exists(partial(image)))
    }

    func testRestoreRefusesFileCallerCannotRead() throws {
        let image = try file(directory.appendingPathComponent("private.img"), mode: 0o600)
        XCTAssertThrowsError(try Cloner.openRestoreImage(image.path, access: other)) {
            guard case CloneError.readAccess(image.path) = $0 else {
                return XCTFail("Expected readAccess, got \($0)")
            }
        }
        XCTAssertEqual(try Cloner.openRestoreImage(image.path, access: me).size, 4096)
        XCTAssertEqual(chmod(image.path, 0o644), 0)
        XCTAssertEqual(try Cloner.openRestoreImage(image.path, access: other).size, 4096)
    }

    func testRestoreRefusesFileInsideFolderCallerCannotSearch() throws {
        let closed = try folder("closed", mode: 0o700)
        let image = try file(closed.appendingPathComponent("disk.img"), mode: 0o644)
        XCTAssertThrowsError(try Cloner.openRestoreImage(image.path, access: other)) {
            guard case CloneError.readAccess = $0 else { return XCTFail("Expected readAccess, got \($0)") }
        }
    }

    func testRestoreReportsMissingImage() {
        let missing = directory.appendingPathComponent("missing.img").path
        XCTAssertThrowsError(try Cloner.openRestoreImage(missing, access: me)) {
            guard case CloneError.readAccess(missing) = $0 else { return XCTFail("Expected readAccess, got \($0)") }
        }
        XCTAssertThrowsError(try Cloner.openRestoreImage(missing, access: nil)) {
            guard case CloneError.cannotOpen(missing) = $0 else { return XCTFail("Expected cannotOpen, got \($0)") }
        }
    }

    func testRestoreSizeAndDataComeFromOpenedDescriptor() throws {
        let image = try file(directory.appendingPathComponent("disk.img"), mode: 0o644,
                             contents: Data(repeating: 0x71, count: 4096))
        for access in [nil, me] as [CallerAccess?] {
            let opened = try Cloner.openRestoreImage(image.path, access: access)
            let replacement = directory.appendingPathComponent("replacement")
            try Data(repeating: 0x72, count: 8192).write(to: replacement)
            XCTAssertEqual(rename(replacement.path, image.path), 0)
            XCTAssertEqual(opened.size, 4096)
            XCTAssertEqual(try opened.handle.readToEnd(), Data(repeating: 0x71, count: 4096))
            try opened.handle.close()
            try Data(repeating: 0x71, count: 4096).write(to: image)
        }
    }

    func testRestoreRefusesFifoAndFolderWithoutBlocking() throws {
        let fifo = directory.appendingPathComponent("pipe.img")
        XCTAssertEqual(mkfifo(fifo.path, 0o644), 0)
        let folderImage = try folder("folder.img", mode: 0o755)
        for path in [fifo.path, folderImage.path] {
            for access in [nil, me] as [CallerAccess?] {
                XCTAssertThrowsError(try Cloner.openRestoreImage(path, access: access)) {
                    guard case CloneError.notRegularFile(path) = $0 else {
                        return XCTFail("Expected notRegularFile(\(path)), got \($0)")
                    }
                }
            }
        }
    }

    func testRestoreFollowsSymlinkToReadableImage() throws {
        let image = try file(directory.appendingPathComponent("disk.img"), mode: 0o600)
        let link = directory.appendingPathComponent("link.img")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: image)
        XCTAssertEqual(try Cloner.openRestoreImage(link.path, access: me).size, 4096)
        XCTAssertEqual(try Cloner.openRestoreImage(link.path, access: nil).size, 4096)
        XCTAssertThrowsError(try Cloner.openRestoreImage(link.path, access: other))
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
