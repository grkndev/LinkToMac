// End-to-end smoke test: two clients (android + mac) join one room, verify
// clip forwarding, no-echo-to-sender, and presence. Self-contained (no src imports).
//
//   npm run dev          # in one terminal
//   npm run smoke        # in another (honors PORT / RELAY_AUTH_TOKEN)
//
// Exit code 0 = PASS, 1 = FAIL.
import { WebSocket } from 'ws';

const PORT = process.env.PORT ?? '8080';
const TOKEN = process.env.RELAY_AUTH_TOKEN ?? '';
const ROOM = 'smoke-room-0123456789'; // >= 16 chars
const BEARER_ROOM = 'smoke-bearer-room-0123456789'; // >= 16 chars, distinct from ROOM
const URL = `ws://127.0.0.1:${PORT}/ws${TOKEN ? `?token=${encodeURIComponent(TOKEN)}` : ''}`;
const BEARER_URL = `ws://127.0.0.1:${PORT}/ws`;

type Msg = Record<string, unknown>;

/** `authHeader: true` connects with `Authorization: Bearer <token>` instead of `?token=`, to
 *  cover the auth path the rest of this suite doesn't exercise (index.ts accepts either). */
function client(opts: { authHeader?: boolean } = {}) {
  const ws = opts.authHeader
    ? new WebSocket(BEARER_URL, TOKEN ? { headers: { Authorization: `Bearer ${TOKEN}` } } : undefined)
    : new WebSocket(URL);
  const inbox: Msg[] = [];
  const waiters: { pred: (m: Msg) => boolean; resolve: (m: Msg) => void }[] = [];

  ws.on('message', (data) => {
    // A malformed/non-JSON frame must not crash the smoke harness itself — log and drop it,
    // same as any other client would, rather than letting JSON.parse throw out of the handler.
    let m: Msg;
    try {
      m = JSON.parse(data.toString()) as Msg;
    } catch (err) {
      console.error('  (ignoring non-JSON message):', err instanceof Error ? err.message : err);
      return;
    }
    inbox.push(m);
    for (let i = waiters.length - 1; i >= 0; i--) {
      const w = waiters[i]!;
      if (w.pred(m)) {
        w.resolve(m);
        waiters.splice(i, 1);
      }
    }
  });

  return {
    open: () =>
      new Promise<void>((res, rej) => {
        ws.once('open', () => res());
        ws.once('error', rej);
      }),
    send: (m: Msg) => ws.send(JSON.stringify(m)),
    inbox: () => inbox,
    close: () => ws.close(),
    waitFor: (pred: (m: Msg) => boolean, label: string, timeoutMs = 2000) =>
      new Promise<Msg>((res, rej) => {
        const hit = inbox.find(pred);
        if (hit) return res(hit);
        const timer = setTimeout(() => rej(new Error(`timeout waiting for: ${label}`)), timeoutMs);
        waiters.push({
          pred,
          resolve: (m) => {
            clearTimeout(timer);
            res(m);
          },
        });
      }),
  };
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

function assert(cond: boolean, label: string): void {
  if (!cond) throw new Error(`assertion failed: ${label}`);
  console.log('  ok:', label);
}

async function main(): Promise<void> {
  // Auth: the `?token=` path is exercised by every other client below; cover the
  // `Authorization: Bearer` path separately (only meaningful when a token is configured).
  if (TOKEN) {
    const bearer = client({ authHeader: true });
    await bearer.open();
    bearer.send({ t: 'join', room: BEARER_ROOM, device: 'android' });
    await bearer.waitFor((m) => m.t === 'joined', 'Bearer-header auth joins successfully');
    bearer.close();
  }

  const android = client();
  const mac = client();
  await Promise.all([android.open(), mac.open()]);

  android.send({ t: 'join', room: ROOM, device: 'android' });
  await android.waitFor((m) => m.t === 'joined', 'android joined');

  mac.send({ t: 'join', room: ROOM, device: 'mac' });
  await mac.waitFor((m) => m.t === 'joined', 'mac joined');

  await android.waitFor(
    (m) => m.t === 'peer' && m.state === 'online' && m.device === 'mac',
    'android sees mac online',
  );

  // Vectors mirror what the real codecs emit: nonce = base64 of exactly 12 bytes (16 chars,
  // no padding), ct = valid block-aligned base64 of >= 16 bytes (the Poly1305 tag minimum).
  // The relay validates this shape since the M12 hardening — sloppy vectors get bad-message.
  const CLIP_NONCE = 'Y2xpcG5vbmNlMDAx';
  const CLIP_CT = 'Y2xpcHRleHRjaXBoZXIwMDAx';
  android.send({ t: 'clip', nonce: CLIP_NONCE, ct: CLIP_CT });
  const clip = await mac.waitFor((m) => m.t === 'clip', 'mac receives clip');
  assert(clip.nonce === CLIP_NONCE && clip.ct === CLIP_CT, 'clip payload intact');

  await sleep(300);
  assert(!android.inbox().some((m) => m.t === 'clip'), 'sender received no echo');

  // Notification mirroring (phone -> Mac): opaque `note` frame, same fan-out as clips.
  const NOTE_NONCE = 'bm90ZW5vbmNlMDAx';
  const NOTE_CT = 'bm90ZWNpcGhlcnBheWxvYWQx';
  android.send({ t: 'note', nonce: NOTE_NONCE, ct: NOTE_CT });
  const note = await mac.waitFor((m) => m.t === 'note', 'mac receives note');
  assert(note.nonce === NOTE_NONCE && note.ct === NOTE_CT, 'note payload intact');

  await sleep(300);
  assert(!android.inbox().some((m) => m.t === 'note'), 'note sender received no echo');

  // SMS mirroring (phone -> Mac): opaque `sms` frame, same fan-out as clips.
  const SMS_NONCE = 'c21zbm9uY2UwMDAx';
  const SMS_CT = 'c21zY2lwaGVycGF5bG9hZDAx';
  android.send({ t: 'sms', nonce: SMS_NONCE, ct: SMS_CT });
  const sms = await mac.waitFor((m) => m.t === 'sms', 'mac receives sms');
  assert(sms.nonce === SMS_NONCE && sms.ct === SMS_CT, 'sms payload intact');

  await sleep(300);
  assert(!android.inbox().some((m) => m.t === 'sms'), 'sms sender received no echo');

  // File transfer (Mac -> phone clipboard image): opaque `file` frame, same fan-out.
  // A ~910 KiB block-aligned ct proves the 1 MiB maxPayload accepts image-sized frames
  // (932,000 b64 chars = 699,000 raw bytes — the fitImage/ImagePrep budget's ballpark).
  const FILE_NONCE = 'ZmlsZW5vbmNlMDAx';
  const bigCt = 'QUJD'.repeat(233_000);
  mac.send({ t: 'file', nonce: FILE_NONCE, ct: bigCt });
  const file = await android.waitFor((m) => m.t === 'file', 'android receives file');
  assert(file.nonce === FILE_NONCE && file.ct === bigCt, 'file payload intact');

  await sleep(300);
  assert(!mac.inbox().some((m) => m.t === 'file'), 'file sender received no echo');

  // Frame validation: a nonce that isn't 12 base64 bytes must be rejected, not forwarded.
  android.send({ t: 'clip', nonce: 'dG9vc2hvcnQ=', ct: CLIP_CT });
  await android.waitFor(
    (m) => m.t === 'error' && m.code === 'bad-message',
    'malformed nonce rejected with bad-message',
  );
  await sleep(300);
  assert(
    mac.inbox().filter((m) => m.t === 'clip').length === 1,
    'malformed clip was not forwarded',
  );

  mac.close();
  await android.waitFor(
    (m) => m.t === 'peer' && m.state === 'offline' && m.device === 'mac',
    'android sees mac offline',
  );

  android.close();
  console.log('\nSMOKE PASS');
  process.exit(0);
}

main().catch((err: unknown) => {
  console.error('\nSMOKE FAIL:', err instanceof Error ? err.message : err);
  process.exit(1);
});
