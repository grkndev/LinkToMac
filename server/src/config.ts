import process from 'node:process';
import env from 'dotenv';

env.config();

export interface Config {
  host: string;
  port: number;
  /** null only when ALLOW_NO_AUTH=true (local dev). */
  authToken: string | null;
  maxPeersPerRoom: number;
  maxPayloadBytes: number;
  pingIntervalMs: number;
  joinTimeoutMs: number;
  rateLimitMsgs: number;
  rateLimitWindowMs: number;
  logLevel: string;
  isProd: boolean;
}

function num(name: string, fallback: number): number {
  const raw = process.env[name];
  if (raw == null || raw === '') return fallback;
  const n = Number(raw);
  if (!Number.isFinite(n) || n <= 0) {
    throw new Error(`Invalid ${name}: "${raw}" (expected a positive number)`);
  }
  return n;
}

function bool(name: string, fallback: boolean): boolean {
  const raw = process.env[name];
  if (raw == null || raw === '') return fallback;
  return raw === 'true' || raw === '1';
}

export function loadConfig(): Config {
  const isProd = process.env.NODE_ENV === 'production';
  const authToken = process.env.RELAY_AUTH_TOKEN?.trim() || null;
  const allowNoAuth = bool('ALLOW_NO_AUTH', false);

  if (!authToken && !allowNoAuth) {
    throw new Error(
      'RELAY_AUTH_TOKEN is not set. Set it (openssl rand -hex 32), or set ALLOW_NO_AUTH=true for local development only.',
    );
  }

  return {
    host: process.env.HOST?.trim() || '0.0.0.0',
    port: num('PORT', 8080),
    authToken,
    maxPeersPerRoom: num('MAX_PEERS_PER_ROOM', 2),
    maxPayloadBytes: num('MAX_PAYLOAD_BYTES', 262144),
    pingIntervalMs: num('PING_INTERVAL_MS', 30000),
    joinTimeoutMs: num('JOIN_TIMEOUT_MS', 10000),
    rateLimitMsgs: num('RATE_LIMIT_MSGS', 120),
    rateLimitWindowMs: num('RATE_LIMIT_WINDOW_MS', 10000),
    logLevel: process.env.LOG_LEVEL?.trim() || 'info',
    isProd,
  };
}
