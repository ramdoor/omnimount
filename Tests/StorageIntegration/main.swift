import Foundation

// Compiled alongside OmnimountKit so the same streaming and preflight code can
// be exercised on ordinary, disposable image files without granting root.
func regularFile(_ path: String) throws -> Int64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
          let size = attributes[.size] as? NSNumber else {
        throw NSError(domain: "ImageIntegration", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Expected a regular image file"])
    }
    return size.int64Value
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count >= 2 else { fatalError("copy <source> <destination> | detect/probe/preflight <path>") }
    switch arguments[0] {
    case "copy":
        guard arguments.count == 3,
              !FileManager.default.fileExists(atPath: arguments[2]) else {
            fatalError("Copy destination must be a new regular file")
        }
        let size = try regularFile(arguments[1])
        let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: arguments[1]))
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: arguments[2], contents: nil) else {
            fatalError("Could not create image")
        }
        let output = try FileHandle(forWritingTo: URL(fileURLWithPath: arguments[2]))
        defer { try? output.close() }
        try Cloner.copyStream(from: input, to: output, totalBytes: size) { progress in
            precondition(progress.bytesCopied <= progress.totalBytes)
        }
        print("Copied \(size) bytes using Cloner.copyStream")
    case "detect":
        _ = try regularFile(arguments[1])
        let result = try FilesystemDetector.detect(devicePath: arguments[1])
        print("\(result.filesystem.rawValue) quota=\(result.extQuotaEnabled)")
    case "preflight":
        _ = try regularFile(arguments[1])
        try Mounter.preflightExtMount(devicePath: arguments[1], deviceIdentifier: "test-image", readOnly: false)
        print("ext preflight passed")
    case "repair-quota":
        _ = try regularFile(arguments[1])
        try Mounter.repairExtQuota(devicePath: arguments[1])
        print("ext quota repair passed")
    case "ntfs-preflight":
        _ = try regularFile(arguments[1])
        try Mounter.prepareNtfsForWriting(devicePath: arguments[1], mountPoint: nil)
        print("NTFS writable preparation passed")
    case "probe":
        guard Mounter.isMountPoint(arguments[1]) else { fatalError("Probe requires an actual mount") }
        print(Mounter.isMountReadOnly(arguments[1]) ? "read-only" : "writable")
    default: fatalError("Unknown image test operation")
    }
} catch MountError.ext4NeedsRepair(let device, let detail) {
    fputs("ext4NeedsRepair: \(device): \(detail)\n", stderr)
    exit(2)
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
