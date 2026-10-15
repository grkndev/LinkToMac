import Foundation
import Testing

@Suite struct BurstCounterTests {
    @Test func countsFilesInOneBurst() {
        var burst = BurstCounter(gap: 30)
        let t = Date(timeIntervalSince1970: 1_000)
        #expect(burst.note(at: t) == 1)
        #expect(burst.note(at: t.addingTimeInterval(2)) == 2)
        #expect(burst.note(at: t.addingTimeInterval(10)) == 3)
    }

    @Test func aQuietGapStartsANewBurst() {
        var burst = BurstCounter(gap: 30)
        let t = Date(timeIntervalSince1970: 1_000)
        _ = burst.note(at: t)
        _ = burst.note(at: t.addingTimeInterval(5))
        // 31 s after the LAST file, not the first: the gap is measured from the latest arrival.
        #expect(burst.note(at: t.addingTimeInterval(36)) == 1)
        #expect(burst.note(at: t.addingTimeInterval(40)) == 2)
    }

    @Test func aSlowTrickleStaysOneBurst() {
        var burst = BurstCounter(gap: 30)
        var t = Date(timeIntervalSince1970: 1_000)
        for expected in 1...5 {
            #expect(burst.note(at: t) == expected)
            t = t.addingTimeInterval(25) // each arrival within 30 s of the previous
        }
    }
}
