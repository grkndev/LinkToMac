import Foundation

/// Delay-driven rate controller for the Mac -> phone file stream while a phone -> Mac video stream is live
/// (stage 0.7 / plan Faz 6.1, docs/plans/2026-11-14-quic-data-plane.md and the "Tanı" findings 36-51 in the Faz 0 results).
///
/// WHY it exists: a fixed limiter (or "x % of the bandwidth measured earlier") is not a safe design parameter, because the capacity
/// of the shared Wi-Fi moves (10-28 MB/s over a day, and the same fixed rate cost +6 ms in one run and +48 ms in the next). What does
/// track the capacity is the queueing delay the file stream puts on the path, and the Mac can see it without any clock
/// synchronisation: for every video stream it receives, `d = Mac arrival - phone send stamp` (an unknown constant clock offset
/// included).
///
/// THE SIGNAL (designed against real traces, with spikes/quic/qos-signal-calibrate.py, kept in the git tag `archive/quic-faz0`): the delay of a single stream is noisy on Wi-Fi
/// (its p75 sits ~7 ms above the smallest value even with NO download, so "p75 - min" read the ambient jitter as congestion and held the
/// rate at the floor). What moves with a queue is the whole distribution, so the signal is the MEDIAN of the last `signalWindowNs` (0.6 s),
/// and the reference is the calm level of that same statistic: the `basePercentile` (p10) of the windowed medians seen over the last
/// `baseWindowNs` (30 s). `q = median_now - calm`. Measured: OFF (no download) q is p50 0.8 / p90 2.6 ms; the segments the video really
/// suffered in sit at q ~ 6, the good ones at ~ 2.
///
/// THE LAW, at every tick (the caller's timer, 100 ms):
///   - cut the rate multiplicatively when `q` is above `highMs` (x0.7), `severeMs` (x0.5) or `criticalMs` (x0.35), at most once per
///     `decreaseCooldownNs`, and not while the queue is already draining (it fell by >= `drainFallMs` since the previous tick within
///     `drainWindowNs` of the last cut: after a cut the queue empties slowly, and cutting again meanwhile only undershoots the capacity);
///   - raise it when `q` is below `lowMs`, the file stream actually used the rate (>= `minUtilisation`), and the last cut is
///     older than `increaseHoldoffNs`: x`slowStartPerSecond` per second until the first time `q` reaches `lowMs`, then additive,
///     `increasePerSecond` bytes/s per second, except near the "knee": the rate at which the last cut happened is remembered, and
///     from `kneeFraction` of it upwards the rate only probes at `probePerSecond` (a fast climb straight back into the knee is what made
///     the queue peak every few seconds); the knee is forgotten after `kneeExpiryNs` without a cut, so a capacity that grew is found again;
///   - hold in between (hysteresis) and whenever there is no usable signal (video paused: fewer than `minSamples` in the window or the
///     newest one older than `staleNs`).
/// A cut starts from `min(rate, achieved)`: when the limit sits far above what the link delivers, cutting the limit alone changes nothing.
///
/// THE FLOOR and ambient noise (tuning round after the first phone comparison, Faz 0 results findings 59-60): the rate never goes below
/// `minRate` (2 MB/s: a 1 GiB file in ~8.5 min, a product policy, not a measurement), and when the rate IS at the floor and the queue still
/// reads high for `ambientAfterSeconds`, the queue is not ours (2 MB/s cannot build one): it is the shared Wi-Fi. The current excess is then
/// taken as an `ambientOffsetMs` (capped at `ambientCapMs`, halving every `ambientHalfLifeSeconds`) that is subtracted from `q`, so ambient
/// bursts stop pinning the rate at the floor while our own queue above that offset still counts.
///
/// Pure Foundation, no Network/Dispatch: the caller feeds `addSample` from its video receive path and calls `tick` from a timer, so
/// the whole behaviour is unit-tested (including against a simulated bottleneck) without a network.
struct DelayRateController {
    struct Config: Equatable {
        var minRate = 2e6                      // bytes/s: the floor (product policy)
        var maxRate = 40e6
        var startRate = 2e6
        var highMs = 7.0
        var lowMs = 3.0
        var severeMs = 40.0
        var criticalMs = 100.0
        var decreaseFactor = 0.7
        var severeFactor = 0.5
        var criticalFactor = 0.35
        var slowStartPerSecond = 1.5           // rate multiplier per second while in slow start
        var increasePerSecond = 1e6            // bytes/s gained per second (additive phase)
        var probePerSecond = 0.3e6             // ... while near the remembered knee
        var kneeFraction = 0.85
        var kneeExpiryNs: UInt64 = 10_000_000_000
        var quantile = 0.5                     // the statistic of the delay window (median)
        var basePercentile = 0.10              // the calm level = this percentile of that statistic over `baseWindowNs`
        var signalWindowNs: UInt64 = 600_000_000
        var baseWindowNs: UInt64 = 30_000_000_000
        var minSamples = 12
        var staleNs: UInt64 = 2_000_000_000
        var decreaseCooldownNs: UInt64 = 400_000_000
        var drainWindowNs: UInt64 = 2_000_000_000
        var drainFallMs = 1.0                  // the queue fell by at least this much since the previous tick = draining
        var increaseHoldoffNs: UInt64 = 1_000_000_000
        var minUtilisation = 0.7
        var ambientAfterSeconds = 1.0          // at the floor with a high queue for this long = ambient
        var ambientCapMs = 20.0
        var ambientHalfLifeSeconds = 8.0
    }

