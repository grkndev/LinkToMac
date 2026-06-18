import * as SecureStore from 'expo-secure-store';

const STORAGE_KEY = 'linktomac.server';

/**
 * Relay/server connection settings, decoupled from the pairing (room/key in pairing-store.ts).
 * Seeded from the Mac's QR (v2) and editable in Settings -> Relay server.
 *
 * - `secure` selects `ws://` (false) vs `wss://` (true).
 * - `token` is the shared, operator-defined relay password (sent as the `Bearer` header). It
 *   replaces the old build-baked RELAY_TOKEN; it travels in the QR alongside the E2E key.
 * - `certFingerprint` is reserved for a future pinned-TLS LAN variant (unused today).
 *
 * LAN-direct fields (relay-less, same network — the Mac runs a WebSocket server):
 * - `lanEnabled` (default true) turns the LAN path on; `lanPort` is the Mac's LAN WS port
 *   (0/undefined = off). The Mac is found over mDNS; `lanHost` is an optional manual seed for
 *   networks that block mDNS. With LAN enabled and `host` empty, the app is LAN-only (no relay).
 */
export type ServerConfig = {
  host: string;
  port: number;
  secure: boolean;
  token: string;
  certFingerprint?: string;
  lanEnabled?: boolean;
  lanPort?: number;
  lanHost?: string;
};

export async function loadServerConfig(): Promise<ServerConfig | null> {
  const raw = await SecureStore.getItemAsync(STORAGE_KEY);
  if (!raw) return null;
  try {
    const obj = JSON.parse(raw) as Partial<ServerConfig>;
    const host = typeof obj.host === 'string' ? obj.host : '';
    const lanPort = typeof obj.lanPort === 'number' ? obj.lanPort : undefined;
    // Usable if there's a relay host OR a LAN port (LAN-only is valid).
    if (host.length > 0 || (lanPort && lanPort > 0)) {
      return {
        host,
        port: typeof obj.port === 'number' ? obj.port : 443,
        secure: typeof obj.secure === 'boolean' ? obj.secure : true,
        token: typeof obj.token === 'string' ? obj.token : '',
        lanEnabled: typeof obj.lanEnabled === 'boolean' ? obj.lanEnabled : true,
        ...(lanPort ? { lanPort } : {}),
        ...(typeof obj.lanHost === 'string' && obj.lanHost.length > 0 ? { lanHost: obj.lanHost } : {}),
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

/** Whether a relay endpoint is configured (vs LAN-only). */
export function hasRelay(config: ServerConfig | null): boolean {
  return !!config && config.host.trim().length > 0;
}

/**
 * The native `setRelay(...)` connection args derived from a ServerConfig. `url` is empty for
 * LAN-only; the LAN trio drives the relay-less path (port 0 = LAN off).
 */
export function connectionArgs(config: ServerConfig | null): {
  url: string;
  token: string;
  lanEnabled: boolean;
  lanPort: number;
  lanHost: string | null;
} {
  return {
    url: hasRelay(config) ? serverWsUrl(config!) : '',
    token: config?.token ?? '',
    lanEnabled: config?.lanEnabled ?? true,
    lanPort: config?.lanPort ?? 0,
    lanHost: config?.lanHost ?? null,
  };
}

/**
 * An empty config to seed the Settings form when nothing is saved yet. There is no baked-in
 * server: the relay endpoint comes only from a scanned QR (v2) or this form. `secure`/`port`
 * default to a TLS-first 443 so the common "domain + Let's Encrypt" case is one toggle away.
 */
export function blankServerConfig(): ServerConfig {
  return { host: '', port: 443, secure: true, token: '', lanEnabled: true, lanPort: 53124 };
}
