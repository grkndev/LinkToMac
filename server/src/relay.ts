import { WebSocket } from 'ws';

import type { Logger } from './logger.js';
import type { SlidingWindowLimiter } from './ratelimit.js';
import {
  serialize,
  type ClipMsg,
  type CmdMsg,
  type Device,
  type JoinMsg,
  type NoteMsg,
  type ServerMessage,
  type StatMsg,
} from './protocol.js';

export interface Conn {
  ws: WebSocket;
  id: string;
  isAlive: boolean;
  room: string | null;
  device: Device | null;
  limiter: SlidingWindowLimiter;
}

// Application-specific close codes (4000-4999).
export const CLOSE_REPLACED = 4000;
export const CLOSE_ROOM_FULL = 4001;
export const CLOSE_RATE_LIMIT = 4002;
export const CLOSE_BACKPRESSURE = 4003;
export const CLOSE_JOIN_TIMEOUT = 4004;

interface RelayOptions {
  maxPeersPerRoom: number;
  maxBufferedBytes: number;
}

/**
 * The "dumb pipe". Holds `roomId -> { device -> connection }` in memory and
 * forwards opaque `clip` frames between the two peers of a room. No storage,
 * no decryption: `nonce`/`ct` are never inspected.
 */
export class Relay {
  private readonly rooms = new Map<string, Map<Device, Conn>>();

  constructor(
    private readonly log: Logger,
    private readonly opts: RelayOptions,
  ) {}

  handleJoin(conn: Conn, msg: JoinMsg): void {
    if (conn.room) {
      this.send(conn, { t: 'error', code: 'bad-join', message: 'already joined' });
      return;
    }

    let room = this.rooms.get(msg.room);
    if (!room) {
      room = new Map();
      this.rooms.set(msg.room, room);
    }

    // newest-wins: a re-connecting device evicts its stale connection.
    const stale = room.get(msg.device);
    if (stale && stale !== conn) {
      this.log.info({ room: redactRoom(msg.room), device: msg.device }, 'replacing stale peer');
      room.delete(msg.device);
      this.send(stale, { t: 'error', code: 'room-full', message: 'replaced by a newer connection' });
      stale.room = null;
      stale.device = null;
      stale.ws.close(CLOSE_REPLACED, 'replaced');
    }

    if (!room.has(msg.device) && room.size >= this.opts.maxPeersPerRoom) {
      this.send(conn, { t: 'error', code: 'room-full', message: 'room is full' });
      conn.ws.close(CLOSE_ROOM_FULL, 'room-full');
      if (room.size === 0) this.rooms.delete(msg.room);
      return;
    }

    conn.room = msg.room;
    conn.device = msg.device;
    room.set(msg.device, conn);

    const peers = [...room.keys()].filter((d) => d !== msg.device);
    this.send(conn, { t: 'joined', peers });
    for (const peer of room.values()) {
      if (peer !== conn) this.send(peer, { t: 'peer', state: 'online', device: msg.device });
    }
    this.log.info({ room: redactRoom(msg.room), device: msg.device, size: room.size }, 'joined');
  }

  handleClip(conn: Conn, msg: ClipMsg): void {
    if (!conn.room || !conn.device) {
      this.send(conn, { t: 'error', code: 'not-joined', message: 'join before sending clips' });
      return;
    }
    const room = this.rooms.get(conn.room);
    if (!room) return;

    // Forward verbatim to the *other* peer(s); never echo to the sender.
    const payload = JSON.stringify(msg);
    let delivered = 0;
    for (const peer of room.values()) {
      if (peer === conn || peer.ws.readyState !== WebSocket.OPEN) continue;
      if (peer.ws.bufferedAmount > this.opts.maxBufferedBytes) {
        this.log.warn({ device: peer.device }, 'slow consumer; dropping connection');
        peer.ws.close(CLOSE_BACKPRESSURE, 'backpressure');
        continue;
      }
      peer.ws.send(payload);
      delivered++;
    }
    // Content stays opaque: only sender, room, ciphertext size, and fan-out are logged.
    this.log.info(
      { room: redactRoom(conn.room), from: conn.device, bytes: msg.ct.length, delivered },
      'clip',
    );
  }

