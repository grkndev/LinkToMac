import {
  AnimatedVisibility,
  Box,
  EnterTransition,
  ExitTransition,
  Surface,
  type SurfaceProps,
} from "@expo/ui/jetpack-compose";
import {
  animated,
  background,
  keyframes,
  matchParentSize,
  spring,
  tween,
  type AnimatedValue,
} from "@expo/ui/jetpack-compose/modifiers";
import {
  useCallback,
  useEffect,
  useState,
  type ComponentProps,
  type ReactNode,
} from "react";

/**
 * The app's motion vocabulary, in one place — springs for things that move or scale, a tween for
 * colour, so every screen shares the same feel. All of it runs natively in Compose (no JS frames,
 * no Reanimated: a `<Host>`'s Compose tree isn't an RN view tree, so Reanimated can't reach it).
 *
 * Two native behaviours shape every helper below:
 *  - `animated()` / `background({animationSpec})` only animate when the value CHANGES; the first
 *    composition starts at the target, so a screen never animates in just by opening.
 *  - Those modifiers call composables natively, so a modifier list must keep the same shape
 *    between renders — change a modifier's VALUE, never add or remove it.
 */
export const Motion = {
  /** Scale and position: a little overshoot. */
  spatial: spring({ dampingRatio: 0.8, stiffness: 380 }),
  /** Alpha and progress: no overshoot, quick. */
  effects: spring({ dampingRatio: 1, stiffness: 1500 }),
  /** Colour changes. */
  color: tween({ durationMillis: 350, easing: "fastOutSlowIn" }),
} as const;

/**
 * `false` on the first render, `true` once mounted. `AnimatedVisibility` doesn't play its enter
 * transition for something visible from the first frame, so a thing that should animate IN when its
 * screen opens (or when it first appears) is mounted with `visible={entered}`.
 */
export function useEntered(): boolean {
  const [entered, setEntered] = useState(false);
  // A timeout (setState in a callback, not the effect body) so the first frame is composed hidden.
  useEffect(() => {
    const id = setTimeout(() => setEntered(true), 0);
    return () => clearTimeout(id);
  }, []);
  return entered;
}

/**
 * The last non-null value. An exit animation runs AFTER `visible` flips to false, by which time the
 * data behind the content is usually gone (`current` transfer → undefined); latching keeps the old
 * content on screen while it animates out.
 */
export function useLatched<T>(value: T | null | undefined): T | undefined {
  // State, not a ref: React forbids reading/writing refs during render. Updating state while
  // rendering is the sanctioned "derive from props" pattern (guarded, so it settles in one pass).
  const [last, setLast] = useState<T | undefined>(value ?? undefined);
  if (value != null && value !== last) setLast(value);
  return value ?? last;
}

/** A press "bounce": call `pulse()`, spread `scale` into `graphicsLayer({ scaleX: scale, scaleY: scale })`. */
export function usePulse(): { pulse: () => void; scale: AnimatedValue } {
  const [flip, setFlip] = useState(false);
  const pulse = useCallback(() => setFlip((f) => !f), []);
  // The target alternates 1 ↔ 1.0001 so every press is a *change* (which is what starts the
  // animation); the keyframes dip to 0.92 and back, whichever way it is flipping.
  const scale = animated(
    flip ? 1.0001 : 1,
    keyframes({ durationMillis: 320, keyframes: { 0: 1, 110: 0.92, 320: 1 } }),
  );
  return { pulse, scale };
}

/**
 * A soft "waiting" alpha: eases between 1 and 0.35 while `active`, rests at 1 otherwise. A single JS
 * timer, and only while active (a connecting dot), flips the target; the easing is native.
 */
export function useBreathing(active: boolean, periodMs = 900): AnimatedValue {
  const [low, setLow] = useState(false);
  useEffect(() => {
    if (!active) return;
    const first = setTimeout(() => setLow(true), 0);
    const id = setInterval(() => setLow((l) => !l), periodMs);
    return () => {
      clearTimeout(first);
      clearInterval(id);
    };
  }, [active, periodMs]);
  return animated(active && low ? 0.35 : 1, tween({ durationMillis: periodMs, easing: "ease" }));
}

type Enter = ComponentProps<typeof AnimatedVisibility>["enterTransition"];
type Exit = ComponentProps<typeof AnimatedVisibility>["exitTransition"];

/**
 * Show/hide with a transition (default: fade + vertical expand/shrink). `appear` also plays the
 * enter transition when the component first mounts visible (see {@link useEntered}).
 */
export function Reveal({
  visible,
  appear,
  enter = EnterTransition.fadeIn().plus(EnterTransition.expandVertically()),
  exit = ExitTransition.fadeOut().plus(ExitTransition.shrinkVertically()),
  children,
}: {
  visible: boolean;
  appear?: boolean;
  enter?: Enter;
  exit?: Exit;
  children: ReactNode;
}) {
  const entered = useEntered();
  return (
    <AnimatedVisibility
      visible={visible && (!appear || entered)}
      enterTransition={enter}
      exitTransition={exit}
    >
      {children}
    </AnimatedVisibility>
  );
}

/**
 * A {@link Surface} whose fill cross-fades when `color` changes. `Surface.color` itself is not
 * animatable, so the surface is transparent (it still owns the shape clip, ripple and click) and
 * the colour is an animated `background` on a box behind the content.
 */
export function AnimatedSurface({
  color,
  children,
  modifiers,
  ...rest
}: Omit<SurfaceProps, "color"> & { color: string }) {
  return (
    <Surface color="transparent" modifiers={modifiers} {...rest}>
      <Box>
        <Box modifiers={[matchParentSize(), background(color, { animationSpec: Motion.color })]} />
        {children}
      </Box>
    </Surface>
  );
}
