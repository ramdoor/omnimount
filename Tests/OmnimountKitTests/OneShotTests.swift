import XCTest
@testable import OmnimountKit

final class OneShotTests: XCTestCase {
    func testFiresExactlyOnceUnderConcurrency() {
        let lock = NSLock()
        var deliveries: [Int] = []
        let once = OneShot<Int> { value in
            lock.lock(); deliveries.append(value); lock.unlock()
        }
        let winners = LockedCounter()
        DispatchQueue.concurrentPerform(iterations: 1000) { i in
            if once.fire(i) { winners.increment() }
        }
        XCTAssertEqual(deliveries.count, 1)
        XCTAssertEqual(winners.value, 1)
    }

    func testLaterCallsAreIgnored() {
        var received: [String] = []
        let once = OneShot<String> { received.append($0) }
        XCTAssertTrue(once.fire("first"))
        XCTAssertFalse(once.fire("second"))
        XCTAssertEqual(received, ["first"])
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
