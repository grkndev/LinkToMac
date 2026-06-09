# Relay Server — Tasarım (Link to macOS)

> Tarih: 2026-06-09 · Kapsam: `workflow.md` Parça 3'teki **Node `ws` relay** bileşeni (#3).
> Kişisel kullanım. Şimdilik localhost, ama VPS için production-ready + Docker.

## Karar Özeti (bu brainstorm'da netleşen)

| Konu | Karar |
|---|---|
| Runtime / dil | **Node (LTS) + TypeScript**, `ws` kütüphanesi. Prod'da derlenmiş JS çalışır. |
| TLS / domain | **TLS dışarıda** — VPS'teki mevcut reverse proxy (Caddy/Nginx/Traefik) terminate eder. Container düz `ws` expose eder. Localhost'ta zaten düz `ws`. |
| Erişim kontrolü | `roomId` (256-bit bearer) **+ global `RELAY_AUTH_TOKEN`** (defense-in-depth). E2E'ye dokunmaz. |
| Relay rolü | "Aptal boru" — depolama yok, çözme yok. `nonce`/`ct` parse/log edilmez. |

## Mimari

Tek Node süreci. `http.createServer` üstüne `ws` `noServer` modunda bağlanır.

- **HTTP yüzeyi:** sadece `GET /health` → `200 {status:"ok", rooms, conns, uptimeSec}`. Proxy + Docker healthcheck için. Diğer HTTP yolları `404`.
- **WS yüzeyi:** `/ws` path'inde upgrade. `upgrade` event'inde önce **token doğrulanır**, sonra `handleUpgrade`.

### Bağlantı yaşam döngüsü

1. Client `ws://host:PORT/ws?token=...` (veya `Authorization: Bearer <token>`) ile bağlanır.
   Token **upgrade anında** timing-safe karşılaştırılır; geçersizse `401` → socket açılmaz.
2. İlk mesaj `join` olmalı. `JOIN_TIMEOUT_MS` içinde gelmezse bağlantı kapatılır.
3. `join` doğrulama:
   - `room`: string, 16–128 karakter.
   - `device` ∈ {`android`, `mac`}.
   - Oda doluysa (`MAX_PEERS_PER_ROOM=2`) → `error{code:"room-full"}` + close.
   - **(room, device) başına tek bağlantı**: aynı cihaz tekrar join ederse eski bağlantı kapatılır (*newest wins*). Reconnect / hayalet bağlantıyı zarifçe çözer.
   - Cevap: `joined{peers}`; karşı uca `peer{state:"online"}`.
4. `clip` mesajı → odadaki **diğer** uca aynen iletilir (gönderene değil). İçerik parse edilmez, sadece boyut kontrolü.
5. `ping`/`pong`: hem app-level hem ws-level heartbeat.
6. Kapanış: odadan çıkar, peer'a `peer{state:"offline"}`, oda boşsa sil.

### Wire protokolü (spec Parça 3 ile birebir)

```
client→relay:  { "t":"join", "room":"<roomId>", "device":"android|mac" }
relay→client:  { "t":"joined", "peers":["mac"] }
relay→client:  { "t":"peer", "state":"online|offline", "device":"mac" }
relay→client:  { "t":"error", "code":"room-full|bad-join|rate-limit|...", "message":"..." }
çift yön:      { "t":"ping" } / { "t":"pong" }
veri (opak):   { "t":"clip", "nonce":"<b64>", "ct":"<b64>" }
```

E2E içerik (`origin`/`seq`/`text`/`ts`) `ct`'nin **içinde** taşınır; relay göremez.

## Konfigürasyon (env, 12-factor)

