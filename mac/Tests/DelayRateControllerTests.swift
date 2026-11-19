import Foundation
import Testing

/// The delay-driven file-rate controller (stage 0.7, plan Faz 6.1). The unit tests pin each rule of the control law on hand-made
/// samples; the simulation tests drive it against a fluid bottleneck (queue = backlog / capacity, a 1 MiB hand-off buffer in front of
/// it, like the server's send pump) to check the behaviour that matters: it finds the knee, follows the capacity down and up, and
/// keeps the queue short.
@Suite struct DelayRateControllerTests {
    private let ms: UInt64 = 1_000_000
    private let offset: UInt64 = 7_000_000_000_000   // the simulation's Mac clock epoch (the phone stamp and the arrival share it, so d is unaffected)

    /// Feeds `count` video samples spaced `spacingNs` apart, ending at `endNs`, each with queueing delay `queueMs` on top of a 5 ms path.
    private func feed(_ c: inout DelayRateController, endNs: UInt64, count: Int, queueMs: Double, spacingNs: UInt64 = 16_666_667) {
        for i in 0 ..< count {
            let arrival = endNs - UInt64(count - 1 - i) * spacingNs
            let delay = UInt64((5 + queueMs) * 1e6)
            c.addSample(sendNs: arrival - delay, arrivalNs: arrival)
        }
    }

    /// A controller that has seen a calm second at t = `startNs`, so the next ticks have a base delay and a signal.
    private func calm(_ config: DelayRateController.Config = .init(), startNs: UInt64 = 40_000_000_000) -> DelayRateController {
        var c = DelayRateController(config: config)
        feed(&c, endNs: startNs, count: 60, queueMs: 0)
        c.tick(nowNs: startNs, sentBytes: 0)   // first tick only arms the clock
        return c
    }

    private func sent(_ c: DelayRateController, dtNs: UInt64, utilisation: Double = 1) -> Int {
        Int(c.rate * Double(dtNs) / 1e9 * utilisation)
    }

    // MARK: signal

    @Test func noSignalHoldsTheRate() {
        var c = DelayRateController()
        c.tick(nowNs: 1_000_000_000, sentBytes: 0)
        let r = c.tick(nowNs: 1_100_000_000, sentBytes: 100_000)
        #expect(r == c.config.startRate)
        #expect(c.state == .noSignal)
        #expect(c.queueMs == nil)
    }

    @Test func tooFewSamplesOrStaleSamplesHoldTheRate() {
        var few = DelayRateController()
        few.tick(nowNs: 10_000_000_000, sentBytes: 0)
        feed(&few, endNs: 10_100_000_000, count: 5, queueMs: 0)
        few.tick(nowNs: 10_100_000_000, sentBytes: 200_000)
        #expect(few.state == .noSignal)

        var stale = calm()
        // 3 s of silence (the video paused): the newest sample is older than `staleNs`.
        stale.tick(nowNs: 43_100_000_000, sentBytes: 6_000_000)
        #expect(stale.state == .noSignal)
        #expect(stale.rate == stale.config.startRate)
    }

    @Test func silenceNeverChangesTheRate() {
        var c = calm()
        let before = c.rate
        for step in 1 ... 50 {
            c.tick(nowNs: 40_000_000_000 + UInt64(step) * 100 * ms + 5_000_000_000, sentBytes: 200_000)
        }
        #expect(c.rate == before)
    }

    @Test func theQueueIsTheWindowMedianAboveTheCalmLevelOfTheLast30Seconds() {
        var c = calm()
        feed(&c, endNs: 40_600_000_000, count: 36, queueMs: 10)
        c.tick(nowNs: 40_600_000_000, sentBytes: 0)
        #expect(abs((c.queueMs ?? -1) - 10) < 0.01)
    }

    @Test func theCalmLevelRisesWhenTheCalmSamplesAgeOut() {
        var c = calm()
        // 31 s of a standing 10 ms queue: the calm samples left the 30 s window, so the calm level followed the queue up and it now
        // reads as zero (the documented "latecomer" limit of any delay-based control; a periodic probe is a later step).
        var t: UInt64 = 40_000_000_000
        for _ in 0 ..< 31 {
            t += 1_000_000_000
            feed(&c, endNs: t, count: 60, queueMs: 10)
        }
        c.tick(nowNs: t, sentBytes: 0)
        #expect((c.queueMs ?? 99) < 0.5)
    }

