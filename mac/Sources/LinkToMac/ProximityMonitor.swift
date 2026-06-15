import CoreBluetooth
import Foundation
import Observation

/// Locks the Mac when the paired phone leaves BLE range ("leaves the room").
///
/// The Mac is the BLE *central*: it scans for the phone's presence beacon (a service UUID
/// derived from the pairing room — see `ProximityConfig`), tracks last-seen + smoothed RSSI,
/// and once the phone has been gone for `awayGraceSeconds` it calls `ScreenLock.lock()`.
/// This is fully local — no relay/internet — so it *fails secure*: if the phone vanishes, we lock.
///
/// `@MainActor` so all observable state mutates on the main thread; `CBCentralManagerDelegate`
/// callbacks are `nonisolated` and hop back here with only `Sendable` values (scan is already
/// filtered to our UUID, so we never touch the non-Sendable peripheral).
@MainActor
@Observable
final class ProximityMonitor: NSObject {
    enum Presence: Equatable {
        case disabled        // feature off
        case bluetoothOff    // BT powered off
        case unauthorized    // Bluetooth permission denied
        case unseen          // scanning, phone not seen yet
        case near            // phone present
        case away            // armed and the phone has left
    }

    /// How close the phone must be to count as "in the room" → the RSSI cutoff. Calibrated on
    /// real hardware: same table ≈ −65/−68 dBm, far in-room corner ≈ −75, adjacent room with the
    /// door closed ≈ −77/−80.
    enum Sensitivity: String, CaseIterable, Identifiable {
        case near, balanced, far
        var id: String { rawValue }
        var thresholdRSSI: Int {
            switch self {
            case .near: return -68      // leaving the desk/table area locks
            case .balanced: return -76  // leaving the room locks
            case .far: return -83       // only well outside locks
            }
        }
        var label: String {
            switch self {
            case .near: return "Near"
            case .balanced: return "Balanced"
            case .far: return "Far"
            }
        }
    }

    private(set) var presence: Presence = .disabled

    /// User opt-in. Persisted, mirroring `RelayClient.sendToAndroid`. Toggling drives scanning.
    var enabled: Bool = UserDefaults.standard.bool(forKey: ProximityMonitor.enabledKey) {
        didSet {
            UserDefaults.standard.set(enabled, forKey: ProximityMonitor.enabledKey)
            if enabled { startScanning() } else { stopScanning() }
        }
    }

    /// Distance sensitivity → the RSSI cutoff for "present". Persisted; changing it re-checks now.
    var sensitivity: Sensitivity = ProximityMonitor.loadSensitivity() {
        didSet {
            UserDefaults.standard.set(sensitivity.rawValue, forKey: ProximityMonitor.sensitivityKey)
            evaluate()
        }
    }

    /// Seconds the phone must stay not-present before locking. Persisted; floored at `minGrace`.
    var graceSeconds: Int = ProximityMonitor.loadGrace() {
        didSet { UserDefaults.standard.set(graceSeconds, forKey: ProximityMonitor.graceKey) }
    }

    private static let enabledKey = "proximityLockEnabled"
    private static let sensitivityKey = "proximitySensitivity"
    private static let graceKey = "proximityGraceSeconds"

    /// Selectable away-grace durations (seconds). 10s is the floor: below it RSSI noise and the
    /// 2.5s eval cadence make false locks likely.
    static let graceOptions = [10, 20, 30, 60]
    static let minGrace = 10
    private static let defaultGrace = 20

    static func loadSensitivity() -> Sensitivity {
        Sensitivity(rawValue: UserDefaults.standard.string(forKey: sensitivityKey) ?? "") ?? .balanced
    }

    static func loadGrace() -> Int {
        let v = UserDefaults.standard.integer(forKey: graceKey)
        return v == 0 ? defaultGrace : max(minGrace, v)
    }

    private var central: CBCentralManager?
    private var serviceUUID: CBUUID?
    /// Last time the phone read at/above `presentRSSI` — i.e. last time it was "in the room".
    /// The lock fires on *this* aging out, so going weak (another room) counts, not just signal loss.
    private var lastStrong: Date?
    private var smoothedRSSI: Double?
    /// We only lock if we've previously seen the phone *near* — so leaving is a real departure.
    private var armed = false
    private var evalTimer: Timer?

