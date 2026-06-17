import type { ConfigContext, ExpoConfig } from 'expo/config';

/**
 * Dynamic config layered on top of app.json. The relay endpoint is no longer baked in: the
 * server address, port, TLS and password come at runtime from the Mac's pairing QR (v2) or
 * Settings -> Relay server (persisted via expo-secure-store; see server-config.ts).
 */
export default ({ config }: ConfigContext): ExpoConfig => ({
  ...config,
  name: config.name ?? 'LinkToMac',
  slug: config.slug ?? 'linktomac',
});
