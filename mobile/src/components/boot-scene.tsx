import { useCallback, useEffect, useRef, useState, type ReactNode, type RefObject } from "react";
import {
  Animated,
  Easing,
  StyleSheet,
  View,
  type ViewProps,
} from "react-native";

import { SPLASH_LAYOUT } from "@/features/boot/splash-storyboard.generated";

/**
 * The splash/boot visuals, shared by the real boot sequence (booting.tsx) and the dev preview screens
 * (app/preview.tsx): the palette, the glyph (four layers + the app name under it), and the "connecting" scene
 * (arrows loop, status line, indeterminate bar). Geometry/palette must stay identical to app.config.ts (splash colours) and
 * scripts/build-brand-assets.mjs (the native AnimatedVectorDrawable) — the boot frame has to match the
 * splash's last frame exactly.
 *
 * RN views + core `Animated` (native driver), not the Compose vocabulary of motion.tsx: it must paint in the
 * very first frame, before any Compose `Host` or icon asset resolves, and is animated as a whole.
 */

export type Scheme = "light" | "dark";

export const PALETTE = {
  light: { bg: "#F6F7FB", glyph: "#3F5590", ink: "#1A1C22", status: "#5B6070", track: "#E5E9F4" },
  dark: { bg: "#121317", glyph: "#AEBEEA", ink: "#E3E4EC", status: "#A9ADBA", track: "#1F2330" },
} as const;

/** Glyph box: the design draws its 76-unit window at 172 dp. One unit = K dp. */
export const GLYPH = 172;
export const K = GLYPH / 76;
/** Visible width of laptop + base (30.5 → 77.5 = 47 units). */
export const GLYPH_VISIBLE = 47 * K;
/**
 * The glyph + wordmark block is lifted this much (dp) so the pair is centred and the text clears the system
 * splash's 192 dp circle. The AVD applies the same lift (scripts/build-brand-assets.mjs, LIFT_DP).
 */
const LIFT = SPLASH_LAYOUT.liftDp;
/** The mask strip right under the laptop base, in dp inside the glyph box (box origin = glyph unit 16,16). */
const STRIP_TOP = (SPLASH_LAYOUT.strip.y1 - 16) * K;
const STRIP_HEIGHT = (SPLASH_LAYOUT.strip.y2 - SPLASH_LAYOUT.strip.y1) * K;
/** The arrows' idle slide: ±2.5 units. */
const ARROW_SLIDE = 2.5 * K;
/** Status line + bar appear this long after the scene starts. */
const STATUS_DELAY_MS = 300;

const LAYERS = {
  laptop: require("../../assets/boot/laptop.png"),
  base: require("../../assets/boot/base.png"),
  arrowTop: require("../../assets/boot/arrow-top.png"),
  arrowBottom: require("../../assets/boot/arrow-bottom.png"),
  wordmark: require("../../assets/boot/wordmark.png"),
};

type AnimStyle = Animated.WithAnimatedValue<object> | undefined;
export type LayerStyles = {
  laptop?: AnimStyle;
  base?: AnimStyle;
  arrowTop?: AnimStyle;
  arrowBottom?: AnimStyle;
  /** The wordmark image itself — slides (translateY) inside the mask. */
  wordmark?: AnimStyle;
  /** The mask wrapper around the wordmark — fade it (opacity) without touching the slide. */
  wordmarkMask?: AnimStyle;
};

/**
 * The glyph: laptop + base in the glyph colour, the two arrows in the BACKGROUND colour (so they read as
 * cut-outs), and the app name under it in the ink colour, inside a clipping strip (so when it slides it appears
 * from "under" the icon and nowhere else). Per-layer animated styles let the callers move the parts
 * independently. Reports once all five images have loaded, so the splash is never hidden before it has painted.
 */
export function Glyph({
  scheme,
  layers,
  style,
  glyphRef,
  onLoaded,
}: {
  scheme: Scheme;
  layers?: LayerStyles;
  style?: AnimStyle;
  glyphRef?: RefObject<View | null>;
  onLoaded?: () => void;
}) {
  const P = PALETTE[scheme];
  const loaded = useRef(0);
  const onLayerLoad = useCallback(() => {
    loaded.current += 1;
    if (loaded.current >= 5) onLoaded?.();
  }, [onLoaded]);

  return (
    <Animated.View ref={glyphRef} style={[styles.glyph, style]}>
      <Layer source={LAYERS.laptop} tint={P.glyph} onLoad={onLayerLoad} style={layers?.laptop} />
      <Layer source={LAYERS.base} tint={P.glyph} onLoad={onLayerLoad} style={layers?.base} />
      <Layer source={LAYERS.arrowTop} tint={P.bg} onLoad={onLayerLoad} style={layers?.arrowTop} />
      <Layer source={LAYERS.arrowBottom} tint={P.bg} onLoad={onLayerLoad} style={layers?.arrowBottom} />
      <Animated.View style={[styles.mask, layers?.wordmarkMask]}>
        <Layer
          source={LAYERS.wordmark}
          tint={P.ink}
          onLoad={onLayerLoad}
          // The image spans the whole glyph box; shift it up so it lines up inside the strip.
          style={[{ top: -STRIP_TOP }, layers?.wordmark]}
        />
      </Animated.View>
    </Animated.View>
  );
}

function Layer({
  source,
  tint,
  onLoad,
  style,
}: {
  source: number;
  tint: string;
  onLoad: () => void;
  style?: AnimStyle | AnimStyle[];
}) {
  return (
    <Animated.Image
      source={source}
      onLoad={onLoad}
      // Android fades images in by default (300 ms): the very first frame must already be complete.
      fadeDuration={0}
      style={[styles.layer, { tintColor: tint }, style]}
    />
  );
}