    @Test func aConstantClockOffsetChangesNothing() {
        var a = DelayRateController(), b = DelayRateController()
        for i in 0 ..< 60 {
            let arrival = 40_000_000_000 + UInt64(i) * 16_666_667
            let delay = UInt64((5 + (i > 40 ? 12.0 : 0)) * 1e6)
            a.addSample(sendNs: arrival - delay, arrivalNs: arrival)
            b.addSample(sendNs: arrival - delay + 3_333_000_000_000, arrivalNs: arrival)   // phone clock 3333 s ahead
        }
        a.tick(nowNs: 39_000_000_000, sentBytes: 0); b.tick(nowNs: 39_000_000_000, sentBytes: 0)
        a.tick(nowNs: 41_000_000_000, sentBytes: 0); b.tick(nowNs: 41_000_000_000, sentBytes: 0)
        #expect(a.queueMs == b.queueMs)
    }

    @Test func aShortSpikeDoesNotMoveTheMedianButASustainedOneDoes() {
        var spiky = calm()
        // 36 samples in the window, 8 of them (22 %) 50 ms late: the median stays at the floor.
        var t: UInt64 = 40_100_000_000
        for i in 0 ..< 36 {
            let arrival = t + UInt64(i) * 16_666_667
            let delay = UInt64((5 + (i < 8 ? 50.0 : 0)) * 1e6)
            spiky.addSample(sendNs: arrival - delay, arrivalNs: arrival)
        }
        t += 36 * 16_666_667
        spiky.tick(nowNs: t, sentBytes: 0)
        #expect((spiky.queueMs ?? 99) < 1)

        var sustained = calm()
        t = 40_100_000_000
        for i in 0 ..< 36 {
            let arrival = t + UInt64(i) * 16_666_667
            let delay = UInt64((5 + (i < 20 ? 50.0 : 0)) * 1e6)   // 56 % of the window late
            sustained.addSample(sendNs: arrival - delay, arrivalNs: arrival)
        }
        t += 36 * 16_666_667
        sustained.tick(nowNs: t, sentBytes: 0)
        #expect((sustained.queueMs ?? 0) > 40)
    }

    // MARK: the floor and ambient noise

    @Test func theDefaultFloorIsTwoMegabytesPerSecond() {
        var c = calm()
        var t: UInt64 = 40_000_000_000
        for _ in 0 ..< 12 {   // hammer it with critical queues
            t += 600 * ms
            feed(&c, endNs: t, count: 36, queueMs: 200)
            c.tick(nowNs: t, sentBytes: sent(c, dtNs: 600 * ms))
        }
        #expect(c.rate == 2e6)
        #expect(c.config.minRate == 2e6)
    }

    /// A controller sitting at the floor (2 MB/s, after one cut from a high start), ready for ticks.
    private func atTheFloor() -> (DelayRateController, UInt64) {
        var config = DelayRateController.Config()
        config.startRate = 2.4e6   // one cut (x0.7) lands below the floor and clamps to it
        var c = calm(config)
        let t: UInt64 = 40_100_000_000
        feed(&c, endNs: t, count: 36, queueMs: 10)
        c.tick(nowNs: t, sentBytes: sent(c, dtNs: 100 * ms))
        return (c, t)
    }

    @Test func aHighQueueAtTheFloorIsTakenForAmbientNoiseAfterASecond() {
        var (c, t) = atTheFloor()
        #expect(c.rate == 2e6)
        #expect(c.ambientOffsetMs == 0)
        // the queue stays at 10 ms although we send only 2 MB/s: after 1 s it is booked as ambient
        for _ in 0 ..< 12 {
            t += 100 * ms
            feed(&c, endNs: t, count: 6, queueMs: 10)
            c.tick(nowNs: t, sentBytes: sent(c, dtNs: 100 * ms))
        }
        #expect(c.ambientOffsetMs > 8 && c.ambientOffsetMs <= 10.5, "offset \(c.ambientOffsetMs)")
        // ... so the queue now reads (close to) zero and the rate may climb again after the 1 s hold-off
        t += 1_500 * ms
        feed(&c, endNs: t, count: 36, queueMs: 10)
        c.tick(nowNs: t, sentBytes: sent(c, dtNs: 1_500 * ms))
        #expect((c.queueMs ?? 99) < 2)
        #expect(c.rate > 2e6)
    }

