/**
 * Where Home's hero badge sits on screen, in window dp.
 *
 * The Boot overlay (src/components/booting.tsx) shrinks the splash glyph into that badge when it hands
 * over to Home. The badge lives inside a Compose `Host`, so RN can't measure it: `StatusCard` reports its
 * tile through `onGloballyPositioned` and the overlay reads it here. A plain module store on purpose — it is
 * written by one component, read once at boot, and needs no re-render of anything.
 */
export type Rect = { x: number; y: number; width: number; height: number };

let current: Rect | null = null;
const listeners = new Set<(rect: Rect) => void>();

export function setHeroBadge(rect: Rect): void {
  current = rect;
  listeners.forEach((fn) => fn(rect));
}

export function getHeroBadge(): Rect | null {
  return current;
}

/** Calls `fn` on every report; returns the unsubscribe. */
export function subscribeHeroBadge(fn: (rect: Rect) => void): () => void {
  listeners.add(fn);
  return () => {
    listeners.delete(fn);
  };
}
