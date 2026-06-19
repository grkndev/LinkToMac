import http from 'node:http';
import { timingSafeEqual } from 'node:crypto';
import process from 'node:process';

import { WebSocketServer, type WebSocket } from 'ws';

import { loadConfig } from './config.js';
import { createLogger } from './logger.js';
import { parseClientMessage, serialize } from './protocol.js';
import { SlidingWindowLimiter } from './ratelimit.js';
import { startHeartbeat } from './heartbeat.js';
import { CLOSE_JOIN_TIMEOUT, CLOSE_RATE_LIMIT, Relay, type Conn } from './relay.js';

const config = loadConfig();
const log = createLogger(config);
const startedAt = Date.now();

const relay = new Relay(log, {
  maxPeersPerRoom: config.maxPeersPerRoom,
  // Allow some buffering before declaring a peer a slow consumer.
  maxBufferedBytes: config.maxPayloadBytes * 8,
});

const conns = new Set<Conn>();
let connSeq = 0;

const server = http.createServer((req, res) => {
  if (req.method === 'GET' && req.url === '/health') {
    const { rooms, conns: connCount } = relay.stats();
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(
      JSON.stringify({
        status: 'ok',
        rooms,
        conns: connCount,
        uptimeSec: Math.floor((Date.now() - startedAt) / 1000),
      }),
    );
    return;
  }
  res.writeHead(404, { 'content-type': 'text/plain' });
  res.end('not found');
});

const wss = new WebSocketServer({ noServer: true, maxPayload: config.maxPayloadBytes });

function tokenOk(req: http.IncomingMessage): boolean {
  if (!config.authToken) return true; // ALLOW_NO_AUTH
  let provided: string | null = null;
  const auth = req.headers['authorization'];
  if (typeof auth === 'string' && auth.startsWith('Bearer ')) {
    provided = auth.slice('Bearer '.length).trim();
  } else {
    provided = new URL(req.url ?? '', 'http://localhost').searchParams.get('token');
  }
  if (!provided) return false;
  const a = Buffer.from(provided);
  const b = Buffer.from(config.authToken);
  return a.length === b.length && timingSafeEqual(a, b);
}

server.on('upgrade', (req, socket, head) => {
  const pathname = new URL(req.url ?? '', 'http://localhost').pathname;
  if (pathname !== '/ws') {
    socket.write('HTTP/1.1 404 Not Found\r\n\r\n');
    socket.destroy();
    return;
  }
  if (!tokenOk(req)) {
    socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n');
    socket.destroy();
    return;
  }
  wss.handleUpgrade(req, socket, head, (ws) => wss.emit('connection', ws, req));
});

wss.on('connection', (ws: WebSocket) => {
  const conn: Conn = {
    ws,
    id: `c${++connSeq}`,
    isAlive: true,
    room: null,
    device: null,
    limiter: new SlidingWindowLimiter(config.rateLimitMsgs, config.rateLimitWindowMs),
  };
  conns.add(conn);

  // Drop connections that never join.
  const joinTimer = setTimeout(() => {
    if (!conn.room) {
      ws.send(serialize({ t: 'error', code: 'join-timeout', message: 'join timeout' }));
      ws.close(CLOSE_JOIN_TIMEOUT, 'join-timeout');
    }
  }, config.joinTimeoutMs);

  ws.on('pong', () => {
    conn.isAlive = true;
  });

  ws.on('message', (data, isBinary) => {
    if (isBinary) {
      ws.send(serialize({ t: 'error', code: 'bad-message', message: 'binary frames not supported' }));
      return;
    }
    if (!conn.limiter.hit()) {
      ws.send(serialize({ t: 'error', code: 'rate-limit', message: 'rate limit exceeded' }));
      ws.close(CLOSE_RATE_LIMIT, 'rate-limit');
      return;
    }
    const msg = parseClientMessage(data.toString());
    if (!msg) {
      ws.send(serialize({ t: 'error', code: 'bad-message', message: 'invalid message' }));
      return;
    }
    switch (msg.t) {
      case 'join':
        relay.handleJoin(conn, msg);
        if (conn.room) clearTimeout(joinTimer);
        break;
      case 'clip':
        relay.handleClip(conn, msg);
        break;
      case 'cmd':
        relay.handleCmd(conn, msg);
        break;
      case 'stat':
        relay.handleStat(conn, msg);
        break;
      case 'ping':
        ws.send(serialize({ t: 'pong' }));
        break;
      case 'pong':
        conn.isAlive = true;
        break;
    }
  });

  ws.on('close', () => {
    clearTimeout(joinTimer);
    relay.handleClose(conn);
    conns.delete(conn);
  });

  ws.on('error', (err) => {
    log.warn({ id: conn.id, err: err.message }, 'socket error');
  });
});

const stopHeartbeat = startHeartbeat(() => conns, config.pingIntervalMs);

server.listen(config.port, config.host, () => {
  log.info(
    { host: config.host, port: config.port, auth: config.authToken ? 'token' : 'DISABLED' },
    'relay listening',
  );
  if (!config.authToken) {
    log.warn('RELAY_AUTH_TOKEN is disabled (ALLOW_NO_AUTH). Do NOT run like this in production.');
  }
});

let shuttingDown = false;
function shutdown(signal: string): void {
  if (shuttingDown) return;
  shuttingDown = true;
  log.info({ signal }, 'shutting down');
  stopHeartbeat();
  server.close();
  for (const conn of conns) conn.ws.close(1001, 'server shutting down');
  const force = setTimeout(() => process.exit(0), 3000);
  force.unref();
  wss.close(() => {
    clearTimeout(force);
    process.exit(0);
  });
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
