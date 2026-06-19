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
  /** Mac battery charge percent, 0–100 */
  level: number;
  /** whether the Mac is currently charging */
  charging: boolean;
};

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

export type SelfAdbModuleEvents = {
  onClip: (event: ClipEvent) => void;
  /** a clip received FROM the Mac (written to this device's clipboard) */
  onMacClip: (event: ClipEvent) => void;
  /** telemetry received FROM the Mac (e.g. battery level + charging state) */
  onMacStat: (event: StatEvent) => void;
  onLog: (event: LogEvent) => void;
  onStatus: (event: StatusEvent) => void;
  onRelay: (event: RelayEvent) => void;
};
