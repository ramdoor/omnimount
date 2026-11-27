import XCTest
@testable import OmnimountKit

final class DiskBusyRegistryTests: XCTestCase {
    func testPartitionOperationLocksWholeDisk() {
        var registry = DiskBusyRegistry()
        XCTAssertTrue(registry.begin(target: "disk4s1", wholeDisk: "disk4"))
        XCTAssertTrue(registry.isTarget("disk4s1"))
        XCTAssertFalse(registry.isTarget("disk4s2"))
        XCTAssertTrue(registry.isDiskBusy("disk4"))
        // Otra partición del mismo disco y el disco entero quedan bloqueados.
        XCTAssertFalse(registry.begin(target: "disk4s2", wholeDisk: "disk4"))
        XCTAssertFalse(registry.begin(target: "disk4", wholeDisk: "disk4"))
        XCTAssertFalse(registry.isTarget("disk4s2"))
    }

    func testWholeDiskOperationLocksItsPartitions() {
        var registry = DiskBusyRegistry()
        XCTAssertTrue(registry.begin(target: "disk4", wholeDisk: "disk4"))
        XCTAssertFalse(registry.begin(target: "disk4s1", wholeDisk: "disk4"))
    }

    func testOtherDisksStayFree() {
        var registry = DiskBusyRegistry()
        XCTAssertTrue(registry.begin(target: "disk4s1", wholeDisk: "disk4"))
        XCTAssertFalse(registry.isDiskBusy("disk5"))
        // "disk4" no debe confundirse con "disk40" por prefijo.
        XCTAssertFalse(registry.isDiskBusy("disk40"))
        XCTAssertTrue(registry.begin(target: "disk5s1", wholeDisk: "disk5"))
    }

    func testEndReleases() {
        var registry = DiskBusyRegistry()
        XCTAssertTrue(registry.isEmpty)
        XCTAssertTrue(registry.begin(target: "disk4s1", wholeDisk: "disk4"))
        XCTAssertFalse(registry.isEmpty)
        registry.end(target: "disk4s1")
        XCTAssertTrue(registry.isEmpty)
        XCTAssertFalse(registry.isDiskBusy("disk4"))
        XCTAssertTrue(registry.begin(target: "disk4s2", wholeDisk: "disk4"))
    }

    func testEndOfUnknownTargetIsHarmless() {
        var registry = DiskBusyRegistry()
        XCTAssertTrue(registry.begin(target: "disk4s1", wholeDisk: "disk4"))
        registry.end(target: "disk4s2")
        XCTAssertTrue(registry.isDiskBusy("disk4"))
    }
}