  handleCmd(conn: Conn, msg: CmdMsg): void {
    if (!conn.room || !conn.device) {
      this.send(conn, { t: 'error', code: 'not-joined', message: 'join before sending commands' });
      return;
    }
    const room = this.rooms.get(conn.room);
    if (!room) return;

    // Same fan-out as clips: forward verbatim to the *other* peer(s); never echo. The
    // action is E2E-encrypted (nonce/ct), so the relay can't tell one command from
    // another — new commands never need a server change.
    const payload = JSON.stringify(msg);
    let delivered = 0;
    for (const peer of room.values()) {
      if (peer === conn || peer.ws.readyState !== WebSocket.OPEN) continue;
      if (peer.ws.bufferedAmount > this.opts.maxBufferedBytes) {
        this.log.warn({ device: peer.device }, 'slow consumer; dropping connection');
        peer.ws.close(CLOSE_BACKPRESSURE, 'backpressure');
        continue;
      }
      peer.ws.send(payload);
      delivered++;
    }
    this.log.info(
      { room: redactRoom(conn.room), from: conn.device, bytes: msg.ct.length, delivered },
      'cmd',
    );
  }

  handleStat(conn: Conn, msg: StatMsg): void {
    if (!conn.room || !conn.device) {
      this.send(conn, { t: 'error', code: 'not-joined', message: 'join before sending stats' });
      return;
    }
    const room = this.rooms.get(conn.room);
    if (!room) return;

    // Same fan-out as clips/cmds: forward verbatim to the *other* peer(s); never echo. The
    // telemetry is E2E-encrypted (nonce/ct), so the relay stays a verbatim, opaque pipe.
    const payload = JSON.stringify(msg);
    let delivered = 0;
    for (const peer of room.values()) {
      if (peer === conn || peer.ws.readyState !== WebSocket.OPEN) continue;
      if (peer.ws.bufferedAmount > this.opts.maxBufferedBytes) {
        this.log.warn({ device: peer.device }, 'slow consumer; dropping connection');
        peer.ws.close(CLOSE_BACKPRESSURE, 'backpressure');
        continue;
      }
      peer.ws.send(payload);
      delivered++;
    }
    this.log.info(
      { room: redactRoom(conn.room), from: conn.device, bytes: msg.ct.length, delivered },
      'stat',
    );
  }

  handleNote(conn: Conn, msg: NoteMsg): void {
    if (!conn.room || !conn.device) {
      this.send(conn, { t: 'error', code: 'not-joined', message: 'join before sending notes' });
      return;
    }
    const room = this.rooms.get(conn.room);
    if (!room) return;

    // Same fan-out as clips/cmds/stats: forward verbatim to the *other* peer(s); never echo. The
    // notification is E2E-encrypted (nonce/ct), so the relay stays a verbatim, opaque pipe.
    const payload = JSON.stringify(msg);
    let delivered = 0;
    for (const peer of room.values()) {
      if (peer === conn || peer.ws.readyState !== WebSocket.OPEN) continue;
      if (peer.ws.bufferedAmount > this.opts.maxBufferedBytes) {
        this.log.warn({ device: peer.device }, 'slow consumer; dropping connection');
        peer.ws.close(CLOSE_BACKPRESSURE, 'backpressure');
        continue;
      }
      peer.ws.send(payload);
      delivered++;
    }
    this.log.info(
      { room: redactRoom(conn.room), from: conn.device, bytes: msg.ct.length, delivered },
      'note',
    );
  }

  handleClose(conn: Conn): void {
    if (!conn.room || !conn.device) return;
    const room = this.rooms.get(conn.room);
    if (!room) return;

    if (room.get(conn.device) === conn) {
      const device = conn.device;
      room.delete(device);
      for (const peer of room.values()) {
        this.send(peer, { t: 'peer', state: 'offline', device });
      }
      this.log.info({ room: redactRoom(conn.room), device, size: room.size }, 'left');
    }
    if (room.size === 0) this.rooms.delete(conn.room);

    conn.room = null;
    conn.device = null;
  }

  stats(): { rooms: number; conns: number } {
    let conns = 0;
    for (const room of this.rooms.values()) conns += room.size;
    return { rooms: this.rooms.size, conns };
  }

  private send(conn: Conn, msg: ServerMessage): void {
    if (conn.ws.readyState === WebSocket.OPEN) conn.ws.send(serialize(msg));
  }
}

/** Avoid logging the full bearer roomId; a short prefix is enough to correlate. */
function redactRoom(room: string): string {
  return `${room.slice(0, 6)}…`;
}
