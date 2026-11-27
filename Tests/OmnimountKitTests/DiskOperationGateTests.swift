import XCTest
@testable import OmnimountKit

final class DiskOperationGateTests: XCTestCase {

    func testWholeDiskIdentifierParsing() {
        let cases: [(String, String?)] = [
            ("disk4", "disk4"), ("disk4s1", "disk4"), ("/dev/disk4s2", "disk4"),
            ("rdisk4", "disk4"), ("/dev/rdisk12s3", "disk12"), ("disk4s1s2", "disk4"),
            ("disk", nil), ("disks1", nil), ("disk4s", nil), ("disk4x1", nil),
            ("/Volumes/disk4", nil), ("", nil), ("disk٤", nil), ("Disk4", nil),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(DiskOperationGate.wholeDiskIdentifier(input), expected, input)
        }
    }

    func testPartitionConflictsWithItsWholeDisk() throws {
        let gate = DiskOperationGate()
        try gate.run(on: "disk4") {
            XCTAssertThrowsError(try gate.run(on: "disk4s1") { XCTFail("Must not run") }) {
                XCTAssertEqual($0 as? DiskOperationError, .busy("disk4"))
            }
            XCTAssertThrowsError(try gate.run(on: "/dev/disk4s2") { XCTFail("Must not run") })
        }
    }

    func testDifferentDisksDoNotConflict() throws {
        let gate = DiskOperationGate()
        var ran = false
        try gate.run(on: "disk1s1") {
            try gate.run(on: "disk10") { ran = true }
        }
        XCTAssertTrue(ran)
    }

    func testReservationReleasedWhenBodyThrows() throws {
        struct Failure: Error {}
        let gate = DiskOperationGate()
        XCTAssertThrowsError(try gate.run(on: "disk5") { throw Failure() })
        XCTAssertEqual(try gate.run(on: "disk5s1") { 7 }, 7)
    }

    func testIdentifierThatIsNotADiskIsNotReserved() throws {
        let gate = DiskOperationGate()
        try gate.run(on: "not-a-disk") {
            XCTAssertNoThrow(try gate.run(on: "not-a-disk") {})
        }
    }

    func testConcurrentRequestsAdmitExactlyOne() {
        let gate = DiskOperationGate()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var admitted = 0
        var refused = 0
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) {
            try? gate.run(on: "disk7s1") {
                lock.lock(); admitted += 1; lock.unlock()
                started.signal()
                release.wait()
            }
        }
        started.wait()
        DispatchQueue.concurrentPerform(iterations: 16) { index in
            do {
                try gate.run(on: index.isMultiple(of: 2) ? "disk7" : "disk7s\(index)") {
                    lock.lock(); admitted += 1; lock.unlock()
                }
            } catch {
                lock.lock(); refused += 1; lock.unlock()
            }
        }
        release.signal()
        group.wait()
        XCTAssertEqual(admitted, 1)
        XCTAssertEqual(refused, 16)
    }
}
