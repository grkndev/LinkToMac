import { useEffect, useState } from "react";
import { Animated, Easing, StyleSheet, View } from "react-native";

import { Glyph, K, PALETTE, type LayerStyles, type Scheme } from "@/components/boot-scene";
import {
  SPLASH_MS,
  SPLASH_STORYBOARD as S,
} from "@/features/boot/splash-storyboard.generated";

/**
 * The splash's 1 s intro, replayed in-app (dev preview only — app/preview.tsx). The REAL splash is the native
 * AnimatedVectorDrawable and can't be replayed without a cold start; this runs the same storyboard (generated
 * by scripts/build-brand-assets.mjs from one table, so it can't drift) on the same four layers, over the same
 * background, at the same size and position. Plays once and holds its last frame, which is exactly the boot frame.
 *
 * Remount it (change its `key`) to replay.
 */

type Frames = readonly (readonly [number, number])[];

/** The AVD's per-segment interpolator (`fast_out_slow_in`). The native driver ignores `easing` on
 *  `interpolate`, so each segment is sampled into a few extra points instead. */
const SEGMENT_EASE = Easing.bezier(0.4, 0, 0.2, 1);
const SUBSTEPS = 8;

function curve(frames: Frames, scale = 1, min = -Infinity): [number, number][] {
  const last = frames[frames.length - 1];
  const f: Frames = last[0] < 1 ? [...frames, [1, last[1]] as const] : frames; // always end at fraction 1
  const at = (v: number) => Math.max(v * scale, min);
  const pts: [number, number][] = [[f[0][0], at(f[0][1])]];
  for (let i = 1; i < f.length; i++) {
    const [t0, v0] = f[i - 1];
    const [t1, v1] = f[i];
    for (let s = 1; s <= SUBSTEPS; s++) {
      const u = s / SUBSTEPS;
      pts.push([t0 + (t1 - t0) * u, at(v0 + (v1 - v0) * SEGMENT_EASE(u))]);
    }
  }
  return pts;
}

export function SplashIntro({ scheme }: { scheme: Scheme }) {
  const [p] = useState(() => new Animated.Value(0));
  const [layers] = useState<LayerStyles>(() => {
    const track = (frames: Frames, scale = 1, min = -Infinity) => {
      const pts = curve(frames, scale, min);
      return p.interpolate({ inputRange: pts.map((x) => x[0]), outputRange: pts.map((x) => x[1]) });
    };
    // Scales never reach exactly 0: a zero matrix is a needless edge case for the native view.
    return {
      laptop: { opacity: track(S.laptopAlpha), transform: [{ scale: track(S.laptopScale, 1, 0.001) }] },
      base: { transform: [{ scaleX: track(S.baseScaleX, 1, 0.001) }] },
      arrowTop: { opacity: track(S.arrowTopAlpha), transform: [{ translateX: track(S.arrowTopX, K) }] },
      arrowBottom: { opacity: track(S.arrowBottomAlpha), transform: [{ translateX: track(S.arrowBottomX, K) }] },
      // The app name slides down out of its mask (the clipping strip is inside <Glyph>); no opacity — the clip hides it.
      wordmark: { transform: [{ translateY: track(S.wordmarkY, K) }] },
    };
  });

  useEffect(() => {
    const run = Animated.timing(p, {
      toValue: 1,
      duration: SPLASH_MS,
      easing: Easing.linear,
      useNativeDriver: true,
    });
    run.start();
    return () => run.stop();
  }, [p]);

  return (
    <View style={[StyleSheet.absoluteFill, { backgroundColor: PALETTE[scheme].bg }]}>
      <Glyph scheme={scheme} layers={layers} />
    </View>
  );
}
