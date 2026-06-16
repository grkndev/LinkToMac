import type { ConfigContext, ExpoConfig } from 'expo/config';

/**
 * Dynamic config layered on top of app.json. Pulls the relay host + token from the
 * environment (the Expo CLI loads .env automatically) into `extra`, so the secret lives in
 * a gitignored .env and never in tracked source. Copy .env.example to .env and fill it in.
 */
export default ({ config }: ConfigContext): ExpoConfig => ({
  ...config,
  name: config.name ?? 'LinkToMac',
  slug: config.slug ?? 'linktomac',
  extra: {
    ...config.extra,
    // RELAY_HOST is optional: when unset the phone falls back to the Metro dev-server host
    // (see relay-config.ts). RELAY_TOKEN must match server/.env RELAY_AUTH_TOKEN.
    relayHost: process.env.RELAY_HOST ?? config.extra?.relayHost,
    relayToken: process.env.RELAY_TOKEN ?? null,
  },
});