    @Test func theAmbientOffsetIsCappedAndFadesOut() {
        var (c, t) = atTheFloor()
        for _ in 0 ..< 15 {   // a 60 ms ambient burst
            t += 100 * ms
            feed(&c, endNs: t, count: 6, queueMs: 60)
            c.tick(nowNs: t, sentBytes: sent(c, dtNs: 100 * ms))
        }
        #expect(c.ambientOffsetMs <= c.config.ambientCapMs + 0.01)
        let peak = c.ambientOffsetMs
        #expect(peak > 15)
        // the noise is gone: the offset halves every 8 s
        for _ in 0 ..< 80 {
            t += 100 * ms
            feed(&c, endNs: t, count: 6, queueMs: 0)
            c.tick(nowNs: t, sentBytes: sent(c, dtNs: 100 * ms))
        }
        #expect(c.ambientOffsetMs < peak * 0.55 && c.ambientOffsetMs > peak * 0.35, "after 8 s: \(c.ambientOffsetMs) of \(peak)")
    }

    @Test func noAmbientOffsetWhileTheRateIsAboveTheFloor() {
        var config = DelayRateController.Config()
        config.startRate = 20e6
        var c = calm(config)
        var t: UInt64 = 40_100_000_000
        feed(&c, endNs: t, count: 36, queueMs: 10)
        c.tick(nowNs: t, sentBytes: sent(c, dtNs: 100 * ms))   // cut to 14 MB/s: far above the floor
        for _ in 0 ..< 5 {
            t += 100 * ms
            feed(&c, endNs: t, count: 6, queueMs: 10)
            c.tick(nowNs: t, sentBytes: sent(c, dtNs: 100 * ms))
        }
        #expect(c.ambientOffsetMs == 0)   // a queue at a high rate may well be ours
    }

    // MARK: connection lifecycle

    @Test func restartForgetsTheIdleGapButKeepsTheRate() {
        var c = calm()
        var t: UInt64 = 40_000_000_000
        for _ in 0 ..< 10 {   // a second of slow start
            t += 100 * ms
            feed(&c, endNs: t, count: 6, queueMs: 0)
            c.tick(nowNs: t, sentBytes: sent(c, dtNs: 100 * ms))
        }
        let before = c.rate
        // 13 s pass with video only (the next OFF segment), then a new download: without `restart` the first tick would see dt = 13 s
        // and multiply the rate by 1.5^13.
        t += 13_000_000_000
        feed(&c, endNs: t, count: 60, queueMs: 0)
        c.restart()
        let r = c.tick(nowNs: t, sentBytes: 0)
        #expect(r == before)
        t += 100 * ms
        feed(&c, endNs: t, count: 6, queueMs: 0)
        c.tick(nowNs: t, sentBytes: sent(c, dtNs: 100 * ms))
        #expect(c.rate < before * 1.06)   // one 100 ms step of slow start, not a leap
    }

    @Test func resetTakesNewParametersAndKeepsTheDelaySamples() {
        var c = calm()
        feed(&c, endNs: 40_600_000_000, count: 36, queueMs: 10)
        c.tick(nowNs: 40_600_000_000, sentBytes: 0)
        let kept = c.sampleCount
        var config = DelayRateController.Config()
        config.highMs = 5; config.lowMs = 2; config.startRate = 3e6
        c.reset(config: config)
        #expect(c.rate == 3e6 && c.inSlowStart && c.config.highMs == 5)
        #expect(c.sampleCount == kept)
        // the samples still give a base: a 10 ms queue reads as 10 ms after the first tick re-arms the clock
        c.tick(nowNs: 40_700_000_000, sentBytes: 0)
        feed(&c, endNs: 41_300_000_000, count: 36, queueMs: 10)
        c.tick(nowNs: 41_300_000_000, sentBytes: 0)
        #expect(abs((c.queueMs ?? -1) - 10) < 0.01)
    }

