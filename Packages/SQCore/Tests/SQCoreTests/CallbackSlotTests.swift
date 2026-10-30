import Foundation
import Synchronization
import Testing
@testable import SQCore

@Suite struct CallbackSlotTests {
    @Test func callingManyTimesKeepsTheStackFlat() async {
        let slot = CallbackSlot()
        let count = Mutex(0)
        slot.set { count.withLock { $0 += 1 } }
        // Small stack: a thunk chain that grew per call would overflow it long before 100k calls.
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let t = Thread {
                for _ in 0..<100_000 { slot.call() }
                c.resume()
            }
            t.stackSize = 256 * 1024
            t.start()
        }
        #expect(count.withLock { $0 } == 100_000)
    }

    @Test func clearedAndTakenSlotsDoNothing() {
        let slot = CallbackSlot()
        let count = Mutex(0)
        slot.set { count.withLock { $0 += 1 } }
        slot.set(nil)
        slot.call()
        slot.set { count.withLock { $0 += 1 } }
        slot.take()?()
        slot.call()
        #expect(count.withLock { $0 } == 1)
    }
}
