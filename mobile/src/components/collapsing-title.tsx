import { useNavigation } from "expo-router";
import { useCallback, useLayoutEffect, useRef, useState } from "react";
import { Animated } from "react-native";

import { useM3Colors } from "@/components/m3";
import { SANS } from "@/constants/typography";

/** Where the large title sits, in window dp (what `onGloballyPositioned` reports). */
export type TitleLayout = { x: number; y: number; width: number; height: number };

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
 * The value is fed from JS (`setValue`) into a native-driven style, so the animation itself runs on
 * the UI thread; the only latency is the event's hop through JS (about a frame).
 *
 * Pass the returned handler to `<LargeTitle onLayoutChange={…}>`.
 */
export function useCollapsingTitle(title: string): (layout: TitleLayout) => void {
  const navigation = useNavigation();
  const colors = useM3Colors();
  const [progress] = useState(() => new Animated.Value(0));
  // Resting (scroll 0) window `y` of the title: the highest it has ever been. Overscroll or a late
  // layout can only raise it, which is the right direction to correct in.
  const restY = useRef<number | null>(null);

  useLayoutEffect(() => {
    navigation.setOptions({
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

  return useCallback(
    ({ y, height }: TitleLayout) => {
      if (restY.current === null || y > restY.current) restY.current = y;
      const scrolled = restY.current - y;
      // Start once ~30% of the title is gone, finished when ~85% is — so the header text arrives
      // as the big one leaves, not before it has begun to.
      const from = height * 0.3;
      const to = height * 0.85;
      progress.setValue(Math.min(1, Math.max(0, (scrolled - from) / (to - from))));
    },
    [progress],
  );
}