    @Test func theSampleStoreStaysBoundedWhileNoFileIsSent() {
        var c = DelayRateController()
        var t: UInt64 = 1_000_000_000
        for _ in 0 ..< 600 {   // 10 minutes of video, no tick at all
            t += 1_000_000_000
            feed(&c, endNs: t, count: 60, queueMs: 0)
        }
        // 30 s of base window at 60 streams/s, plus one second of slack
        #expect(c.sampleCount <= 31 * 60)
        #expect(c.sampleCount >= 29 * 60)
    }

    // MARK: control law

    @Test func slowStartMultipliesWhileTheQueueIsLow() {
        var c = calm()
        let start = c.rate
        var t: UInt64 = 40_000_000_000
        for _ in 0 ..< 10 {   // 1 s in 100 ms ticks, the stream uses all of its rate
            t += 100 * ms
            feed(&c, endNs: t, count: 6, queueMs: 0)
            c.tick(nowNs: t, sentBytes: sent(c, dtNs: 100 * ms))
        }
        #expect(c.state == .slowStart)
        #expect(abs(c.rate / start - c.config.slowStartPerSecond) < 0.05)
    }

    @Test func slowStartEndsTheFirstTimeTheQueueReachesTheLowThreshold() {
        var c = calm()
        var t: UInt64 = 40_100_000_000
        feed(&c, endNs: t, count: 36, queueMs: 5)   // between low (3) and high (7)
        c.tick(nowNs: t, sentBytes: sent(c, dtNs: 100 * ms))
        #expect(c.state == .hold)
        #expect(!c.inSlowStart)
        let held = c.rate
        t += 600 * ms
        feed(&c, endNs: t, count: 36, queueMs: 0)
        c.tick(nowNs: t, sentBytes: sent(c, dtNs: 600 * ms))
        #expect(c.state == .increase)   // additive now, not multiplicative
        #expect(abs(c.rate - (held + c.config.increasePerSecond * 0.6)) < 1)
    }

    @Test func noIncreaseWhenTheStreamDoesNotUseItsRate() {
        var c = calm()
        let before = c.rate
        let t: UInt64 = 40_100_000_000
        feed(&c, endNs: t, count: 36, queueMs: 0)
        c.tick(nowNs: t, sentBytes: sent(c, dtNs: 100 * ms, utilisation: 0.5))
        #expect(c.rate == before)
        #expect(c.state == .hold)
    }

    @Test func aHighQueueCutsToSeventyPercentOfTheAchievedRate() {
        var config = DelayRateController.Config()
        config.startRate = 10e6   // well above the 2 MB/s floor, so the cut is not clamped
        var c = calm(config)
        let t: UInt64 = 40_100_000_000
        feed(&c, endNs: t, count: 36, queueMs: 12)
        c.tick(nowNs: t, sentBytes: sent(c, dtNs: 100 * ms))
        #expect(c.state == .decrease)
        #expect(abs(c.rate - 10e6 * c.config.decreaseFactor) < 1)
    }

    @Test func theCutStartsFromWhatTheLinkActuallyDelivered() {
        var config = DelayRateController.Config()
        config.startRate = 20e6
        var c = calm(config)
        let t: UInt64 = 40_100_000_000
        feed(&c, endNs: t, count: 36, queueMs: 12)
        // Limit 20 MB/s, but only 8 MB/s went through (the transport pushed back): cut from 8, not from 20.
        c.tick(nowNs: t, sentBytes: 800_000)
        #expect(abs(c.rate - 8e6 * 0.7) < 1)
    }

    @Test func severeAndCriticalQueuesCutHarder() {
        var config = DelayRateController.Config()
        config.startRate = 10e6
        var severe = calm(config)
        feed(&severe, endNs: 40_100_000_000, count: 36, queueMs: 60)
        severe.tick(nowNs: 40_100_000_000, sentBytes: sent(severe, dtNs: 100 * ms))
        #expect(severe.state == .severe)
        #expect(abs(severe.rate - 10e6 * severe.config.severeFactor) < 1)

        var critical = calm(config)
        feed(&critical, endNs: 40_100_000_000, count: 36, queueMs: 200)
        critical.tick(nowNs: 40_100_000_000, sentBytes: sent(critical, dtNs: 100 * ms))
        #expect(critical.state == .critical)
        #expect(abs(critical.rate - 10e6 * critical.config.criticalFactor) < 1)
    }

