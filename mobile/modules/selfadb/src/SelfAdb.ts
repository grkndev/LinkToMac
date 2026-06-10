import { NativeModule, requireNativeModule } from 'expo';

import type { RelayEvent, SelfAdbModuleEvents } from './SelfAdb.types';

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
  /** persist relay config (url/token/room/peer name) and (re)connect the native WS to the Mac. */
  setRelay(url: string, token: string, room: string, peerName: string | null): Promise<void>;
  /** unpair: forget the persisted relay config and disconnect the native WS. */
  clearRelay(): Promise<void>;
  /** current relay state, retained natively (the service may have connected before the app). */
  relayGetStatus(): Promise<RelayEvent>;
  /** live pause/resume of relay forwarding (does not touch persisted config). */
  relaySetPaused(paused: boolean): Promise<void>;
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
  /** kill the detached daemon (requires adb connected). */
  killDaemon(): Promise<string>;
  /** detach the bridge but LEAVE the daemon running (survives app death). */
  stop(): Promise<void>;
}

export default requireNativeModule<SelfAdbModule>('SelfAdb');
