import { useNavigation } from "expo-router";
import { useCallback, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { Animated, View } from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";

import { useM3Colors } from "@/components/m3";
import { SANS } from "@/constants/typography";

/** Where the large title sits, in window dp (what `onGloballyPositioned` reports). */
export type TitleLayout = { x: number; y: number; width: number; height: number };

/** Eased fade stops (position %, alpha): solid at the top edge, gone at the bottom. */
const FADE_STOPS: readonly (readonly [number, number])[] = [
  [0, 1],
  [25, 0.97],
  [45, 0.85],
  [65, 0.55],
  [85, 0.2],
  [100, 0],
];

/**
 * Top-to-bottom CSS gradient from the theme background to the SAME colour at zero alpha (not the
 * `transparent` keyword, which is black at 0 and can leave a grey fringe mid-fade). Eased through
 * several stops: a plain two-stop gradient shows a visible edge where the fade begins.
 */
function headerGradient(color: string): string {
  const hex = color.replace("#", "");
  const [r, g, b] = [0, 2, 4].map((i) => parseInt(hex.slice(i, i + 2), 16));
  const a = hex.length >= 8 ? parseInt(hex.slice(6, 8), 16) / 255 : 1;
  const stops = FADE_STOPS.map(([pos, alpha]) => `rgba(${r}, ${g}, ${b}, ${(alpha * a).toFixed(3)}) ${pos}%`);
  return `linear-gradient(to bottom, ${stops.join(", ")})`;
}

/** Height of the soft fade BELOW the (solid) toolbar. */
const FADE_HEIGHT = 28;

/** The Android toolbar height react-native-screens (and expo-router's own `defaultHeaderHeight`) assume. */
const TOOLBAR_HEIGHT = 56;

/**
 * Collapsing large title for screens that draw a `LargeTitle` in the body under a title-less native
 * header (Settings, Notifications): as the big title scrolls away, the same text slides + fades
 * into the header next to the back arrow — scrubbed by the scroll position, not timed.
 *
 * Compose exposes no scroll offset, but the title's own window position IS the scroll offset: it
 * only moves because the column scrolls. `LargeTitle` reports it (`onGloballyPositioned`, which
 * Compose re-fires as the node is re-placed during a scroll); the largest `y` seen is the resting
 * position, and `restY - y` is how far we've scrolled. That maps to an `Animated.Value` (0 → 1)
 * driving the header title's opacity + translateY. The header title is set ONCE through
 * `setOptions` and only ever driven by the value, so scrolling never re-renders it.
 *
 * The header is also made transparent, and the screen paints its own cover over the header area:
 * solid `background` across the status bar + toolbar (so the title and back arrow never sit over
 * scrolling content), then a soft gradient fading to transparent just BELOW the toolbar, so content
 * sliding up dissolves instead of being cut at a hard edge. The fade strip's opacity follows the
 * scroll (0 at rest → 1 after `FADE_HEIGHT`), because at rest the large title sits right under the
 * toolbar and must not be faded. A translucent native header lets the body extend underneath, and
 * the cover lives inside the screen because navigation's `headerBackground` is drawn BEHIND the
 * screen content, i.e. behind our opaque Compose Host. Because the body now starts at the top of the
 * screen, `topInset` (status bar + toolbar) must be added to the body's top padding.
 *
 * The value is fed from JS (`setValue`) into a native-driven style, so the animation itself runs on
 * the UI thread; the only latency is the event's hop through JS (about a frame).
 *
 * Wire it up: `onTitleLayout` → `<LargeTitle onLayoutChange>`, `topInset` → the body's top padding,
 * and render `backdrop` (the cover) as a sibling AFTER the body so it draws above it.
 */
export function useCollapsingTitle(title: string): {
  onTitleLayout: (layout: TitleLayout) => void;
  topInset: number;
  backdrop: ReactNode;
} {
  const navigation = useNavigation();
  const colors = useM3Colors();
  const insets = useSafeAreaInsets();
  const topInset = insets.top + TOOLBAR_HEIGHT;
  const [progress] = useState(() => new Animated.Value(0));
  const [fadeOpacity] = useState(() => new Animated.Value(0));
  // Resting (scroll 0) window `y` of the title: the highest it has ever been. Overscroll or a late
  // layout can only raise it, which is the right direction to correct in.
  const restY = useRef<number | null>(null);

  useLayoutEffect(() => {
    navigation.setOptions({
      // `headerStyle.backgroundColor` wins over `headerTransparent`, so clear it explicitly.
      headerTransparent: true,
      headerStyle: { backgroundColor: "transparent" },
      headerShadowVisible: false,
      headerTitle: () => (
        <Animated.Text
          numberOfLines={1}
          style={{
            color: colors.onSurface,
            fontFamily: SANS.regular,
            fontSize: 22,
            opacity: progress,
            transform: [
              { translateY: progress.interpolate({ inputRange: [0, 1], outputRange: [14, 0] }) },
            ],
          }}
        >
          {title}
        </Animated.Text>
      ),
    });
  }, [navigation, progress, title, colors.onSurface]);

  const onTitleLayout = useCallback(
    ({ y, height }: TitleLayout) => {
      if (restY.current === null || y > restY.current) restY.current = y;
      const scrolled = restY.current - y;
      // Start once ~30% of the title is gone, finished when ~85% is — so the header text arrives
      // as the big one leaves, not before it has begun to.
      const from = height * 0.3;
      const to = height * 0.85;
      progress.setValue(Math.min(1, Math.max(0, (scrolled - from) / (to - from))));
      fadeOpacity.setValue(Math.min(1, Math.max(0, scrolled / FADE_HEIGHT)));
    },
    [progress, fadeOpacity],
  );

  const backdrop = (
    <View
      pointerEvents="none"
      style={{ position: "absolute", top: 0, left: 0, right: 0, height: topInset + FADE_HEIGHT }}
    >
      <View style={{ height: topInset, backgroundColor: colors.background }} />
      <Animated.View
        style={{
          height: FADE_HEIGHT,
          opacity: fadeOpacity,
          experimental_backgroundImage: headerGradient(colors.background),
        }}
      />
    </View>
  );

  return { onTitleLayout, topInset, backdrop };
}
