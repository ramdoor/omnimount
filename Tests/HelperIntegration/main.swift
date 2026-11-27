import Foundation

// Compile beside Sources/OmnimountKit/HelperProtocol.swift, then sign this
// executable with the same team as the installed helper and the signing
// identifier the helper accepts for this client:
//   codesign --force --identifier org.omnimount.helper-integration --sign <identity> <executable>
// This runner does not register services, install apps, or modify privileges.

struct RunnerError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw RunnerError(message: message) }
}

struct Options {
    var command: String
    var arguments: [String] = []
    var authorizedWholeDisk: String?
    var workspace: String?
    var readOnly = false

    init(_ input: [String]) throws {
        guard let command = input.first else {
            throw RunnerError(message: "Expected version, fda, detect, detect-invalid, mount, unmount, clone, restore, fix-quota, or make-writable")
        }
        self.command = command
        var index = 1
        while index < input.count {
            let value = input[index]
            if value == "--read-only" {
                readOnly = true
            } else if value == "--allow-mutations-on" || value == "--workspace" {
                index += 1
                try require(index < input.count, "Missing value for \(value)")
                if value == "--workspace" { workspace = input[index] }
                else { authorizedWholeDisk = input[index] }
            } else {
                try require(!value.hasPrefix("--"), "Unknown option \(value)")
                arguments.append(value)
            }
            index += 1
        }
        try require(!readOnly || command == "mount", "--read-only applies only to mount")
    }
}

func diskutil(_ arguments: [String]) throws -> [String: Any] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.standardError
    try process.run()
    let bytes = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try require(process.terminationReason == .exit && process.terminationStatus == 0,
                "diskutil failed during the device safety check")
    guard let plist = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any] else {
        throw RunnerError(message: "Could not decode diskutil safety information")
    }
    return plist
}

