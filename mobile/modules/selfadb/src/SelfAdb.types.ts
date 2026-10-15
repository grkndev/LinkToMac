export type ClipEvent = {
  /** clipboard text captured on the device */
  text: string;
  /** epoch millis when captured */
  ts: number;
};

export type LogEvent = {
  message: string;
};

export type StatEvent = {
  /** Mac battery charge percent, 0–100. Absent on a desktop Mac or a proximity-only frame. */
  level?: number;
  /** whether the Mac is currently charging */
  charging?: boolean;
  /** BLE proximity state the Mac computed from scanning this phone: "near" | "away" | "unseen" | "off".
   *  The phone can't measure distance itself (it only advertises), so it relies on this. */
  prox?: 'near' | 'away' | 'unseen' | 'off';
  /** smoothed signal strength (dBm) the Mac measured for this phone; present only when prox is near/away */
  rssi?: number;
};

/** A launchable app for the per-app notification-mirroring picker. */
export type InstalledApp = {
  /** Android package name (the filter key). */
  pkg: string;
  /** human-readable app name */
  label: string;
  /** file:// URI of the cached launcher-icon PNG, or null if it couldn't be rasterized */
  icon: string | null;
};

/** "exclude" mirrors every app except the exclude set (default); "include" mirrors only the include set. */
export type NotifFilterMode = 'include' | 'exclude';

/** The per-app mirroring filter. Each mode keeps its own package set so flipping modes
 *  doesn't lose the other's selection; only the active mode's set is enforced. */
export type NotifAppFilter = {
  mode: NotifFilterMode;
  include: string[];
  exclude: string[];
};

/**
 * Outcome of a runtime-permission request.
 *  - `granted` — now held.
 *  - `denied`  — a person answered the system prompt with "Don't allow".
 *  - `blocked` — Android refused without showing a prompt (a permission denied twice, or the
 *    restricted-settings block a sideloaded APK hits for SMS). Only App info can still grant it.
 */
export type PermissionRequestResult = 'granted' | 'denied' | 'blocked';

export type StatusEvent = {
  /** adb connection: "idle" | "connecting" | "connected" | "failed" */
  adb: string;
  /** clip bridge: "idle" | "running" | "stopped" */
  clip: string;
};

export type RelayEvent = {
  /** "disconnected" | "connecting" | "connected" | "joined" | "error" */
  status: string;
  /** whether the Mac peer is present in the room */
  peerOnline: boolean;
  lastError?: string | null;
  /** which transport is active: "lan" (relay-less, same network) | "relay" | null when down */
  transport?: 'lan' | 'relay' | null;
  /** consecutive reconnect attempts on the active link; 0 once joined. Drives Reconnecting vs Disconnected. */
  attempt?: number;
};

export type FileTransferStatus = 'queued' | 'active' | 'done' | 'failed' | 'cancelled';

/** One row of the Files screen: a file that came from the Mac or went to it. */
export type FileTransferEntry = {
  id: string;
  direction: 'in' | 'out';
  name: string;
  /** folder the file sat in (`Photos/2024`), when a folder was sent/received */
  dir: string | null;
  /** bytes */
  size: number;
  mime: string;
  /** epoch ms */
  ts: number;
  status: FileTransferStatus;
  error: string | null;
  /** 0..100 while active */
  progress: number;
  /** where a received file now lives (a content URI) — pass to `openFile` */
  uri: string | null;
  /** a send that didn't finish and can be re-sent (it was picked in the app, so its read grant persisted) */
  retryable: boolean;
};

export type SelfAdbModuleEvents = {
  /** a file-transfer row was added or changed (progress, status) */
  onFileTransfer: (event: FileTransferEntry) => void;
  onClip: (event: ClipEvent) => void;
  /** a clip received FROM the Mac (written to this device's clipboard) */
  onMacClip: (event: ClipEvent) => void;
  /** telemetry received FROM the Mac (e.g. battery level + charging state) */
  onMacStat: (event: StatEvent) => void;
  onLog: (event: LogEvent) => void;
  onStatus: (event: StatusEvent) => void;
  onRelay: (event: RelayEvent) => void;
};
