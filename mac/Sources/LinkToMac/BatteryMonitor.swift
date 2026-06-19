import Foundation
import IOKit.ps

/// Polls the Mac's internal battery via IOKit power sources and reports charge percent +
/// charging state to the peer. The analogue of `PasteboardWatcher` for telemetry: same
/// poll-and-diff shape, but the source is the battery rather than the pasteboard.
///
/// Desktop Macs (Mac mini/Studio/Pro) have no internal battery, so `read()` returns nil and
/// nothing is ever sent — the phone simply shows no battery chip.
@MainActor
final class BatteryMonitor {
    private var pollTask: Task<Void, Never>?
    private let onChange: (String) -> Void
    /// Last payload sent, so a poll only fires `onChange` when level or charging actually changed.
    private var last: String?

    /// Battery moves slowly; a minute is plenty. Prompt updates on (re)connect are handled by
    /// the owner pushing `currentPayload()` when a peer comes online.
    private static let interval: Duration = .seconds(60)

    init(onChange: @escaping (String) -> Void) {
        self.onChange = onChange
    }

    func start() {
        stop()
        last = nil
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: BatteryMonitor.interval)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Current battery as the wire payload, or nil if this Mac has no internal battery.
    /// Used to push a fresh value the moment a peer connects (don't wait for the next poll).
    func currentPayload() -> String? {
        read().map(payload)
    }

    private func poll() {
        guard let state = read() else { return } // desktop Mac: nothing to report
        let p = payload(state)
        guard p != last else { return }
        last = p
        onChange(p)
    }

    /// Plaintext wire payload. Wire-compatible with the phone's `JSON.parse`: `{"level":85,"charging":true}`.
    private func payload(_ state: (level: Int, charging: Bool)) -> String {
        "{\"level\":\(state.level),\"charging\":\(state.charging)}"
    }

    /// Read the internal battery's charge percent (0–100) + charging flag. nil when there is no
    /// internal battery (desktop Macs) or the power-source info is unavailable.
    private func read() -> (level: Int, charging: Bool)? {
        guard
            let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard
                let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue()
                    as? [String: Any],
                desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                let current = desc[kIOPSCurrentCapacityKey] as? Int,
                let maxCap = desc[kIOPSMaxCapacityKey] as? Int, maxCap > 0
            else { continue }
            let level = min(max(Int((Double(current) / Double(maxCap) * 100).rounded()), 0), 100)
            let charging = (desc[kIOPSIsChargingKey] as? Bool)
                ?? ((desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue)
            return (level, charging)
        }
        return nil
    }
}