func validIdentifier(_ value: String) -> Bool {
    value.range(of: #"^disk\d+(s\d+)*$"#, options: .regularExpression) != nil
}

// Every request capable of mutation must explicitly name one currently present
// external physical disk. Images, internal disks, and unrelated targets fail
// before an XPC connection is opened. This does not change helper policy.
func authorizeTarget(_ target: String, options: Options) throws -> [String: Any] {
    guard let whole = options.authorizedWholeDisk else {
        throw RunnerError(message: "Mutation requires --allow-mutations-on diskN for the user's approved disposable disk")
    }
    try require(whole.range(of: #"^disk\d+$"#, options: .regularExpression) != nil,
                "Authorization must name a whole disk, such as disk12")
    try require(validIdentifier(target), "Expected a BSD disk identifier without /dev/")
    let listing = try diskutil(["list", "-plist", "external", "physical"])
    let disks = listing["AllDisksAndPartitions"] as? [[String: Any]] ?? []
    guard let disk = disks.first(where: { $0["DeviceIdentifier"] as? String == whole }) else {
        throw RunnerError(message: "Approved disk \(whole) is not an external physical disk")
    }
    let parts = disk["Partitions"] as? [[String: Any]] ?? []
    try require(target == whole || parts.contains(where: { $0["DeviceIdentifier"] as? String == target }),
                "Target \(target) does not belong to approved disk \(whole)")
    let info = try diskutil(["info", "-plist", whole])
    try require(info["Internal"] as? Bool == false && info["VirtualOrPhysical"] as? String == "Physical",
                "Target safety check requires a physical, non-internal disk")
    return ["authorized_whole_disk": whole,
            "target": target,
            "media_name": info["MediaName"] as? String ?? "",
            "size_bytes": info["TotalSize"] as? NSNumber ?? 0,
            "bus_protocol": info["BusProtocol"] as? String ?? ""]
}

func imagePath(_ path: String, options: Options, destination: Bool) throws -> String {
    guard let workspace = options.workspace else {
        throw RunnerError(message: "clone/restore require --workspace with a dedicated directory owned by this user")
    }
    try require(getuid() != 0, "Run the signed test client as the ordinary user; the service owns privilege escalation")
    let directory = URL(fileURLWithPath: workspace).standardizedFileURL.resolvingSymlinksInPath()
    let attrs = try FileManager.default.attributesOfItem(atPath: directory.path)
    try require(attrs[.type] as? FileAttributeType == .typeDirectory
                && (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                "Workspace must be a directory owned by the calling user")
    let candidate = URL(fileURLWithPath: path).standardizedFileURL
    try require(candidate.pathExtension == "img", "Use a .img file in the approved workspace")
    try require(candidate.deletingLastPathComponent().resolvingSymlinksInPath() == directory,
                "Image must be a direct child of the approved workspace")
    let normalized = directory.appendingPathComponent(candidate.lastPathComponent).path
    if destination {
        // attributesOfItem also detects dangling symlinks, unlike fileExists.
        do {
            _ = try FileManager.default.attributesOfItem(atPath: normalized)
            throw RunnerError(message: "Clone destination already exists; this runner never overwrites images")
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            // Expected new destination.
        }
    } else {
        let attrs = try FileManager.default.attributesOfItem(atPath: normalized)
        try require(attrs[.type] as? FileAttributeType == .typeRegular
                    && ((attrs[.size] as? NSNumber)?.int64Value ?? 0) > 0,
                    "Restore source must be a nonempty regular file, not a symlink")
        try require((attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                    "Restore source must belong to the calling user")
    }
    return normalized
}

final class HelperIntegration {
    private let connection = NSXPCConnection(machServiceName: HelperConstants.machServiceName,
                                               options: .privileged)
    private let options: Options
    private var arguments: [String]
    private var result: [String: Any]
    private var completed = false
    private let timeout: TimeInterval

    init(options: Options) throws {
        self.options = options
        arguments = options.arguments
        result = ["command": options.command, "service": HelperConstants.machServiceName,
                  "client_protocol": HelperConstants.protocolVersion]
        let expectedArguments: Int
        switch options.command {
        case "version", "fda", "detect-invalid": expectedArguments = 0; timeout = 15
        case "detect": expectedArguments = 1; timeout = 30
        case "mount": expectedArguments = 1; timeout = 1800
        case "unmount": expectedArguments = 1; timeout = 60
        case "clone", "restore": expectedArguments = 2; timeout = 21600
        case "fix-quota", "make-writable": expectedArguments = 1; timeout = 300
        default: throw RunnerError(message: "Unknown command \(options.command)")
        }
        try require(arguments.count == expectedArguments,
                    "\(options.command) expects \(expectedArguments) positional argument(s)")
        if options.command == "detect" {
            try require(validIdentifier(arguments[0]), "Expected BSD disk identifier")
        } else if ["mount", "unmount", "clone", "restore", "fix-quota", "make-writable"].contains(options.command) {
            let target = options.command == "restore" ? arguments[1] : arguments[0]
            result["device_guard"] = try authorizeTarget(target, options: options)
            if options.command == "clone" { arguments[1] = try imagePath(arguments[1], options: options, destination: true) }
            if options.command == "restore" { arguments[0] = try imagePath(arguments[0], options: options, destination: false) }
        }
        result["arguments"] = arguments
        result["timeout_seconds"] = timeout
    }

    func start() {
        connection.remoteObjectInterface = NSXPCInterface(with: OmnimountHelperProtocol.self)
        connection.resume()
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            self.finish(false, message: "XPC timed out; the helper operation may still be running. Do not retry a mutation until its state is checked.")
        }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            DispatchQueue.main.async { self.finish(false, message: error.localizedDescription) }
        }) as? OmnimountHelperProtocol else {
            finish(false, message: "Could not create XPC proxy")
            return
        }
        let reply: (Bool, String) -> Void = { ok, message in
            DispatchQueue.main.async { self.finish(ok, message: message) }
        }
        switch options.command {
        case "version":
            proxy.version { version in
                DispatchQueue.main.async {
                    self.result["protocol"] = version
                    self.finish(version == HelperConstants.protocolVersion, message: version)
                }
            }
        case "fda":
            proxy.checkFullDiskAccess { granted in
                DispatchQueue.main.async {
                    self.result["full_disk_access"] = granted
                    self.finish(granted, message: granted ? "Full Disk Access available" : "Full Disk Access unavailable")
                }
            }
        case "detect", "detect-invalid":
            let identifier = options.command == "detect-invalid" ? "omnimount-validation-invalid-device" : arguments[0]
            proxy.detect(deviceIdentifier: identifier) { ok, message, label in
                DispatchQueue.main.async {
                    self.result["operation_succeeded"] = ok
                    self.result["label"] = label.map { $0 as Any } ?? NSNull()
                    let passed = self.options.command == "detect-invalid" ? !ok && message.contains(identifier) : ok
                    self.finish(passed, message: message)
                }
            }
        case "mount": proxy.mount(deviceIdentifier: arguments[0], readOnly: options.readOnly, reply: reply)
        case "unmount": proxy.unmount(target: arguments[0], reply: reply)
        case "clone": proxy.clone(deviceIdentifier: arguments[0], imagePath: arguments[1], reply: reply)
        case "restore": proxy.restore(imagePath: arguments[0], deviceIdentifier: arguments[1], reply: reply)
        case "fix-quota": proxy.fixQuota(deviceIdentifier: arguments[0], reply: reply)
        case "make-writable": proxy.makeWritable(deviceIdentifier: arguments[0], reply: reply)
        default: preconditionFailure("Validated command expected")
        }
    }

    private func finish(_ passed: Bool, message: String) {
        guard !completed else { return }
        completed = true
        result["passed"] = passed
        result["message"] = message
        connection.invalidate()
        output(result)
        exit(passed ? 0 : 1)
    }
}

func output(_ value: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

do {
    let runner = try HelperIntegration(options: Options(Array(CommandLine.arguments.dropFirst())))
    runner.start()
    RunLoop.main.run()
} catch {
    output(["passed": false, "stage": "client_validation", "error": error.localizedDescription])
    exit(2)
}
