import { NativeModule, requireNativeModule } from 'expo';

import type { SelfAdbModuleEvents } from './SelfAdb.types';

declare class SelfAdbModule extends NativeModule<SelfAdbModuleEvents> {
  /** spake2 pair with the device's own adbd (Android 11+ wireless debugging). */
  pair(host: string, port: number, code: string): Promise<string>;
  /** TLS connect using the stored key. Find host/port via Wireless Debugging settings (or mDNS later). */
  connect(host: string, port: number): Promise<string>;
  /** push the bundled clipboard-agent.dex, launch it via app_process, then open the localhost clip socket. */
  deployAndRun(clipPort: number): Promise<string>;
  /** send text down to the shell process to set the system clipboard. */
  writeClipboard(text: string): Promise<void>;
  /** true if a pairing key already exists on disk. */
  isPaired(): Promise<boolean>;
  /** kill the detached daemon (requires adb connected). */
  killDaemon(): Promise<string>;
  /** detach the bridge but LEAVE the daemon running (survives app death). */
  stop(): Promise<void>;
}

export default requireNativeModule<SelfAdbModule>('SelfAdb');
