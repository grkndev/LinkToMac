import { getMaterialColors, isDynamicColorAvailable, type MaterialColors } from '@expo/ui/jetpack-compose';
import type { ReactNode } from 'react';
import { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react';
import { Appearance as RNAppearance, useColorScheme } from 'react-native';

import {
  DEFAULT_APPEARANCE,
  SEEDS,
  loadAppearance,
  saveAppearance,
  type Appearance,
  type ThemeColor,
  type ThemeMode,
} from './appearance-store';

type AppearanceContextValue = {
  /** false until the SecureStore read settles (the root layout holds Booting until then). */
  ready: boolean;
  mode: ThemeMode;
  /** The *effective* colour: a persisted `dynamic` falls back to blue where wallpaper colour is unavailable. */
  color: ThemeColor;
  /**
   * Seed for the Material 3 palette; `undefined` means "use the wallpaper palette" (dynamic colour).
   * Pass it straight to `getMaterialColors({ seedColor })` / `<Host seedColor>`.
   */
  seedColor: string | undefined;
  /**
   * The resolved Material 3 palette for the current scheme + seed. Computed ONCE here (one native
   * `getMaterialColors` call per theme change) and shared through context — `useM3Colors()` used
   * to make its own synchronous native call in each of ~22 call sites on every mount.
   */
  colors: MaterialColors;
  /** Whether the "System" (wallpaper) colour can be offered on this device. */
  dynamicAvailable: boolean;
  setMode: (mode: ThemeMode) => void;
  setColor: (color: ThemeColor) => void;
};

const FALLBACK: AppearanceContextValue = {
  colors: getMaterialColors({ scheme: 'light', seedColor: SEEDS.blue }),
  ready: false,
  mode: DEFAULT_APPEARANCE.mode,
  color: DEFAULT_APPEARANCE.color,
  seedColor: SEEDS.blue,
  dynamicAvailable: isDynamicColorAvailable,
  setMode: () => {},
  setColor: () => {},
};

const AppearanceContext = createContext<AppearanceContextValue>(FALLBACK);

/**
 * App-wide theme preference: light/dark/system plus the accent colour.
 *
 * Mode is applied with `Appearance.setColorScheme`, which RN reflects into every
 * `useColorScheme()` — so the Compose `Host`s, the navigation theme, the StatusBar and the
 * M3 palette hook all follow without each call site knowing about the preference. `'unspecified'`
 * hands control back to the system. The colour only changes the palette seed (see `useM3Colors`).
 */
export function AppearanceProvider({ children }: { children: ReactNode }) {
  const [value, setValue] = useState<Appearance | undefined>(undefined);

  useEffect(() => {
    // A failed read must not strand the app on Booting: fall back to the defaults.
    loadAppearance()
      .then(setValue)
      .catch(() => setValue(DEFAULT_APPEARANCE));
  }, []);

  const mode = value?.mode ?? DEFAULT_APPEARANCE.mode;
  useEffect(() => {
    if (!value) return;
    RNAppearance.setColorScheme(mode === 'system' ? 'unspecified' : mode);
  }, [value, mode]);

  const update = useCallback((patch: Partial<Appearance>) => {
    setValue((prev) => {
      const next = { ...(prev ?? DEFAULT_APPEARANCE), ...patch };
      saveAppearance(next).catch(() => {});
      return next;
    });
  }, []);

  const setMode = useCallback((m: ThemeMode) => update({ mode: m }), [update]);
  const setColor = useCallback((c: ThemeColor) => update({ color: c }), [update]);

  const scheme = useColorScheme() === 'dark' ? 'dark' : 'light';

  const ctx = useMemo<AppearanceContextValue>(() => {
    const saved = value?.color ?? DEFAULT_APPEARANCE.color;
    const color = saved === 'dynamic' && !isDynamicColorAvailable ? 'blue' : saved;
    const seedColor = color === 'dynamic' ? undefined : SEEDS[color];
    return {
      ready: value !== undefined,
      mode,
      color,
      seedColor,
      colors: getMaterialColors({ scheme, seedColor }),
      dynamicAvailable: isDynamicColorAvailable,
      setMode,
      setColor,
    };
  }, [value, mode, scheme, setMode, setColor]);

  return <AppearanceContext.Provider value={ctx}>{children}</AppearanceContext.Provider>;
}

export function useAppearance(): AppearanceContextValue {
  return useContext(AppearanceContext);
}
