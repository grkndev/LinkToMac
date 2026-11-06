/**
 * The app's typefaces: Google Sans Flex for UI text and JetBrains Mono for code/logs/ids (the
 * redesign mockup's pairing). Both ship as STATIC instances (one file per weight) from the
 * `@expo-google-fonts/*` packages and are registered at boot with expo-font's runtime loader.
 *
 * Why static + a family per weight: `@expo/ui`'s Compose `Text` resolves a custom `fontFamily`
 * through React Native's `ReactFontManager` as a ready-made Typeface, and Compose does NOT apply
 * `fontWeight` on top of such a family (nor can it pick a weight from a variable font loaded this
 * way). So the weight has to be chosen by family NAME — see `resolveFontFamily`, used by the
 * `Text` wrapper in `src/components/text.tsx`.
 */

export const SANS = {
  regular: 'GoogleSansFlex-Regular',
  medium: 'GoogleSansFlex-Medium',
  semibold: 'GoogleSansFlex-SemiBold',
  bold: 'GoogleSansFlex-Bold',
} as const;

export const MONO = {
  regular: 'JetBrainsMono-Regular',
  medium: 'JetBrainsMono-Medium',
} as const;

/** Passed to `useFonts` (expo-font) in the root layout. Keys are the family names above. */
export const FONT_ASSETS = {
  [SANS.regular]: require('@expo-google-fonts/google-sans-flex/400Regular/GoogleSansFlex_400Regular.ttf'),
  [SANS.medium]: require('@expo-google-fonts/google-sans-flex/500Medium/GoogleSansFlex_500Medium.ttf'),
  [SANS.semibold]: require('@expo-google-fonts/google-sans-flex/600SemiBold/GoogleSansFlex_600SemiBold.ttf'),
  [SANS.bold]: require('@expo-google-fonts/google-sans-flex/700Bold/GoogleSansFlex_700Bold.ttf'),
  [MONO.regular]: require('@expo-google-fonts/jetbrains-mono/400Regular/JetBrainsMono_400Regular.ttf'),
  [MONO.medium]: require('@expo-google-fonts/jetbrains-mono/500Medium/JetBrainsMono_500Medium.ttf'),
};

type Weight = 'normal' | 'bold' | '100' | '200' | '300' | '400' | '500' | '600' | '700' | '800' | '900';

/** Weight each Material 3 typography role carries when the caller doesn't set `fontWeight`. */
const TYPOGRAPHY_WEIGHT: Record<string, Weight> = {
  titleMedium: '500',
  titleSmall: '500',
  labelLarge: '500',
  labelMedium: '500',
  labelSmall: '500',
};

function numeric(w: Weight | undefined): number {
  if (w === undefined || w === 'normal') return 400;
  if (w === 'bold') return 700;
  return Number(w);
}

export function sansForWeight(w: number): string {
  if (w >= 700) return SANS.bold;
  if (w >= 600) return SANS.semibold;
  if (w >= 500) return SANS.medium;
  return SANS.regular;
}

/**
 * The family a `Text` should render in, from its style: an explicit custom family wins; `monospace`
 * becomes JetBrains Mono; anything else is Google Sans Flex at the weight the style (or its
 * typography role) asks for.
 */
export function resolveFontFamily(style: {
  fontFamily?: string;
  fontWeight?: Weight;
  typography?: string;
} | undefined): string {
  const family = style?.fontFamily;
  const weight = numeric(style?.fontWeight ?? (style?.typography ? TYPOGRAPHY_WEIGHT[style.typography] : undefined));
  if (family === 'monospace') return weight >= 500 ? MONO.medium : MONO.regular;
  if (family && family !== 'default' && family !== 'sansSerif') return family; // already a custom family
  return sansForWeight(weight);
}
