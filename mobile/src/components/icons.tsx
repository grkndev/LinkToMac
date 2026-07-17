import { Asset } from 'expo-asset';
import { createContext, useContext, useEffect, useState, type ReactNode } from 'react';

/**
 * Material XML vector drawables (see assets/icons), rendered by the `@expo/ui` `Icon`.
 *
 * @expo/ui's `Icon` loads each source asynchronously *per mount* via its own OkHttpClient,
 * which has no cache (see VectorIconLoader / ExpoUIModule). In dev that means a fresh HTTP
 * round-trip to Metro every time a screen mounts → icons visibly pop in ~1s late on every
 * navigation. To avoid the network entirely we download each XML once at boot and hand the
 * `Icon` a local `file://` URI; the native loader then reads it straight off disk (no HTTP,
 * no cache dependency, identical parse path). Same code path works in release builds too.
 */
const MODULES = {
  // Home
  settings: require('../../assets/icons/settings.xml'),
  laptop: require('../../assets/icons/laptop_mac.xml'),
  lock: require('../../assets/icons/lock.xml'),
  send: require('../../assets/icons/send.xml'),
  cast: require('../../assets/icons/cast.xml'),
  folder: require('../../assets/icons/folder_open.xml'),
  clipboard: require('../../assets/icons/content_paste.xml'),
  sensors: require('../../assets/icons/sensors.xml'),
  // Settings
  search: require('../../assets/icons/search.xml'),
  chevronRight: require('../../assets/icons/chevron_right.xml'),
  notifications: require('../../assets/icons/notifications.xml'),
  notificationsActive: require('../../assets/icons/notifications_active.xml'),
  apps: require('../../assets/icons/apps.xml'),
  chat: require('../../assets/icons/chat.xml'),
  contentCopy: require('../../assets/icons/content_copy.xml'),
  image: require('../../assets/icons/image.xml'),
  battery: require('../../assets/icons/battery_charging_full.xml'),
  qr: require('../../assets/icons/qr_code_scanner.xml'),
  linkOff: require('../../assets/icons/link_off.xml'),
  terminal: require('../../assets/icons/terminal.xml'),
  // About
  info: require('../../assets/icons/info.xml'),
  mail: require('../../assets/icons/mail.xml'),
  code: require('../../assets/icons/code.xml'),
  person: require('../../assets/icons/account_circle.xml'),
  openInNew: require('../../assets/icons/open_in_new.xml'),
  sourcenotes: require('../../assets/icons/source_notes.xml'),
  update: require('../../assets/icons/update.xml'),
} as const;

export type IconName = keyof typeof MODULES;

/** A source `@expo/ui` `Icon` accepts: a `require()`d module (number) or a resolved URI. */
export type IconSource = number | { uri: string };

export type IconMap = Record<IconName, IconSource>;

const NAMES = Object.keys(MODULES) as IconName[];

/** Before warm-up completes, fall back to the raw module (HTTP in dev) so icons still render. */
const INITIAL: IconMap = Object.fromEntries(NAMES.map((n) => [n, MODULES[n]])) as IconMap;

const IconsContext = createContext<IconMap>(INITIAL);

/** Resolved icon sources — local `file://` URIs once warmed, raw modules until then. */
export function useIcons(): IconMap {
  return useContext(IconsContext);
}

/**
 * Dev-only warm-up: downloads every icon XML to the on-device cache once, then swaps the map over
 * to local `file://` URIs so subsequent screen mounts read icons off disk instead of refetching
 * them from Metro (the per-mount HTTP round-trip only happens in development).
 *
 * In release there is no Metro server: the raw `require()` modules in `INITIAL` resolve to the
 * bundled drawables that `@expo/ui`'s `Icon` loads natively — that's the supported path. Swapping
 * them for cache `file://` URIs there instead leaves every icon blank, so we skip the warm-up
 * entirely outside dev and keep the bundled modules.
 */
export function IconsProvider({ children }: { children: ReactNode }) {
  const [icons, setIcons] = useState<IconMap>(INITIAL);

  useEffect(() => {
    if (!__DEV__) return;
    let cancelled = false;
    Asset.loadAsync(NAMES.map((n) => MODULES[n]))
      .then((assets) => {
        if (cancelled) return;
        const next = { ...INITIAL };
        NAMES.forEach((n, i) => {
          const uri = assets[i]?.localUri;
          if (uri) next[n] = { uri };
        });
        setIcons(next);
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, []);

  return <IconsContext.Provider value={icons}>{children}</IconsContext.Provider>;
}
