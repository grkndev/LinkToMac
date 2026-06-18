import { NativeModule, requireNativeModule } from 'expo';

import type { ClipEvent, RelayEvent, SelfAdbModuleEvents } from './SelfAdb.types';

/** Boot state returned by autoStart(): drives the JS gate. */
export type AutoStartState = 'ready' | 'need-pair' | 'need-connect';

declare class SelfAdbModule extends NativeModule<SelfAdbModuleEvents> {
  /** spake2 pair with the device's own adbd (Android 11+ wireless debugging). */
  pair(host: string, port: number, code: string): Promise<string>;
  /** TLS connect using the stored key. Find host/port via Wireless Debugging settings (or mDNS later). */
  connect(host: string, port: number): Promise<string>;
  /** push the bundled clipboard-agent.dex, launch it via app_process, then open the localhost clip socket. */
  deployAndRun(clipPort: number): Promise<string>;
  /**
   * Drive the whole boot in one call (no manual host/port). Probes the daemon;
   * if dead and paired, self-enables wireless debugging + mDNS-connects + deploys.
   * Returns "ready" | "need-pair" | "need-connect".
   */
  autoStart(clipPort: number): Promise<AutoStartState>;
  /**
   * First-time pairing, fully discovered via mDNS. The system "Pair device with
   * pairing code" dialog must be open. Pairs with `code`, self-grants
   * WRITE_SECURE_SETTINGS, then connects + deploys. Resolves "ready".
   */
  pairAuto(code: string, clipPort: number): Promise<'ready'>;
  /** true once we hold WRITE_SECURE_SETTINGS (can self-toggle wireless debugging). */
  hasSecureSettings(): Promise<boolean>;
  /** deep-link to Developer options so the user can open the pairing dialog. */
  openWirelessDebuggingSettings(): Promise<void>;
  /** send text down to the shell process to set the system clipboard. */
  writeClipboard(text: string): Promise<void>;
  /** adb-free liveness probe of the on-device clipboard daemon (localhost socket). */
  isDaemonAlive(): Promise<boolean>;
  /**
   * persist connection config and (re)connect the native link to the Mac. `key` is the 32-byte
   * pairing secret (base64) used by the E2E ClipCodec. `url` may be empty for LAN-only. The LAN
   * params drive the relay-less path: `lanEnabled` + `lanPort` (0 = LAN off) and an optional
   * `lanHost` manual seed (the Mac is otherwise found over mDNS).
   */
  setRelay(
    url: string,
    token: string,
    room: string,
    key: string,
    peerName: string | null,
    lanEnabled: boolean,
    lanPort: number,
    lanHost: string | null,
  ): Promise<void>;
  /** send a remote action to the Mac over the relay (e.g. "lock"). Needs the service running. */
  sendCommand(action: string): Promise<void>;
  /** enable/disable the BLE presence beacon (Mac auto-locks when this phone leaves). Persisted. */
  setProximityAdvertise(enabled: boolean): Promise<void>;
  /** whether the presence beacon is enabled (persisted, default false). */
  getProximityAdvertise(): Promise<boolean>;
  /** whether we hold the Nearby Devices (BLUETOOTH_ADVERTISE) permission. */
  hasNearbyDevicesPermission(): Promise<boolean>;
  /** request the Nearby Devices permission (Android 12+); resolves whether granted. */
  requestNearbyDevicesPermission(): Promise<boolean>;
  /** unpair: forget the persisted relay config and disconnect the native WS. */
  clearRelay(): Promise<void>;
  /** current relay state, retained natively (the service may have connected before the app). */
  relayGetStatus(): Promise<RelayEvent>;
  /** pause/resume outbound (Mac-bound) forwarding; stays connected to receive. Persisted. */
  relaySetPaused(paused: boolean): Promise<void>;
  /** whether outbound forwarding to the Mac is currently paused (persisted, default false). */
  relayIsSendPaused(): Promise<boolean>;
  /** hide/show the FGS notification's status-bar icon (re-posts on a MIN/LOW importance channel). */
  setStatusNotificationVisible(visible: boolean): Promise<void>;
  /** whether the status-bar icon is currently shown (persisted, default true). */
  getStatusNotificationVisible(): Promise<boolean>;
  /** whether the FGS notification can be shown (POST_NOTIFICATIONS, Android 13+). */
  hasPostNotifications(): Promise<boolean>;
  /** request POST_NOTIFICATIONS; re-posts the service notification once granted. */
  requestPostNotifications(): Promise<boolean>;
  /** whether the app is exempt from battery optimizations (more resilient FGS). */
  hasIgnoreBatteryOptimizations(): Promise<boolean>;
  /** open the system dialog to request battery-optimization exemption. */
  requestIgnoreBatteryOptimizations(): Promise<void>;
  /** true if a pairing key already exists on disk. */
  isPaired(): Promise<boolean>;
  /** retained history of clips received FROM the Mac (newest-first), across the JS-runtime gap. */
  getClipHistory(): Promise<ClipEvent[]>;
  /** clear the retained Mac-clip history buffer. */
  clearClipHistory(): Promise<void>;
  /** snapshot of the in-app log ring buffer (oldest first), retained across the JS gap. */
  getLogs(): Promise<string[]>;
  /** clear the in-app log ring buffer. */
  clearLogs(): Promise<void>;
  /**
   * fetch the privileged daemon's own on-device log + a liveness/socket probe.
   * (Re)connects adb over mDNS, self-enabling wireless debugging if permitted.
   */
  readDaemonLog(): Promise<string>;
  /** kill the detached daemon (requires adb connected). */
  killDaemon(): Promise<string>;
  /** detach the bridge but LEAVE the daemon running (survives app death). */
  stop(): Promise<void>;
}

export default requireNativeModule<SelfAdbModule>('SelfAdb');
