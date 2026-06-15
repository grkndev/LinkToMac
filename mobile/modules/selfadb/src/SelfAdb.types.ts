export type ClipEvent = {
  /** clipboard text captured on the device */
  text: string;
  /** epoch millis when captured */
  ts: number;
};

export type LogEvent = {
  message: string;
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
};

export type SelfAdbModuleEvents = {
  onClip: (event: ClipEvent) => void;
  /** a clip received FROM the Mac (written to this device's clipboard) */
  onMacClip: (event: ClipEvent) => void;
  onLog: (event: LogEvent) => void;
  onStatus: (event: StatusEvent) => void;
  onRelay: (event: RelayEvent) => void;
};
