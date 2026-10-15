import Foundation
import Testing

@Suite struct AckWindowTests {
    @Test func fillsThenTimesOut() {
        let window = AckWindow(capacity: 2)
        #expect(window.reserve(0, timeout: 1) == .ok)
        #expect(window.reserve(1, timeout: 1) == .ok)
        #expect(window.reserve(2, timeout: 0.05) == .timeout)
    }

    @Test func acknowledgingFreesASlot() {
        let window = AckWindow(capacity: 1)
        #expect(window.reserve(0, timeout: 1) == .ok)
        window.acknowledge(0)
        #expect(window.reserve(1, timeout: 1) == .ok)
    }

    @Test func duplicateAndStrayAcksAreHarmless() {
        let window = AckWindow(capacity: 2)
        #expect(window.reserve(0, timeout: 1) == .ok)
        window.acknowledge(0)
        window.acknowledge(0)
        window.acknowledge(99)
        #expect(window.reserve(1, timeout: 1) == .ok)
        #expect(window.reserve(2, timeout: 1) == .ok)
        // Two in flight is still the cap; the stray acks above did not widen it.
        #expect(window.reserve(3, timeout: 0.05) == .timeout)
    }

    @Test func failWakesAWaiterImmediately() async {
        let window = AckWindow(capacity: 1)
        #expect(window.reserve(0, timeout: 1) == .ok)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { window.fail("nope") }
        let started = Date()
        let outcome = window.reserve(1, timeout: 10)
        #expect(outcome == .failed("nope"))
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test func firstFailureReasonWins() {
        let window = AckWindow(capacity: 1)
        window.fail("first")
        window.fail("second")
        #expect(window.reserve(0, timeout: 0.05) == .failed("first"))
        #expect(window.drain(timeout: 0.05) == .failed("first"))
    }

    @Test func drainWaitsForEveryOutstandingAck() {
        let window = AckWindow(capacity: 4)
        for seq in 0..<3 { #expect(window.reserve(seq, timeout: 1) == .ok) }
        #expect(window.drain(timeout: 0.05) == .timeout)
        for seq in 0..<3 { window.acknowledge(seq) }
        #expect(window.drain(timeout: 0.05) == .ok)
    }

    /// Regression for the shipped crash. A `DispatchSemaphore` deallocated below its initial value
    /// kills the process; this window must be droppable in any state, over and over.
    @Test func abandoningAShortWindowIsSafe() {
        for _ in 0..<50 {
            var window: AckWindow? = AckWindow(capacity: 4)
            _ = window?.reserve(0, timeout: 1)
            _ = window?.reserve(1, timeout: 1)
            window?.fail("abandoned")
            window = nil
        }
    }
}
