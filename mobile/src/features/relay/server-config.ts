import * as SecureStore from 'expo-secure-store';

const STORAGE_KEY = 'linktomac.server';

/**
 * Relay/server connection settings, decoupled from the pairing (room/key in pairing-store.ts).
 * Seeded from the Mac's QR (v2) and editable in Settings -> Relay server.
 *
 * - `secure` selects `ws://` (false) vs `wss://` (true).
 * - `token` is the shared, operator-defined relay password (sent as the `Bearer` header). It
 *   replaces the old build-baked RELAY_TOKEN; it travels in the QR alongside the E2E key.
 * - `certFingerprint` is reserved for the future relay-less LAN-direct mode: pin a self-signed
 *   server cert (a public-CA relay leaves it unset). Carrying it now keeps that path a drop-in.
 */
export type ServerConfig = {
  host: string;
  port: number;
  secure: boolean;
  token: string;
  certFingerprint?: string;
};

export async function loadServerConfig(): Promise<ServerConfig | null> {
  const raw = await SecureStore.getItemAsync(STORAGE_KEY);
  if (!raw) return null;
  try {
    const obj = JSON.parse(raw) as Partial<ServerConfig>;
    if (typeof obj.host === 'string' && obj.host.length > 0 && typeof obj.port === 'number') {
      return {
        host: obj.host,
        port: obj.port,
        secure: typeof obj.secure === 'boolean' ? obj.secure : true,
        token: typeof obj.token === 'string' ? obj.token : '',
        ...(typeof obj.certFingerprint === 'string' ? { certFingerprint: obj.certFingerprint } : {}),
      };
    }
  } catch {
    // fall through
  }
  return null;
}

export async function saveServerConfig(config: ServerConfig): Promise<void> {
  await SecureStore.setItemAsync(STORAGE_KEY, JSON.stringify(config));
}

export async function clearServerConfig(): Promise<void> {
  await SecureStore.deleteItemAsync(STORAGE_KEY);
}

/** The `ws://` or `wss://` URL the native relay client connects to. */
export function serverWsUrl(config: ServerConfig): string {
  const scheme = config.secure ? 'wss' : 'ws';
  return `${scheme}://${config.host}:${config.port}/ws`;
}

/**
 * An empty config to seed the Settings form when nothing is saved yet. There is no baked-in
 * server: the relay endpoint comes only from a scanned QR (v2) or this form. `secure`/`port`
 * default to a TLS-first 443 so the common "domain + Let's Encrypt" case is one toggle away.
 */
export function blankServerConfig(): ServerConfig {
  return { host: '', port: 443, secure: true, token: '' };
}
