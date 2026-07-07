// Wire protocol (JSON over WebSocket). Matches workflow.md Parça 3.
// The relay reads control messages but treats `clip` as opaque (E2E encrypted).

export type Device = 'android' | 'mac';

// --- client -> relay ---
export interface JoinMsg {
  t: 'join';
  room: string;
  device: Device;
}

export interface ClipMsg {
  t: 'clip';
  nonce: string;
  ct: string;
}

// A remote action targeting the peer (e.g. lock the Mac). The action plaintext is
// E2E-encrypted (ChaCha20-Poly1305) into `nonce`/`ct` exactly like a `clip`, so the
// relay never sees which command it forwards — it stays a verbatim, opaque pipe.
export interface CmdMsg {
  t: 'cmd';
  nonce: string;
  ct: string;
}

// Telemetry from a peer (e.g. the Mac's battery). E2E-encrypted (`nonce`/`ct`) exactly like a
// `clip`, so the relay forwards it verbatim and never sees the contents — opaque, just like clips.
export interface StatMsg {
  t: 'stat';
  nonce: string;
  ct: string;
}

// A mirrored device notification (phone → Mac). E2E-encrypted (`nonce`/`ct`) exactly like a
// `clip`, so the relay forwards it verbatim and never sees the contents — opaque, just like clips.
export interface NoteMsg {
  t: 'note';
  nonce: string;
  ct: string;
}

// A batch/delta of mirrored SMS messages (phone → Mac). E2E-encrypted (`nonce`/`ct`) exactly like a
// `clip`, so the relay forwards it verbatim and never sees the contents — opaque, just like clips.
export interface SmsMsg {
  t: 'sms';
  nonce: string;
  ct: string;
}

// A transferred file (Mac → phone clipboard image for now). E2E-encrypted (`nonce`/`ct`) exactly
// like a `clip`, so the relay forwards it verbatim and never sees the contents — opaque, just like clips.
export interface FileMsg {
  t: 'file';
  nonce: string;
  ct: string;
}

export interface PingMsg {
  t: 'ping';
}

export interface PongMsg {
  t: 'pong';
}

export type ClientMessage =
  | JoinMsg
  | ClipMsg
  | CmdMsg
  | StatMsg
  | NoteMsg
  | SmsMsg
  | FileMsg
  | PingMsg
  | PongMsg;

// --- relay -> client ---
export type ErrorCode =
  | 'bad-message'
  | 'bad-join'
  | 'room-full'
  | 'not-joined'
  | 'rate-limit'
  | 'join-timeout';

export interface JoinedMsg {
  t: 'joined';
  peers: Device[];
}

export interface PeerMsg {
  t: 'peer';
  state: 'online' | 'offline';
  device: Device;
}

export interface ErrorMsg {
  t: 'error';
  code: ErrorCode;
  message: string;
}

export type ServerMessage = JoinedMsg | PeerMsg | ErrorMsg | PongMsg;

const DEVICES: readonly string[] = ['android', 'mac'];
const ROOM_MIN = 16;
const ROOM_MAX = 128;

function isDevice(v: unknown): v is Device {
  return typeof v === 'string' && DEVICES.includes(v);
}

function isValidRoom(v: unknown): v is string {
  return typeof v === 'string' && v.length >= ROOM_MIN && v.length <= ROOM_MAX;
}

/** Parse + validate an inbound text frame. Returns null for anything malformed. */
export function parseClientMessage(raw: string): ClientMessage | null {
  let data: unknown;
  try {
    data = JSON.parse(raw);
  } catch {
    return null;
  }
  if (typeof data !== 'object' || data === null) return null;
  const obj = data as Record<string, unknown>;

  switch (obj.t) {
    case 'join':
      if (!isValidRoom(obj.room) || !isDevice(obj.device)) return null;
      return { t: 'join', room: obj.room, device: obj.device };
    case 'clip':
      if (typeof obj.nonce !== 'string' || obj.nonce.length === 0) return null;
      if (typeof obj.ct !== 'string' || obj.ct.length === 0) return null;
      return { t: 'clip', nonce: obj.nonce, ct: obj.ct };
    case 'cmd':
      if (typeof obj.nonce !== 'string' || obj.nonce.length === 0) return null;
      if (typeof obj.ct !== 'string' || obj.ct.length === 0) return null;
      return { t: 'cmd', nonce: obj.nonce, ct: obj.ct };
    case 'stat':
      if (typeof obj.nonce !== 'string' || obj.nonce.length === 0) return null;
      if (typeof obj.ct !== 'string' || obj.ct.length === 0) return null;
      return { t: 'stat', nonce: obj.nonce, ct: obj.ct };
    case 'note':
      if (typeof obj.nonce !== 'string' || obj.nonce.length === 0) return null;
      if (typeof obj.ct !== 'string' || obj.ct.length === 0) return null;
      return { t: 'note', nonce: obj.nonce, ct: obj.ct };
    case 'sms':
      if (typeof obj.nonce !== 'string' || obj.nonce.length === 0) return null;
      if (typeof obj.ct !== 'string' || obj.ct.length === 0) return null;
      return { t: 'sms', nonce: obj.nonce, ct: obj.ct };
    case 'file':
      if (typeof obj.nonce !== 'string' || obj.nonce.length === 0) return null;
      if (typeof obj.ct !== 'string' || obj.ct.length === 0) return null;
      return { t: 'file', nonce: obj.nonce, ct: obj.ct };
    case 'ping':
      return { t: 'ping' };
    case 'pong':
      return { t: 'pong' };
    default:
      return null;
  }
}

export function serialize(msg: ServerMessage): string {
  return JSON.stringify(msg);
}
