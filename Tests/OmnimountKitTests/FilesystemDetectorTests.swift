import XCTest
@testable import OmnimountKit

/// Fabrica imágenes de disco mínimas con los magic bytes de cada FS y
/// comprueba que el detector las identifica.
final class FilesystemDetectorTests: XCTestCase {

    private var tempFiles: [String] = []

    override func tearDown() {
        for path in tempFiles { try? FileManager.default.removeItem(atPath: path) }
        tempFiles = []
        super.tearDown()
    }

    private func writeImage(_ data: Data) -> String {
        let path = NSTemporaryDirectory() + "omnimount-test-\(UUID().uuidString).img"
        FileManager.default.createFile(atPath: path, contents: data)
        tempFiles.append(path)
        return path
    }

    /// Superbloque ext en offset 1024 con las flags indicadas.
    private func extImage(compat: UInt32, incompat: UInt32, roCompat: UInt32,
                          label: String? = nil) -> Data {
        var image = Data(count: 128 * 1024)
        image[1024 + 56] = 0x53
        image[1024 + 57] = 0xEF
        func put32(_ value: UInt32, at offset: Int) {
            for i in 0..<4 { image[1024 + offset + i] = UInt8((value >> (8 * i)) & 0xFF) }
        }
        put32(compat, at: 92)
        put32(incompat, at: 96)
        put32(roCompat, at: 100)
        if let label {
            let bytes = Array(label.utf8.prefix(16))
            for (i, byte) in bytes.enumerated() { image[1024 + 120 + i] = byte }
        }
        return image
    }

    func testDetectsExt4ByExtents() throws {
        let path = writeImage(extImage(compat: 0x0004, incompat: 0x0040, roCompat: 0, label: "EASYROMS"))
        let result = try FilesystemDetector.detect(devicePath: path)
        XCTAssertEqual(result.filesystem, .ext4)
        XCTAssertEqual(result.label, "EASYROMS")
    }

    func testDetectsExt3ByJournalWithoutExt4Features() throws {
        let path = writeImage(extImage(compat: 0x0004, incompat: 0, roCompat: 0))
        let result = try FilesystemDetector.detect(devicePath: path)
        XCTAssertEqual(result.filesystem, .ext3)
    }

    func testDetectsExt2WithoutJournal() throws {
        let path = writeImage(extImage(compat: 0, incompat: 0, roCompat: 0))
        let result = try FilesystemDetector.detect(devicePath: path)
        XCTAssertEqual(result.filesystem, .ext2)
    }

    func testDetectsNTFS() throws {
        var image = Data(count: 128 * 1024)
        image.replaceSubrange(3..<11, with: Data("NTFS    ".utf8))
        let result = try FilesystemDetector.detect(devicePath: writeImage(image))
        XCTAssertEqual(result.filesystem, .ntfs)
    }

    func testDetectsExFAT() throws {
        var image = Data(count: 128 * 1024)
        image.replaceSubrange(3..<11, with: Data("EXFAT   ".utf8))
        let result = try FilesystemDetector.detect(devicePath: writeImage(image))
        XCTAssertEqual(result.filesystem, .exfat)
    }

    func testDetectsFAT32() throws {
        var image = Data(count: 128 * 1024)
        image.replaceSubrange(82..<87, with: Data("FAT32".utf8))
        let result = try FilesystemDetector.detect(devicePath: writeImage(image))
        XCTAssertEqual(result.filesystem, .fat)
    }

    func testUnknownOnZeroes() throws {
        let result = try FilesystemDetector.detect(devicePath: writeImage(Data(count: 128 * 1024)))
        XCTAssertEqual(result.filesystem, .unknown)
    }

    func testRetroCardIdentification() {
        let partition = DiskPartition(
            deviceIdentifier: "disk4s2", parentWholeDisk: "disk4", content: "Linux Filesystem",
            volumeName: nil, size: 1024, mountPoint: nil, isWholeDisk: false)
        let match = RetroCards.identify(partitions: [partition],
                                        extLabels: ["disk4s2": "EASYROMS"])
        XCTAssertEqual(match?.firmware, "ArkOS")
    }
}