    @Test func cutsRespectTheCooldown() {
        var config = DelayRateController.Config()
        config.startRate = 10e6
        var c = calm(config)
        var t: UInt64 = 40_100_000_000
        feed(&c, endNs: t, count: 36, queueMs: 12)
        c.tick(nowNs: t, sentBytes: sent(c, dtNs: 100 * ms))
        let afterFirst = c.rate
        // Still a 12 ms queue at the next tick (100 ms later): no second cut inside the 400 ms cooldown.
        t += 100 * ms
        feed(&c, endNs: t, count: 6, queueMs: 12)
        c.tick(nowNs: t, sentBytes: sent(c, dtNs: 100 * ms))
        #expect(c.rate == afterFirst)
        // 400 ms after the first cut it may cut again.
        t += 300 * ms
        feed(&c, endNs: t, count: 18, queueMs: 12)
        c.tick(nowNs: t, sentBytes: sent(c, dtNs: 300 * ms))
        #expect(c.rate < afterFirst)
    }

    @Test func noCutWhileTheQueueIsAlreadyDraining() {
        var config = DelayRateController.Config()
        config.startRate = 10e6
        var c = calm(config)
        var t: UInt64 = 40_100_000_000
        feed(&c, endNs: t, count: 36, queueMs: 40)
        c.tick(nowNs: t, sentBytes: sent(c, dtNs: 100 * ms))   // cut
        let afterCut = c.rate
        // 500 ms later the queue is still above the high threshold (7 ms) but fell by more than `drainFallMs` (40 -> 15): hold.
        t += 500 * ms
        feed(&c, endNs: t, count: 36, queueMs: 15)
        c.tick(nowNs: t, sentBytes: sent(c, dtNs: 500 * ms))
        #expect(c.state == .hold)
        #expect(c.rate == afterCut)
    }

    @Test func noIncreaseRightAfterACut() {
        var c = calm()
        var t: UInt64 = 40_100_000_000
        feed(&c, endNs: t, count: 36, queueMs: 12)
        c.tick(nowNs: t, sentBytes: sent(c, dtNs: 100 * ms))
        let afterCut = c.rate
        t += 500 * ms   // 500 ms after the cut: the queue is gone, but the 1 s hold-off has not passed
        feed(&c, endNs: t, count: 36, queueMs: 0)
        c.tick(nowNs: t, sentBytes: sent(c, dtNs: 500 * ms))
        #expect(c.rate == afterCut)
        t += 600 * ms   // 1.1 s after the cut
        feed(&c, endNs: t, count: 36, queueMs: 0)
        c.tick(nowNs: t, sentBytes: sent(c, dtNs: 600 * ms))
        #expect(c.rate > afterCut)
    }

    /// Drives `ticks` ticks of 100 ms at a calm queue, every one using all of its rate, and returns (rate before, rate after) per tick.
    private func calmTicks(_ c: inout DelayRateController, from startNs: UInt64, ticks: Int) -> (end: UInt64, steps: [(before: Double, after: Double)]) {
        var t = startNs
        var steps: [(Double, Double)] = []
        for _ in 0 ..< ticks {
            t += 100 * ms
            feed(&c, endNs: t, count: 6, queueMs: 0)
            let before = c.rate
            c.tick(nowNs: t, sentBytes: sent(c, dtNs: 100 * ms))
            steps.append((before, c.rate))
        }
        return (t, steps)
    }

    /// Starts a controller at 10 MB/s, lets it cut once (knee = 10 MB/s, rate 7 MB/s) and returns it just after the cut, with the time.
    private func afterOneCut() -> (DelayRateController, UInt64) {
        var config = DelayRateController.Config()
        config.startRate = 10e6
        var c = calm(config)
        let t: UInt64 = 40_100_000_000
        feed(&c, endNs: t, count: 36, queueMs: 12)
        c.tick(nowNs: t, sentBytes: sent(c, dtNs: 100 * ms))
        return (c, t)
    }

