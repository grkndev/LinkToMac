import * as SecureStore from 'expo-secure-store';

const STORAGE_KEY = 'linktomac.appearance';

/** Light/dark behaviour: follow the system, or force one. */
export type ThemeMode = 'system' | 'light' | 'dark';

/**
 * The accent colour the whole Material 3 palette is generated from.
 * `dynamic` = the device wallpaper palette (Material You, Android 12+); the rest are fixed seeds
 * fed to `SchemeTonalSpot`, so they work on every API level.
 */
export type ThemeColor = 'dynamic' | 'blue' | 'teal' | 'violet' | 'rose' | 'amber';

export type Appearance = { mode: ThemeMode; color: ThemeColor };

/**
 * Seed per fixed colour. `blue` is the brand blue (also the notification accent in app.json) and the
 * pre-theming default, so existing installs look unchanged. The others are the hues of the redesign
 * mockup (teal 195 / violet 300 / rose 10 / amber 70) at a chroma high enough for the tonal palette.
 */
export const SEEDS: Record<Exclude<ThemeColor, 'dynamic'>, string> = {
  blue: '#208AEF',
  teal: '#009B9E',
  violet: '#9065D0',
  rose: '#CC4F6A',
  amber: '#BB6A00',
};

export const COLOR_LABELS: Record<ThemeColor, string> = {
  dynamic: 'System',
  blue: 'Blue',
  teal: 'Teal',
  violet: 'Violet',
  rose: 'Rose',
  amber: 'Amber',
};

export const DEFAULT_APPEARANCE: Appearance = { mode: 'system', color: 'blue' };

const MODES: readonly ThemeMode[] = ['system', 'light', 'dark'];
const COLORS: readonly ThemeColor[] = ['dynamic', 'blue', 'teal', 'violet', 'rose', 'amber'];

export async function loadAppearance(): Promise<Appearance> {
  const raw = await SecureStore.getItemAsync(STORAGE_KEY);
  if (!raw) return DEFAULT_APPEARANCE;
  try {
    const obj = JSON.parse(raw) as Partial<Appearance>;
    return {
      mode: MODES.includes(obj.mode as ThemeMode) ? (obj.mode as ThemeMode) : DEFAULT_APPEARANCE.mode,
      color: COLORS.includes(obj.color as ThemeColor) ? (obj.color as ThemeColor) : DEFAULT_APPEARANCE.color,
    };
  } catch {
    return DEFAULT_APPEARANCE;
  }
}

export async function saveAppearance(a: Appearance): Promise<void> {
  await SecureStore.setItemAsync(STORAGE_KEY, JSON.stringify(a));
}
