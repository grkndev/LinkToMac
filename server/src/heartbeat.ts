import type { WebSocket } from 'ws';

export interface Heartbeatable {
  ws: WebSocket;
  isAlive: boolean;
}

/**
 * ws-level liveness check. Every `intervalMs` it terminates connections that
 * didn't answer the previous ping, then pings the rest. Each `pong` handler
 * (registered by the caller) flips `isAlive` back to true.
 *
 * Returns a stop function that clears the interval.
 */
export function startHeartbeat(
  conns: () => Iterable<Heartbeatable>,
  intervalMs: number,
): () => void {
  const timer = setInterval(() => {
    for (const conn of conns()) {
      if (!conn.isAlive) {
        conn.ws.terminate();
        continue;
      }
      conn.isAlive = false;
      conn.ws.ping();
    }
  }, intervalMs);
  timer.unref();
  return () => clearInterval(timer);
}