    @Test func belowTheKneeTheRateClimbsFastAndNearItItOnlyProbes() {
        var (c, t) = afterOneCut()
        #expect(abs(c.rate - 7e6) < 1)   // knee 10 MB/s, rate cut to 70 %
        let warm = calmTicks(&c, from: t, ticks: 12)   // the 1 s hold-off after a cut, plus the first tick of the climb
        t = warm.end
        let climb = calmTicks(&c, from: t, ticks: 40).steps
        let fast = climb.filter { $0.before < 8.5e6 }.map { $0.after - $0.before }
        let slow = climb.filter { $0.before >= 8.5e6 }.map { $0.after - $0.before }
        #expect(!fast.isEmpty && !slow.isEmpty)
        for step in fast { #expect(abs(step - c.config.increasePerSecond * 0.1) < 1) }
        for step in slow { #expect(abs(step - c.config.probePerSecond * 0.1) < 1) }
    }

    @Test func theKneeIsForgottenAfterTenSecondsWithoutACut() {
        var (c, t) = afterOneCut()
        // 20 s of calm: fast to 8.5 MB/s, then probing; after 10 s from the cut the knee expires and the climb is fast again.
        let all = calmTicks(&c, from: t, ticks: 200)
        t = all.end
        let last = Array(all.steps.suffix(10))   // the final second, well past the expiry
        for step in last { #expect(abs(step.after - step.before - c.config.increasePerSecond * 0.1) < 1) }
        #expect(c.rate > 10e6)   // it went past the old knee
    }

    @Test func theBandBetweenTheThresholdsHolds() {
        var c = calm()
        c.tick(nowNs: 40_100_000_000, sentBytes: 0)   // consume the slow-start flag path
        let t: UInt64 = 40_700_000_000
        feed(&c, endNs: t, count: 36, queueMs: 5)
        let before = c.rate
        c.tick(nowNs: t, sentBytes: sent(c, dtNs: 600 * ms))
        #expect(c.rate == before)
        #expect(c.state == .hold)
    }

    @Test func theRateStaysInsideItsBounds() {
        var low = DelayRateController.Config()
        low.minRate = 0.5e6   // the test needs a floor the cuts can reach from a small start rate
        low.startRate = 0.6e6
        var c = calm(low)
        var t: UInt64 = 40_000_000_000
        for _ in 0 ..< 8 {   // cut over and over (a standing queue lasting ~30 s would become the calm level: the "latecomer" limit)
            t += 600 * ms
            feed(&c, endNs: t, count: 36, queueMs: 200)
            c.tick(nowNs: t, sentBytes: sent(c, dtNs: 600 * ms))
        }
        #expect(c.rate == low.minRate)

        var high = DelayRateController.Config()
        high.startRate = 39e6
        var d = calm(high)
        t = 40_000_000_000
        for _ in 0 ..< 40 {
            t += 600 * ms
            feed(&d, endNs: t, count: 36, queueMs: 0)
            d.tick(nowNs: t, sentBytes: sent(d, dtNs: 600 * ms))
        }
        #expect(d.rate == high.maxRate)
    }

    // MARK: simulation against a bottleneck

    private struct Trace { var rates: [(t: Double, rate: Double)] = []; var queues: [(t: Double, ms: Double)] = [] }

    /// Fluid model: the pump hands over `min(rate x dt, free buffer)` per frame, the link drains `capacity x dt`; queue = backlog / capacity.
    /// `jitterMs` = per-stream delay spread on top of the queue, uniform 0...12 ms: what the real Wi-Fi traces looked like with no download at all.
    private func simulate(config: DelayRateController.Config = .init(), seconds: Double, capacity: (Double) -> Double, jitterMs: Double = 12, ambientMs: (Double) -> Double = { _ in 0 }) -> Trace {
        var c = DelayRateController(config: config)
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func random() -> Double { state ^= state << 13; state ^= state >> 7; state ^= state << 17; return Double(state % 1_000_000) / 1_000_000 }
        let frame = 1.0 / 60.0, bufferCap = 1_048_576.0, tickEvery = 0.1
        var backlog = 0.0, t = 0.0, nextTick = tickEvery, handedOver = 0.0
        var rate = c.rate
        var trace = Trace()
        while t < seconds {
            let cap = capacity(t)
            let accepted = min(rate * frame, max(0, bufferCap - backlog))
            handedOver += accepted
            backlog = max(0, backlog + accepted - cap * frame)
            let q = backlog / cap
            trace.queues.append((t, q * 1000))
            let jitter = jitterMs * random() * 1e6
            c.addSample(sendNs: UInt64(t * 1e9) + offset, arrivalNs: UInt64(t * 1e9 + 5e6 + q * 1e9 + jitter + ambientMs(t) * 1e6) + offset)
            t += frame
            if t >= nextTick {
                rate = c.tick(nowNs: UInt64(t * 1e9) + offset, sentBytes: Int(handedOver))
                handedOver = 0
                trace.rates.append((t, rate))
                nextTick += tickEvery
            }
        }
        return trace
    }

    private func mean(_ trace: Trace, from: Double, to: Double) -> Double {
        let v = trace.rates.filter { $0.t >= from && $0.t < to }.map(\.rate)
        return v.reduce(0, +) / Double(max(1, v.count))
    }

    private func quantile(_ trace: Trace, from: Double, to: Double, _ p: Double) -> Double {
        let v = trace.queues.filter { $0.t >= from && $0.t < to }.map(\.ms).sorted()
        return v.isEmpty ? 0 : v[min(v.count - 1, Int(p * Double(v.count)))]
    }

    @Test func findsTheKneeOfASteadyLinkAndKeepsTheQueueShort() {
        let trace = simulate(seconds: 90, capacity: { _ in 10e6 })
        let rate = mean(trace, from: 30, to: 90)
        #expect(rate > 6e6 && rate < 10.5e6, "mean rate \(rate / 1e6) MB/s")
        #expect(quantile(trace, from: 30, to: 90, 0.95) < 10)
        #expect(quantile(trace, from: 30, to: 90, 1.0) < 25)
    }

    @Test func followsACapacityDropDown() {
        let trace = simulate(seconds: 90, capacity: { $0 < 40 ? 12e6 : 4e6 })
        // The first seconds after the drop are a burst of queue (the 1 MiB buffer fills); it must be over within ~2 s. Afterwards the
        // fast climb back to the knee may peak a little (simulation: ~19-23 ms), never more.
        let late = trace.queues.filter { $0.t >= 42.5 && $0.ms > 30 }
        #expect(late.isEmpty, "queue still above 30 ms after 42.5 s")
        // ... and the rate settles just under the new capacity.
        let rate = mean(trace, from: 50, to: 90)
        #expect(rate > 2e6 && rate < 4.4e6, "settled rate \(rate / 1e6) MB/s")
        #expect(quantile(trace, from: 50, to: 90, 0.95) < 15)
    }

    @Test func followsACapacityRiseUp() {
        let trace = simulate(seconds: 100, capacity: { $0 < 40 ? 4e6 : 12e6 })
        let rate = mean(trace, from: 70, to: 100)
        #expect(rate > 7e6, "rate \(rate / 1e6) MB/s 30 s after the rise")
        #expect(quantile(trace, from: 70, to: 100, 0.95) < 10)
    }

    @Test func anAmbientBurstPinsTheRateAtTheFloorAndItRecoversAfterwards() {
        // A steady 10 MB/s link; between 30 s and 60 s +30 ms of delay that has nothing to do with the file stream (shared Wi-Fi).
        let trace = simulate(seconds: 100, capacity: { _ in 10e6 }, ambientMs: { $0 >= 30 && $0 < 60 ? 30 : 0 })
        #expect(mean(trace, from: 30, to: 90) > 0)
        let during = mean(trace, from: 36, to: 58)
        #expect(during <= 2.5e6, "during the burst: \(during / 1e6) MB/s")   // the floor, not a collapse below it, not a climb through the noise
        let after = mean(trace, from: 78, to: 100)
        #expect(after > 6e6, "after the burst: \(after / 1e6) MB/s")
    }

    @Test func aSilentVideoDoesNotMoveTheRateInTheSimulation() {
        var c = DelayRateController()
        var t: UInt64 = 1_000_000_000
        c.tick(nowNs: t, sentBytes: 0)
        for _ in 0 ..< 50 {   // 5 s of ticks, no samples at all
            t += 100 * ms
            c.tick(nowNs: t, sentBytes: sent(c, dtNs: 100 * ms))
        }
        #expect(c.rate == c.config.startRate)
    }
}
