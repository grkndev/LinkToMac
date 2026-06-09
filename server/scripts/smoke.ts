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
const URL = `ws://127.0.0.1:${PORT}/ws${TOKEN ? `?token=${encodeURIComponent(TOKEN)}` : ''}`;

type Msg = Record<string, unknown>;

function client() {
  const ws = new WebSocket(URL);
  const inbox: Msg[] = [];
  const waiters: { pred: (m: Msg) => boolean; resolve: (m: Msg) => void }[] = [];

  ws.on('message', (data) => {
    const m = JSON.parse(data.toString()) as Msg;
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

  android.send({ t: 'clip', nonce: 'bm9uY2U=', ct: 'Y2lwaGVydGV4dA==' });
  const clip = await mac.waitFor((m) => m.t === 'clip', 'mac receives clip');
  assert(clip.nonce === 'bm9uY2U=' && clip.ct === 'Y2lwaGVydGV4dA==', 'clip payload intact');

  await sleep(300);
  assert(!android.inbox().some((m) => m.t === 'clip'), 'sender received no echo');

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
