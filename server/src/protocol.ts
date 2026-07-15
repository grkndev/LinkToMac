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
// Rooms are base64 of 32 random bytes; accept the base64 + base64url alphabets and nothing
// else (no control chars / whitespace riding into log lines or map keys).
const ROOM_RE = /^[A-Za-z0-9+/=_-]+$/;

function isDevice(v: unknown): v is Device {
  return typeof v === 'string' && DEVICES.includes(v);
}

function isValidRoom(v: unknown): v is string {
  return (
    typeof v === 'string' && v.length >= ROOM_MIN && v.length <= ROOM_MAX && ROOM_RE.test(v)
  );
}

// The relay must be at least as strict as the strictest client, or it forwards frames the
// receiver silently drops ("I sent it but the Mac never saw it"). Both codecs require a
// 12-byte nonce (`ChaChaPoly.Nonce` / `NONCE_LEN`) — exactly 16 base64 chars, no padding —
// and reject any ct shorter than the 16-byte Poly1305 tag (24 base64 chars with padding).
const NONCE_RE = /^[A-Za-z0-9+/]{16}$/;
const CT_RE = /^[A-Za-z0-9+/]+={0,2}$/;
const CT_MIN_B64 = 24;

function isValidNonce(v: unknown): v is string {
  return typeof v === 'string' && NONCE_RE.test(v);
}

// `% 4` matters: Swift's base64 decoder rejects ragged lengths outright, so a ct that
// isn't block-aligned would be forwarded by the relay and then fail to even decode.
function isValidCt(v: unknown): v is string {
  return (
    typeof v === 'string' && v.length >= CT_MIN_B64 && v.length % 4 === 0 && CT_RE.test(v)
  );
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
      if (!isValidNonce(obj.nonce) || !isValidCt(obj.ct)) return null;
      return { t: 'clip', nonce: obj.nonce, ct: obj.ct };
    case 'cmd':
      if (!isValidNonce(obj.nonce) || !isValidCt(obj.ct)) return null;
      return { t: 'cmd', nonce: obj.nonce, ct: obj.ct };
    case 'stat':
      if (!isValidNonce(obj.nonce) || !isValidCt(obj.ct)) return null;
      return { t: 'stat', nonce: obj.nonce, ct: obj.ct };
    case 'note':
      if (!isValidNonce(obj.nonce) || !isValidCt(obj.ct)) return null;
      return { t: 'note', nonce: obj.nonce, ct: obj.ct };
    case 'sms':
      if (!isValidNonce(obj.nonce) || !isValidCt(obj.ct)) return null;
      return { t: 'sms', nonce: obj.nonce, ct: obj.ct };
    case 'file':
      if (!isValidNonce(obj.nonce) || !isValidCt(obj.ct)) return null;
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
