import { alpha, onSizeChanged } from "@expo/ui/jetpack-compose/modifiers";
import { useEffect, useMemo, useState } from "react";
import { PixelRatio, useWindowDimensions } from "react-native";

import { Text } from "@/components/text";

/** Settled size per (text, range, window width, font scale) so a revisit doesn't re-measure. */
const settled = new Map<string, number>();

/**
 * A heading that stays on ONE line when it can: it starts at `maxSize` and steps down 1sp at a time
 * until the text fits on a single line, and only once it hits `minSize` is it allowed to wrap onto a
 * second line (`maxLines`, then an ellipsis).
 *
 * Compose's `Text` has no auto-size and the natural text width can't be read from it, so this uses
 * layout feedback: render at the current size, read the laid-out height via `onSizeChanged`, and if
 * that is more than one line tall, shrink and try again. The text is invisible (`alpha(0)`, still
 * laid out) while it searches — a few frames at most — then the result is cached, so revisiting the
 * screen shows the right size immediately. A short timeout reveals the text regardless, so a missed
 * layout callback can never leave it hidden.
 */
export function FitText({
  children,
  color,
  typography,
  fontWeight,
  maxSize,
  minSize,
  lineHeightRatio = 1.2,
  maxLines = 2,
}: {
  children: string;
  color: string;
  typography?: NonNullable<React.ComponentProps<typeof Text>["style"]>["typography"];
  fontWeight?: NonNullable<React.ComponentProps<typeof Text>["style"]>["fontWeight"];
  maxSize: number;
  minSize: number;
  /** line height as a multiple of the font size (kept proportional while shrinking) */
  lineHeightRatio?: number;
  maxLines?: number;
}) {
  const { width } = useWindowDimensions();
  const fontScale = PixelRatio.getFontScale();
  const key = `${children}|${maxSize}|${minSize}|${Math.round(width)}|${fontScale}`;

  // One state object tagged with its key: when the text / window / range changes the stale state is
  // ignored and the search restarts from the cache (or `maxSize`), with no reset-in-an-effect.
  const [state, setState] = useState({
    key,
    size: settled.get(key) ?? maxSize,
    done: settled.has(key),
  });
  const { size, done } =
    state.key === key
      ? state
      : { size: settled.get(key) ?? maxSize, done: settled.has(key) };

  // Never leave it hidden if no layout callback arrives.
  useEffect(() => {
    if (done) return;
    const t = setTimeout(() => setState({ key, size, done: true }), 700);
    return () => clearTimeout(t);
  }, [done, size, key]);

  const lineHeight = size * lineHeightRatio;
  const modifiers = useMemo(
    () => [
      alpha(done ? 1 : 0),
      onSizeChanged(({ height }) => {
        if (done) return;
        // dp height of one line = lineHeight(sp) × fontScale; more than ~1.5 lines ⇒ it wrapped.
        const wrapped = height > lineHeight * fontScale * 1.5;
        if (wrapped && size > minSize) {
          setState({ key, size: size - 1, done: false });
        } else {
          settled.set(key, size);
          setState({ key, size, done: true });
        }
      }),
    ],
    [done, lineHeight, fontScale, size, minSize, key],
  );

  return (
    <Text
      color={color}
      modifiers={modifiers}
      maxLines={maxLines}
      overflow="ellipsis"
      style={{ typography, fontWeight, fontSize: size, lineHeight }}
    >
      {children}
    </Text>
  );
}