| Değişken | Default | Not |
|---|---|---|
| `PORT` | `8080` | |
| `HOST` | `0.0.0.0` | |
| `RELAY_AUTH_TOKEN` | — | **prod'da zorunlu**. Boşsa: `ALLOW_NO_AUTH=true` değilse başlangıçta hata ver. |
| `ALLOW_NO_AUTH` | `false` | sadece localhost dev kolaylığı |
| `MAX_PEERS_PER_ROOM` | `2` | |
| `MAX_PAYLOAD_BYTES` | `262144` | 256 KB; `ws.maxPayload` ile de zorlanır |
| `PING_INTERVAL_MS` | `30000` | ws-level heartbeat |
| `JOIN_TIMEOUT_MS` | `10000` | |
| `RATE_LIMIT_MSGS` | `120` | bağlantı başına pencere içi mesaj |
| `RATE_LIMIT_WINDOW_MS` | `10000` | |
| `LOG_LEVEL` | `info` | |

## Korumalar & güvenlik

- `ws.maxPayload` (büyük frame otomatik düşer) + boyut kontrolü.
- Bağlantı başına **sliding-window rate limit**; aşımda `error{code:"rate-limit"}` + close.
- Geçersiz JSON / bilinmeyen `t` → yok say (sayaçla; tekrarlarsa close).
- **Slow consumer**: peer'ın `bufferedAmount` eşiği aşılırsa mesaj drop / bağlantı close.
- ws-level `ping`/`pong` ile ölü bağlantı temizliği (`PING_INTERVAL_MS`).
- `RELAY_AUTH_TOKEN` timing-safe (`crypto.timingSafeEqual`).
- **E2E gizlilik:** `nonce`/`ct` asla parse/log edilmez. Loglar yapısal (pino), yalnız oda/bağlantı olayları. **Pano içeriği hiçbir şekilde loglanmaz.**
- **Graceful shutdown:** `SIGTERM`/`SIGINT` → yeni bağlantı alma, socket'leri `1001` ile kapat, http kapat, çık.

## Dosya yapısı

```
server/
  src/
    index.ts       # bootstrap: config -> http -> ws -> sinyal işleme
    config.ts      # env parse + default + doğrulama
    relay.ts       # Room registry + join/clip/leave/presence
    protocol.ts    # mesaj tipleri + elle yazılmış type guard'lar (zod yok)
    heartbeat.ts   # ws ping/pong canlılık + ölü bağlantı temizliği
    ratelimit.ts   # bağlantı başına sliding-window
    logger.ts      # pino (içerik ASLA loglanmaz)
  scripts/
    smoke.ts       # iki WS client ile uçtan uca forward + no-echo doğrulama
  package.json · tsconfig.json · .env.example
  Dockerfile · docker-compose.yml · .dockerignore · README.md
```

Bağımlılıklar: runtime `ws` + `pino`; dev `typescript`, `tsx`, `@types/node`, `@types/ws`, `pino-pretty`.

## Docker

- **Multi-stage**: builder (tüm deps + `tsc` → `dist/`) → runtime `node:22-alpine`, sadece prod deps + `dist`, **non-root `node`**, `EXPOSE $PORT`, `HEALTHCHECK` busybox `wget -qO- http://localhost:$PORT/health`, `CMD ["node","dist/index.js"]`.
- **docker-compose.yml**: tek `relay` servisi, `env_file: .env`, `restart: unless-stopped`, port mapping, healthcheck. TLS dışarıda → compose'da proxy yok.
- README: localhost çalıştırma, env tablosu, mevcut proxy arkasına koyma (Caddy/Nginx WebSocket upgrade forward snippet'leri).

## Test / doğrulama

`scripts/smoke.ts`: iki client (`android`+`mac`) aynı odaya join olur, biri `clip` yollar; diğeri aldı mı + gönderene echo gelmedi mi doğrular. `npm run smoke`.

## Kapsam dışı (YAGNI)

- Mesaj kalıcılığı / geçmiş (clipboard "son yazan kazanır").
- `sync-request` (nice-to-have, sonra).
- Çoklu oda yönetim paneli / metrics dashboard.
- Mobil/Swift WS client entegrasyonu (ayrı iş — bu doküman sadece relay).
