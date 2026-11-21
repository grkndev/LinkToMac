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

export type AppUpdateStatus = 'idle' | 'downloading' | 'ready' | 'failed';

/** The pending native update (a newer APK on GitHub), as the background updater sees it. */
export type AppUpdateState = {
  /** `idle` = found but not fetched (auto-download off, or no APK asset); `ready` = verified and installable. */
  state: AppUpdateStatus;
  /** the newer version, or null when nothing newer is pending */
  version: string | null;
  notes: string | null;
  /** the APK URL, else the release page — the browser fallback when `downloadable` is false */
  url: string | null;
  /** the release has an APK asset the app can fetch itself */
  downloadable: boolean;
  /** 0..100 while `downloading` */
  progress: number;
  /** why the last attempt failed (`failed` only) */
  error: string | null;
};

/** One entry of `ApplicationExitInfo`: why Android ended this app's process. */
export type ExitReason = {
  /** epoch milliseconds */
  timestamp: number;
  /** readable name: LOW_MEMORY, CRASH, CRASH_NATIVE, ANR, USER_REQUESTED, … (`REASON_<n>` when unknown) */
  reason: string;
  /** the process's importance when it died: FOREGROUND, FOREGROUND_SERVICE, CACHED, … */
  importance: string;
  /** exit status / signal number, as the OS reports it */
  status: number;
  /** OEM free text, capped; empty when there is none */
  description: string;
};

export type AppUpdateCheck = AppUpdateState & {
  /** false when the probe itself failed (offline / API error) — "no update" must not be claimed then */
  checked: boolean;
};

export type SelfAdbModuleEvents = {
  /** the pending native update changed state or download progress */
  onAppUpdate: (event: AppUpdateState) => void;
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

/**
 * The QUIC developer screen's view of the phone-to-Mac data plane (stage 1.8). Plain words and flags only: never an address, a port, a
 * fingerprint, a token or a session id.
 */
export type QuicStatus = {
  /** QUIC can be used right now: the library is in this build, the Mac announced `q1` and the LAN-direct link is up. */
  available: boolean;
  /** `Idle`, `AwaitingOffer`, `Connecting`, `Connected` or `Ended(<reason>)`. */
  state: string;
  /** What last happened, as a sentence, or `null` when nothing has. */
  last: string | null;
  /** Why QUIC is not available, or `null` when it is. */
  reason: string | null;
  /** Only a debuggable build can run the echo test. */
  debuggable: boolean;
  /** The link's round-trip time in milliseconds while a session is open, else `null`. */
  rttMs: number | null;
  /** Packets the QUIC connection counted as lost while a session is open, else `null`. */
  lostPackets: number | null;
  /** Congestion events while a session is open, else `null`. */
  congestionEvents: number | null;
};

/** `none` = the echo check; `fp`/`tok` = flip one character and expect the right refusal; `hold` = stay connected; `force` = ask even if the gate says no. */
export type QuicSelfTestMode = 'none' | 'fp' | 'tok' | 'hold' | 'force';
