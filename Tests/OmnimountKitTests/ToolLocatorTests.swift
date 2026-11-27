import XCTest
@testable import OmnimountKit

/// Búsqueda de herramientas con directorios temporales; no depende de lo que
/// haya instalado en la máquina salvo /sbin/newfs_msdos (parte de macOS).
final class ToolLocatorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("omnimount-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func makeTool(_ name: String, in folder: String) throws -> String {
        let dir = directory.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent(name).path
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(chmod(path, 0o755), 0)
        return path
    }

    private func policy(team: String? = "ABCDE12345") -> ToolLocator.TrustedToolPolicy {
        ToolLocator.TrustedToolPolicy(bundledToolDirectory: directory.appendingPathComponent("bundle").path,
                                      teamIdentifier: team)
    }

    private func standardFind(_ tool: ExternalTool, overrideDirectory: String) -> String? {
        ToolLocator.find(tool, environment: ["OMNIMOUNT_TOOL_DIR": overrideDirectory],
                         currentDirectory: directory.path,
                         executablePath: directory.appendingPathComponent("bin/omnimount").path)
    }

    // MARK: - Búsqueda normal (CLI)

    func testSystemFormatToolsResolveFromSbinBeforeOverrideDirectory() throws {
        try makeTool("newfs_msdos", in: "override")
        XCTAssertEqual(standardFind(.newfsMsdos, overrideDirectory: directory.appendingPathComponent("override").path),
                       "/sbin/newfs_msdos")
    }

    func testStandardLookupStillHonoursToolDirectoryOverride() throws {
        let tool = try makeTool("fuse2fs", in: "override")
        XCTAssertEqual(standardFind(.fuse2fs, overrideDirectory: directory.appendingPathComponent("override").path),
                       tool)
    }

    // MARK: - Búsqueda restringida (helper)

    func testTrustedPolicyIgnoresEnvironmentAndWorkingDirectory() throws {
        try makeTool("fuse2fs", in: "override")
        try makeTool("fuse2fs", in: "vendor/bin")
        try makeTool("fuse2fs", in: "bin/vendor/bin")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("bundle"),
                                                withIntermediateDirectories: true)
        setenv("OMNIMOUNT_TOOL_DIR", directory.appendingPathComponent("override").path, 1)
        defer { unsetenv("OMNIMOUNT_TOOL_DIR") }
        let previous = FileManager.default.currentDirectoryPath
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(directory.path))
        defer { FileManager.default.changeCurrentDirectoryPath(previous) }

        XCTAssertNil(ToolLocator.find(.fuse2fs, trusted: policy(), verify: { _, _ in true }))
    }

    func testTrustedPolicySystemToolsOnlyFromSbin() throws {
        try makeTool("newfs_msdos", in: "bundle")
        XCTAssertEqual(ToolLocator.find(.newfsMsdos, trusted: policy(), verify: { _, _ in
            XCTFail("System tools are not checked against the Team ID")
            return false
        }), "/sbin/newfs_msdos")
    }

    func testTrustedPolicyReturnsBundledToolThatPassesVerification() throws {
        let tool = try makeTool("mkfs.ext4", in: "bundle")
        var checked: [String] = []
        XCTAssertEqual(ToolLocator.find(.mkfsExt4, trusted: policy(), verify: { path, team in
            XCTAssertEqual(team, "ABCDE12345")
            checked.append(path)
            return true
        }), tool)
        XCTAssertEqual(checked, [tool])
    }

    func testTrustedPolicyVerifiesOnEveryLookup() throws {
        try makeTool("e2fsck", in: "bundle")
        var calls = 0
        let verify: (String, String) -> Bool = { _, _ in calls += 1; return calls == 1 }
        XCTAssertNotNil(ToolLocator.find(.e2fsck, trusted: policy(), verify: verify))
        XCTAssertNil(ToolLocator.find(.e2fsck, trusted: policy(), verify: verify))
        XCTAssertEqual(calls, 2)
    }

    func testTrustedPolicyWithoutTeamIdentifierFindsNoBundledTool() throws {
        try makeTool("fuse2fs", in: "bundle")
        for team in [nil, "", "not-a-team"] as [String?] {
            XCTAssertNil(ToolLocator.find(.fuse2fs, trusted: policy(team: team), verify: { _, _ in true }))
        }
    }

    func testTrustedPolicyRejectsUnsignedBundledTool() throws {
        try makeTool("ntfs-3g", in: "bundle")
        XCTAssertNil(ToolLocator.find(.ntfs3g, trusted: policy(), verify: ToolLocator.satisfiesTeamRequirement))
    }

    func testTrustedPolicyRefusesSymlinkedBundledTool() throws {
        let real = try makeTool("tune2fs-real", in: "bundle")
        try FileManager.default.createSymbolicLink(
            atPath: directory.appendingPathComponent("bundle/tune2fs").path, withDestinationPath: real)
        XCTAssertNil(ToolLocator.find(.tune2fs, trusted: policy(), verify: { _, _ in true }))
    }

    func testTrustedPolicyRefusesNonExecutableBundledTool() throws {
        let tool = try makeTool("ntfsfix", in: "bundle")
        XCTAssertEqual(chmod(tool, 0o644), 0)
        XCTAssertNil(ToolLocator.find(.ntfsfix, trusted: policy(), verify: { _, _ in true }))
    }

    func testTrustedPolicyNeverReturnsCLI() throws {
        try makeTool("omnimount-cli", in: "bundle")
        try makeTool("omnimount", in: "bundle")
        XCTAssertNil(ToolLocator.find(.omnimountCLI, trusted: policy(), verify: { _, _ in true }))
    }
}