/**
 * The "connecting" motion: the two arrows slide in opposite directions (1.2 s loop), the indeterminate bar
 * sweeps (1.4 s), and the status line fades in after 300 ms. Runs while `active`.
 */
export function useBootMotion(active: boolean) {
  const [slide] = useState(() => new Animated.Value(0.5)); // 0..1 → −2.5..+2.5 units; 0.5 = settled
  const [bar] = useState(() => new Animated.Value(0));
  const [statusOpacity] = useState(() => new Animated.Value(0));

  useEffect(() => {
    if (!active) return;
    const arrows = Animated.sequence([
      Animated.timing(slide, { toValue: 1, duration: 300, easing: Easing.out(Easing.ease), useNativeDriver: true }),
      Animated.loop(
        Animated.sequence([
          Animated.timing(slide, { toValue: 0, duration: 600, easing: Easing.inOut(Easing.ease), useNativeDriver: true }),
          Animated.timing(slide, { toValue: 1, duration: 600, easing: Easing.inOut(Easing.ease), useNativeDriver: true }),
        ]),
      ),
    ]);
    const sweep = Animated.loop(
      Animated.timing(bar, { toValue: 1, duration: 1400, easing: Easing.bezier(0.4, 0, 0.2, 1), useNativeDriver: true }),
    );
    arrows.start();
    sweep.start();
    const status = setTimeout(() => {
      Animated.timing(statusOpacity, { toValue: 1, duration: 250, useNativeDriver: true }).start();
    }, STATUS_DELAY_MS);
    return () => {
      clearTimeout(status);
      arrows.stop();
      sweep.stop();
    };
  }, [active, slide, bar, statusOpacity]);

  return { slide, bar, statusOpacity };
}

export type BootMotion = ReturnType<typeof useBootMotion>;

/**
 * Full-screen boot frame: background, status line + bar, and the glyph as its own layer (so the real boot can
 * fly it into Home's badge while the background fades). `bgStyle` / `glyphStyle` carry those animations.
 */
export function BootScene({
  scheme,
  motion,
  rootRef,
  glyphRef,
  onGlyphLoaded,
  bgStyle,
  glyphStyle,
  wordmarkStyle,
  pointerEvents,
  children,
}: {
  scheme: Scheme;
  motion: BootMotion;
  rootRef?: RefObject<View | null>;
  glyphRef?: RefObject<View | null>;
  onGlyphLoaded?: () => void;
  bgStyle?: AnimStyle;
  glyphStyle?: AnimStyle;
  /** Style for the app name's mask wrapper — the real boot fades it first when the glyph flies to Home's badge. */
  wordmarkStyle?: AnimStyle;
  pointerEvents?: ViewProps["pointerEvents"];
  children?: ReactNode;
}) {
  const P = PALETTE[scheme];
  const arrowTop = motion.slide.interpolate({ inputRange: [0, 1], outputRange: [-ARROW_SLIDE, ARROW_SLIDE] });
  const arrowBottom = motion.slide.interpolate({ inputRange: [0, 1], outputRange: [ARROW_SLIDE, -ARROW_SLIDE] });
  const barWidth = 96 * 0.4;
  const barX = motion.bar.interpolate({ inputRange: [0, 1], outputRange: [-1.1 * barWidth, 2.6 * barWidth] });

  return (
    <View ref={rootRef} style={StyleSheet.absoluteFill} pointerEvents={pointerEvents}>
      <Animated.View style={[StyleSheet.absoluteFill, { backgroundColor: P.bg }, bgStyle]}>
        <Animated.View style={[styles.status, { opacity: motion.statusOpacity }]}>
          <Animated.Text style={[styles.statusText, { color: P.status }]}>
            Connecting to Mac…
          </Animated.Text>
          <View style={[styles.track, { backgroundColor: P.track }]}>
            <Animated.View
              style={[
                styles.fill,
                { backgroundColor: P.glyph, width: barWidth, transform: [{ translateX: barX }] },
              ]}
            />
          </View>
        </Animated.View>
      </Animated.View>

      <Glyph
        scheme={scheme}
        glyphRef={glyphRef}
        onLoaded={onGlyphLoaded}
        style={glyphStyle}
        layers={{
          arrowTop: { transform: [{ translateX: arrowTop }] },
          arrowBottom: { transform: [{ translateX: arrowBottom }] },
          wordmarkMask: wordmarkStyle,
        }}
      />
      {children}
    </View>
  );
}

const styles = StyleSheet.create({
  // Dead centre, like the system splash's icon.
  glyph: {
    position: "absolute",
    left: "50%",
    top: "50%",
    width: GLYPH,
    height: GLYPH,
    marginLeft: -GLYPH / 2,
    marginTop: -GLYPH / 2 - LIFT,
  },
  // The wordmark's clipping strip (the text is hidden while it is above it).
  mask: { position: "absolute", left: 0, top: STRIP_TOP, width: GLYPH, height: STRIP_HEIGHT, overflow: "hidden" },
  layer: { position: "absolute", left: 0, top: 0, width: GLYPH, height: GLYPH },
  status: {
    position: "absolute",
    left: 0,
    right: 0,
    top: "50%",
    // Below the wordmark (its bottom sits ~59 dp under the screen centre): same ~41 dp gap the design used
    // under the glyph before the wordmark existed.
    marginTop: 100,
    alignItems: "center",
    gap: 16,
  },
  statusText: { fontSize: 15, fontWeight: "500" },
  track: { width: 96, height: 4, borderRadius: 2, overflow: "hidden" },
  fill: { height: "100%", borderRadius: 2 },
});