    enum State: String { case noSignal, slowStart, increase, hold, decrease, severe, critical }

    private(set) var config: Config
    private(set) var rate: Double
    private(set) var state: State = .noSignal
    /// The queue estimate the last tick acted on, in milliseconds (nil when there was no usable signal).
    private(set) var queueMs: Double?
    private(set) var inSlowStart = true
    private var samples: [(arrivalNs: UInt64, d: Int64)] = []
    /// The window statistic (ms) as it stood at each sample: the history the calm level is taken from.
    private var levels: [(arrivalNs: UInt64, level: Double)] = []
    private var lastTickNs: UInt64?
    private var lastDecreaseNs: UInt64?
    private var previousQueueMs: Double?
    /// The rate the last cut started from (where the queue built) and when it was set.
    private var kneeRate: Double?
    /// Excess delay attributed to the shared Wi-Fi rather than to us (see "THE FLOOR" above) and how long it has been building.
    private(set) var ambientOffsetMs = 0.0
    private var ambientStreakSeconds = 0.0

    init(config: Config = Config()) {
        self.config = config
        rate = min(max(config.startRate, config.minRate), config.maxRate)
    }

    /// One finished (or first-byte) video stream: the phone's stamp and the Mac's arrival time. Clocks may differ by any constant.
    /// Samples keep arriving while no file is being sent (that is what keeps the calm level fresh) and are trimmed here, so the store
    /// never holds more than `baseWindowNs` of them however long the video runs without a download.
    mutating func addSample(sendNs: UInt64, arrivalNs: UInt64) {
        samples.append((arrivalNs, Int64(bitPattern: arrivalNs &- sendNs)))
        if arrivalNs > config.baseWindowNs {
            let cutoff = arrivalNs - config.baseWindowNs
            if let first = samples.firstIndex(where: { $0.arrivalNs >= cutoff }), first > 0 { samples.removeFirst(first) }
            if let first = levels.firstIndex(where: { $0.arrivalNs >= cutoff }) {
                if first > 0 { levels.removeFirst(first) }
            } else {
                levels.removeAll()
            }
        }
        if let level = windowStatistic(endingAt: arrivalNs) { levels.append((arrivalNs, level)) }
    }

    /// Number of delay samples currently kept (for tests and diagnostics).
    var sampleCount: Int { samples.count }

    /// A new download starts on this connection: forget the tick clock (so the idle gap since the last download is not mistaken for
    /// one control interval) but keep the rate, the slow-start flag and the delay history.
    mutating func restart() {
        lastTickNs = nil
        previousQueueMs = nil
    }

    /// New parameters (they arrive with the download command): the rate goes back to `config.startRate` and slow start is armed
    /// again; the delay samples are path measurements, not controller state, so they are kept (the window statistic is recomputed
    /// over them in case the window or the quantile changed).
    mutating func reset(config: Config) {
        self.config = config
        rate = min(max(config.startRate, config.minRate), config.maxRate)
        state = .noSignal
        queueMs = nil
        inSlowStart = true
        lastDecreaseNs = nil
        kneeRate = nil
        ambientOffsetMs = 0
        ambientStreakSeconds = 0
        restart()
        levels.removeAll()
        let kept = samples
        samples.removeAll()
        for sample in kept {
            samples.append(sample)
            if let level = windowStatistic(endingAt: sample.arrivalNs) { levels.append((sample.arrivalNs, level)) }
        }
    }