    override init() {
        super.init()
        loadServiceUUID()
        if enabled { startScanning() }
    }

    /// Re-derive the beacon UUID after an unpair (the room — and thus the UUID — rotates).
    func reloadPairing() {
        loadServiceUUID()
        if enabled { beginScan() }
    }

    private func loadServiceUUID() {
        if let room = PairingStore.load()?.room {
            serviceUUID = CBUUID(nsuuid: ProximityConfig.serviceUUID(room: room))
        } else {
            serviceUUID = nil
        }
    }

    // MARK: - Scan lifecycle

    private func startScanning() {
        guard enabled else { return }
        startEvalTimer()
        if central == nil {
            // First creation prompts for Bluetooth permission; the scan starts in
            // `centralManagerDidUpdateState(.poweredOn)`.
            central = CBCentralManager(delegate: self, queue: nil)
            return
        }
        applyState(central!.state)
    }

    private func stopScanning() {
        evalTimer?.invalidate()
        evalTimer = nil
        central?.stopScan()
        armed = false
        lastStrong = nil
        smoothedRSSI = nil
        presence = .disabled
    }

    private func beginScan() {
        guard enabled, let central, central.state == .poweredOn, let serviceUUID else { return }
        central.stopScan()
        lastStrong = nil
        smoothedRSSI = nil
        armed = false
        presence = .unseen
        central.scanForPeripherals(
            withServices: [serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true],
        )
    }

    private func startEvalTimer() {
        evalTimer?.invalidate()
        evalTimer = Timer.scheduledTimer(withTimeInterval: ProximityConfig.evalInterval, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
    }

    // MARK: - State machine

    private func applyState(_ state: CBManagerState) {
        switch state {
        case .poweredOn: beginScan()
        case .poweredOff: presence = .bluetoothOff
        case .unauthorized: presence = .unauthorized
        default: presence = enabled ? .unseen : .disabled
        }
    }

    private func recordSighting(rssi: Int) {
        let v = Double(rssi)
        let s = smoothedRSSI.map { $0 + ProximityConfig.rssiAlpha * (v - $0) } ?? v
        smoothedRSSI = s
        // "In the room" = a strong-enough reading. Refreshing presence on *strength* (not merely
        // on receiving a packet) is what makes walking to another room — still faintly in range,
        // but weak — count as leaving. Seeing the phone strong also arms a future lock.
        if s >= Double(sensitivity.thresholdRSSI) {
            lastStrong = Date()
            armed = true
        }
        evaluate()
    }

    private func evaluate() {
        guard enabled, let central, central.state == .poweredOn else { return }

        // Not yet armed: never seen the phone strong enough to consider it "here", so there's
        // nothing to lock on. Just reflect whether we're hearing anything at all.
        guard armed, let lastStrong else {
            presence = (smoothedRSSI == nil) ? .unseen : .away
            return
        }

        // Lock once the phone hasn't been "in the room" (strong) for the whole grace window —
        // covers both going fully out of range and just getting weak (another room).
        if Date().timeIntervalSince(lastStrong) > Double(graceSeconds) {
            presence = .away
            armed = false
            ScreenLock.lock()
            return
        }

        let strongNow = (smoothedRSSI ?? -200) >= Double(sensitivity.thresholdRSSI)
        presence = strongNow ? .near : .away
    }
}

// MARK: - CBCentralManagerDelegate (nonisolated; hops to the main actor with Sendable values)

extension ProximityMonitor: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Task { @MainActor in self.applyState(state) }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber,
    ) {
        let rssi = RSSI.intValue
        Task { @MainActor in self.recordSighting(rssi: rssi) }
    }
}

// MARK: - UI-facing status

extension ProximityMonitor {
    var statusText: String {
        switch presence {
        case .disabled: return "Off"
        case .bluetoothOff: return "Bluetooth off"
        case .unauthorized: return "Allow Bluetooth in Settings"
        case .unseen: return "Looking for phone…"
        case .near: return "Nearby\(rssiSuffix)"
        case .away: return "Away\(rssiSuffix)"
        }
    }

    /// Live smoothed signal, e.g. " (−68 dBm)" — handy for calibrating `presentRSSI`.
    private var rssiSuffix: String {
        guard let smoothedRSSI else { return "" }
        return " (\(Int(smoothedRSSI.rounded())) dBm)"
    }
}
