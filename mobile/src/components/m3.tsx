import { Box, Column, Icon, Row, Shape, getMaterialColors, type MaterialColors } from '@expo/ui/jetpack-compose';
import {
  background,
  clip,
  fillMaxWidth,
  Shapes,
  size,
} from '@expo/ui/jetpack-compose/modifiers';
import { Children, cloneElement, isValidElement, useMemo, type ReactNode } from 'react';
import { useColorScheme } from 'react-native';

import { type IconSource } from './icons';

/**
 * Shared Material 3 Expressive primitives used across the native (Jetpack Compose) screens —
 * the seed color, the grouped-list shape logic, the tonal leading icon circle. Keeping these in
 * one place is what makes Settings and Home read as the same design language.
 */

/** Brand blue (app.json notification color) — seeds the whole Material 3 palette. */
export const SEED = '#208AEF';

/**
 * Stable, scheme-keyed Material 3 palette. `useMaterialColors({ seedColor })` makes a
 * synchronous native call and returns a *new* object on every render (see @expo/ui colors.ts),
 * which churns the whole native `Host` subtree on each re-render. Memoizing by color scheme
 * keeps the reference stable and only re-resolves when light/dark actually flips.
 */
export function useM3Colors(): MaterialColors {
  const scheme = useColorScheme();
  return useMemo(
    () => getMaterialColors({ scheme: scheme === 'dark' ? 'dark' : 'light', seedColor: SEED }),
    [scheme],
  );
}

/**
 * Google-style grouped list: the rows in a group read as one rounded block, packed with a
 * hairline GROUP_GAP between them. The group's outer corners are large (R_OUTER); the corners
 * that touch a neighbour are small (R_INNER). A lone row keeps large corners all the way round.
 */
const GROUP_GAP = 3;
const R_OUTER = 24;
const R_INNER = 6;

export type RowShape = ReturnType<typeof Shape.RoundedCorner>;

/** Position-aware corner radii for a row inside its group. */
export function groupShape(isFirst: boolean, isLast: boolean): RowShape {
  const top = isFirst ? R_OUTER : R_INNER;
  const bottom = isLast ? R_OUTER : R_INNER;
  return Shape.RoundedCorner({
    cornerRadii: { topStart: top, topEnd: top, bottomStart: bottom, bottomEnd: bottom },
  });
}

/** Horizontal counterpart of {@link groupShape}: large outer start/end corners, small inner. */
export function groupShapeH(isFirst: boolean, isLast: boolean): RowShape {
  const start = isFirst ? R_OUTER : R_INNER;
  const end = isLast ? R_OUTER : R_INNER;
  return Shape.RoundedCorner({
    cornerRadii: { topStart: start, bottomStart: start, topEnd: end, bottomEnd: end },
  });
}

/**
 * One continuous grouped list: clones each rendered row with position-aware corner radii.
 * Any child row must accept a `shape?: RowShape` prop.
 */
export function Group({ children }: { children: ReactNode }) {
  // toArray drops the `null`s from conditionally-rendered rows, so first/last land correctly.
  const rows = Children.toArray(children);
  return (
    <Column modifiers={[fillMaxWidth()]} verticalArrangement={{ spacedBy: GROUP_GAP }}>
      {rows.map((row, i) =>
        isValidElement<{ shape?: RowShape }>(row)
          ? cloneElement(row, { shape: groupShape(i === 0, i === rows.length - 1) })
          : row,
      )}
    </Column>
  );
}

/**
 * Horizontal connected "button group" (M3 Expressive): a tight row where the group's outer
 * corners are large and the buttons' touching edges are small. Mirrors {@link Group} for a Row.
 * Any child must accept a `shape?: RowShape` prop (and typically carry a `weight(1)` modifier).
 */
export function ButtonGroup({ children }: { children: ReactNode }) {
  const items = Children.toArray(children);
  return (
    <Row modifiers={[fillMaxWidth()]} horizontalArrangement={{ spacedBy: GROUP_GAP }}>
      {items.map((item, i) =>
        isValidElement<{ shape?: RowShape }>(item)
          ? cloneElement(item, { shape: groupShapeH(i === 0, i === items.length - 1) })
          : item,
      )}
    </Row>
  );
}

export type Tone = 'secondary' | 'error';

/** Tonal container + on-container pair for the expressive leading icon circle. */
export function tonal(colors: MaterialColors, tone: Tone) {
  return tone === 'error'
    ? { container: colors.errorContainer, on: colors.onErrorContainer }
    : { container: colors.secondaryContainer, on: colors.onSecondaryContainer };
}

/** The signature M3 Expressive leading element: an icon inside a tonal circle. */
export function IconCircle({
  source,
  container,
  on,
  diameter = 40,
  iconSize = 22,
}: {
  source: IconSource;
  container: string;
  on: string;
  diameter?: number;
  iconSize?: number;
}) {
  return (
    <Box
      contentAlignment="center"
      modifiers={[size(diameter, diameter), clip(Shapes.Circle), background(container)]}
    >
      <Icon source={source} size={iconSize} tint={on} />
    </Box>
  );
}