    /// The configured quantile (ms) of the delays of the last `signalWindowNs` ending at `endNs`; nil with fewer than `minSamples`.
    private func windowStatistic(endingAt endNs: UInt64) -> Double? {
        let start = endNs > config.signalWindowNs ? endNs - config.signalWindowNs : 0
        var window: [Int64] = []
        var i = samples.count
        while i > 0, samples[i - 1].arrivalNs >= start {
            if samples[i - 1].arrivalNs <= endNs { window.append(samples[i - 1].d) }
            i -= 1
        }
        guard window.count >= config.minSamples else { return nil }
        window.sort()
        return Double(window[min(window.count - 1, Int(Double(window.count) * config.quantile))]) / 1e6
    }

    /// `sentBytes` = bytes the file stream handed to the transport since the previous tick. Returns the rate to use from now on.
    @discardableResult
    mutating func tick(nowNs: UInt64, sentBytes: Int) -> Double {
        defer { lastTickNs = nowNs }
        guard let last = lastTickNs, nowNs > last else { return rate }
        let dt = Double(nowNs - last) / 1e9
        let achieved = Double(sentBytes) / dt

        let newest = samples.last { $0.arrivalNs <= nowNs }?.arrivalNs
        guard let newest, nowNs - newest <= config.staleNs, let level = windowStatistic(endingAt: nowNs) else {
            state = .noSignal
            queueMs = nil
            previousQueueMs = nil
            return rate
        }
        let calmCutoff = nowNs > config.baseWindowNs ? nowNs - config.baseWindowNs : 0
        let history = levels.filter { $0.arrivalNs >= calmCutoff }.map(\.level).sorted()
        let calm = history.isEmpty ? level : history[min(history.count - 1, Int(Double(history.count) * config.basePercentile))]
        let qRaw = max(0, level - calm)
        ambientOffsetMs *= pow(0.5, dt / config.ambientHalfLifeSeconds)
        if rate <= config.minRate * 1.05, qRaw - ambientOffsetMs > config.highMs {
            ambientStreakSeconds += dt
            if ambientStreakSeconds >= config.ambientAfterSeconds {
                ambientOffsetMs = min(config.ambientCapMs, qRaw)
                ambientStreakSeconds = 0
            }
        } else {
            ambientStreakSeconds = 0
        }
        let q = max(0, qRaw - ambientOffsetMs)
        queueMs = q
        if q >= config.lowMs { inSlowStart = false }

        let sinceDecrease = lastDecreaseNs.map { nowNs - $0 } ?? UInt64.max
        let utilisation = rate > 0 ? achieved / rate : 0
        let draining = sinceDecrease < config.drainWindowNs && (previousQueueMs.map { q < $0 - config.drainFallMs } ?? false)
        if kneeRate != nil, sinceDecrease > config.kneeExpiryNs { kneeRate = nil }
        defer { previousQueueMs = q }
        if q > config.criticalMs, sinceDecrease >= config.decreaseCooldownNs, !draining {
            kneeRate = min(rate, achieved)
            rate = kneeRate! * config.criticalFactor
            lastDecreaseNs = nowNs
            inSlowStart = false
            state = .critical
        } else if q > config.severeMs, sinceDecrease >= config.decreaseCooldownNs, !draining {
            kneeRate = min(rate, achieved)
            rate = kneeRate! * config.severeFactor
            lastDecreaseNs = nowNs
            inSlowStart = false
            state = .severe
        } else if q > config.highMs, sinceDecrease >= config.decreaseCooldownNs, !draining {
            kneeRate = min(rate, achieved)
            rate = kneeRate! * config.decreaseFactor
            lastDecreaseNs = nowNs
            inSlowStart = false
            state = .decrease
        } else if q < config.lowMs, sinceDecrease >= config.increaseHoldoffNs, utilisation >= config.minUtilisation {
            if inSlowStart {
                rate *= pow(config.slowStartPerSecond, dt)
                state = .slowStart
            } else {
                let nearKnee = kneeRate.map { rate >= $0 * config.kneeFraction } ?? false
                rate += (nearKnee ? config.probePerSecond : config.increasePerSecond) * dt
                state = .increase
            }
        } else {
            state = .hold
        }
        rate = min(max(rate, config.minRate), config.maxRate)
        return rate
    }
}
