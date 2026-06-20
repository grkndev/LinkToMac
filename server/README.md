# Link to macOS — Relay Server

A minimal **WebSocket relay** ("dumb pipe") for the Android ↔ macOS clipboard sync
project. It pairs the two ends of a room by `roomId` and forwards **end-to-end
encrypted** `clip` / `cmd` / `stat` frames between them. The relay never stores or
decrypts content — it only sees `roomId`, ciphertext size, and timing.

See the design doc: [`../docs/plans/2026-06-09-relay-server-design.md`](../docs/plans/2026-06-09-relay-server-design.md).

## Requirements

- Node.js ≥ 20 (Docker image uses Node 22).

## Local development

```bash
cd server
npm install
cp .env.example .env          # set RELAY_AUTH_TOKEN, or ALLOW_NO_AUTH=true for quick local runs
npm run dev                   # tsx watch, pretty logs
```

Check health:

```bash
curl localhost:8080/health
# {"status":"ok","rooms":0,"conns":0,"uptimeSec":3}
```

Run the end-to-end smoke test (server must be running; honors `PORT`/`RELAY_AUTH_TOKEN`):

```bash
RELAY_AUTH_TOKEN=$(grep '^RELAY_AUTH_TOKEN=' .env | cut -d= -f2) npm run smoke
```

## Configuration

All via env vars (see `.env.example`):

| Variable | Default | Notes |
|---|---|---|
| `HOST` | `0.0.0.0` | bind address |
| `PORT` | `8080` | listen port |
| `RELAY_AUTH_TOKEN` | — | **required in production**; clients pass it as `?token=` or `Authorization: Bearer`. Generate: `openssl rand -hex 32` |
| `ALLOW_NO_AUTH` | `false` | set `true` to run without a token (local dev only) |
| `MAX_PEERS_PER_ROOM` | `2` | per-room connection cap |
| `MAX_PAYLOAD_BYTES` | `262144` | 256 KB frame cap |
| `PING_INTERVAL_MS` | `50000` | ws-level heartbeat; keep < front-proxy WS read timeout (nginx default 60s). Higher = fewer mobile radio wakeups |
| `JOIN_TIMEOUT_MS` | `10000` | close if no `join` arrives |
| `RATE_LIMIT_MSGS` / `RATE_LIMIT_WINDOW_MS` | `120` / `10000` | per-connection sliding window |
| `LOG_LEVEL` | `info` | pino level |

## Wire protocol

Connect to `ws://host:PORT/ws?token=<RELAY_AUTH_TOKEN>` (or send `Authorization: Bearer`).
First message must be `join`.

```jsonc
// client → relay
{ "t": "join", "room": "<roomId>", "device": "android" | "mac" }
{ "t": "clip", "nonce": "<base64>", "ct": "<base64>" }   // opaque, forwarded verbatim
{ "t": "cmd",  "nonce": "<base64>", "ct": "<base64>" }   // remote action (e.g. lock), opaque
{ "t": "stat", "nonce": "<base64>", "ct": "<base64>" }   // telemetry (e.g. Mac battery), opaque
{ "t": "ping" }

// relay → client
{ "t": "joined", "peers": ["mac"] }
{ "t": "peer", "state": "online" | "offline", "device": "mac" }
{ "t": "clip", "nonce": "...", "ct": "..." }   // the peer's clip/cmd/stat, relayed verbatim
{ "t": "cmd",  "nonce": "...", "ct": "..." }
{ "t": "stat", "nonce": "...", "ct": "..." }
{ "t": "error", "code": "room-full" | "bad-join" | "not-joined" | "rate-limit" | "join-timeout" | "bad-message", "message": "..." }
{ "t": "pong" }
```

`clip`, `cmd`, and `stat` are forwarded to the *other* peer only — the sender never receives its
own echo.

## Docker

The relay runs behind a reverse proxy on a **shared Docker network** and does **not** publish
a host port — only the proxy can reach it (by container name `linktomac-relay:$PORT`).

```bash
cd server
cp .env.example .env          # set a real RELAY_AUTH_TOKEN (and PORT if not 8080)
# `shared-db` is the proxy's network and must already exist:
docker network ls | grep shared-db || docker network create shared-db
docker compose up -d --build
docker compose ps             # STATUS should become "healthy"
docker compose logs -f relay
docker compose down           # graceful shutdown (SIGTERM)
```

In **nginx-proxy-manager**, add a Proxy Host: forward to **`linktomac-relay`** : **`$PORT`**,
scheme **`http`**, **Websockets support ON**, request a Let's Encrypt cert. The container serves
**plain `ws`**; the proxy terminates TLS, so clients connect to `wss://<your-domain>/ws`.
(The relay's network name in `docker-compose.yml` must match the proxy's — here `shared-db`.)

## Behind a reverse proxy (VPS, wss)

The relay needs the proxy to forward the WebSocket `Upgrade`. The public endpoint
becomes `wss://<your-domain>/ws`.

**Caddy** (automatic Let's Encrypt) — a ready-to-edit [`./Caddyfile`](./Caddyfile) is
committed; replace the domain and run `caddy run --config ./Caddyfile`:

```caddy
relay.example.com {
    reverse_proxy 127.0.0.1:8080
}
```

Caddy forwards WebSocket upgrades automatically — no extra config needed.

**In the app:** set `host = relay.example.com`, `port = 443`, **TLS on** (Mac:
`RELAY_SECURE = true` in `Secrets.xcconfig`). The Mac embeds host/port/TLS/password into the
pairing QR, so the phone auto-fills the server config on scan (it's also editable under
Settings → Relay server).

> **LAN-direct (future):** a Let's Encrypt cert can't be issued for a private LAN IP. That mode
> will instead pin a **self-signed** cert via the QR (the app's `certFingerprint` field), using
> the same `wss://` path — no public domain required.

**Nginx:**

```nginx
location /ws {
    proxy_pass http://127.0.0.1:8080;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_read_timeout 3600s;   # keep idle WebSocket connections alive
}
```

## Security notes

- The relay is a dumb pipe: `nonce`/`ct` are **never** parsed or logged. Clipboard
  content is end-to-end encrypted by the Android/Mac clients (libsodium secretbox).
- `roomId` is an unguessable 256-bit bearer; `RELAY_AUTH_TOKEN` is the operator-defined
  **relay password** — a second gate so strangers can't open sockets against your VPS. The
  clients no longer bake it in: the Mac reads it from `Secrets.xcconfig` and ships it to the
  phone in the pairing QR (and it's editable in the app), so each operator sets their own.
- Per-room cap (2), per-connection rate limit, 256 KB payload cap, ws-level heartbeat
  with dead-connection cleanup, and slow-consumer backpressure handling.
