import {
  Box,
  Column,
  Icon,
  Row,
  Shape,
  Surface,
  type MaterialColors,
} from '@expo/ui/jetpack-compose';
import { Text } from "@/components/text";
import {
  background,
  clip,
  fillMaxWidth,
  graphicsLayer,
  onVisibilityChanged,
  padding,
  Shapes,
  size,
  weight,
  type AnimatedValue,
} from '@expo/ui/jetpack-compose/modifiers';
import { Children, cloneElement, isValidElement, type ReactNode } from 'react';
import { useColorScheme } from 'react-native';

import { Spacing } from '@/constants/theme';
import { useAppearance } from '@/features/appearance/appearance-context';

import { useIcons, type IconSource } from './icons';
import { Motion } from './motion';

/**
 * Shared Material 3 Expressive primitives used across the native (Jetpack Compose) screens —
 * the seed color, the grouped-list shape logic, the tonal leading icon circle. Keeping these in
 * one place is what makes Settings and Home read as the same design language.
 */

/**
 * Stable Material 3 palette for the current scheme + accent colour. `getMaterialColors` makes a
 * synchronous native call and returns a *new* object each time (see @expo/ui colors.ts), which would
 * churn the whole native `Host` subtree — so it is resolved ONCE in `AppearanceProvider` (memoized on
 * scheme + seed) and shared here through context, not recomputed by each caller.
 */
export function useM3Colors(): MaterialColors {
  return useAppearance().colors;
}

/**
 * The `seedColor` + `colorScheme` every Compose `<Host>` must be given so the native components
 * (Switch, Checkbox, ripples, sheets…) are themed from the same palette as {@link useM3Colors}.
 * Spread it: `<Host {...useHostTheme()}>`.
 */
export function useHostTheme() {
  const colorScheme = useColorScheme();
  const { seedColor } = useAppearance();
  return { seedColor, colorScheme };
}

/**
 * Google-style grouped list: the rows in a group read as one rounded block, packed with a
 * hairline GROUP_GAP between them. The group's outer corners are large (R_OUTER); the corners
 * that touch a neighbour are small (R_INNER). A lone row keeps large corners all the way round.
 */
/** Exported for lists that lay grouped rows out manually (memoized rows with stable,
 *  precomputed shapes — {@link Group}'s cloneElement would re-mint every row's `shape`
 *  object each render and defeat React.memo on long lists). */
export const GROUP_GAP = 3;
const R_OUTER = 24;
const R_INNER = 6;

export type RowShape = ReturnType<typeof Shape.RoundedCorner>;

/** Position-aware corner radii for a row inside its group. */
export function groupShape(isFirst: boolean, isLast: boolean, outer: number = R_OUTER): RowShape {
  const top = isFirst ? outer : R_INNER;
  const bottom = isLast ? outer : R_INNER;
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
export function Group({
  children,
  outerRadius = R_OUTER,
}: {
  children: ReactNode;
  /** Radius of the group's outer corners (24 by default; the Files history uses 20). */
  outerRadius?: number;
}) {
  // toArray drops the `null`s from conditionally-rendered rows, so first/last land correctly.
  const rows = Children.toArray(children);
  return (
    <Column modifiers={[fillMaxWidth()]} verticalArrangement={{ spacedBy: GROUP_GAP }}>
      {rows.map((row, i) =>
        isValidElement<{ shape?: RowShape }>(row)
          ? cloneElement(row, { shape: groupShape(i === 0, i === rows.length - 1, outerRadius) })
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

export type Tone = 'secondary' | 'primary' | 'tertiary' | 'error';

/** Tonal container + on-container pair for the expressive leading icon circle. */
export function tonal(colors: MaterialColors, tone: Tone) {
  switch (tone) {
    case 'error':
      return { container: colors.errorContainer, on: colors.onErrorContainer };
    case 'primary':
      return { container: colors.primaryContainer, on: colors.onPrimaryContainer };
    case 'tertiary':
      return { container: colors.tertiaryContainer, on: colors.onTertiaryContainer };
    default:
      return { container: colors.secondaryContainer, on: colors.onSecondaryContainer };
  }
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

/** Section heading above a grouped list: primary-coloured, 14sp medium (Settings, Files, Appearance…). */
export function SectionLabel({ colors, children }: { colors: MaterialColors; children: string }) {
  return (
    <Box modifiers={[fillMaxWidth(), padding(Spacing.one, 0, Spacing.one, 0)]}>
      <Text color={colors.primary} style={{ typography: 'labelLarge', fontWeight: '500' }}>
        {children}
      </Text>
    </Box>
  );
}

/**
 * Small filled status dot (connected / reconnecting / error). The colour cross-fades when it
 * changes; `alpha` takes a {@link useBreathing} value for the "still trying" pulse.
 */
export function StatusDot({
  color,
  diameter = 8,
  alpha = 1,
}: {
  color: string;
  diameter?: number;
  alpha?: number | AnimatedValue;
}) {
  return (
    <Box
      modifiers={[
        size(diameter, diameter),
        clip(Shapes.Circle),
        background(color, { animationSpec: Motion.color }),
        graphicsLayer({ alpha }),
      ]}
    />
  );
}

/**
 * One segment of a connected 2-up selector (Appearance mode, Select-apps mode) — a tonal tile in
 * the {@link ButtonGroup} language. Deliberately NOT an M3 SegmentedButton: its check animation
 * freezes mid-flight while a heavy list flushes on the UI thread, so the selected state is a plain
 * container-colour flip plus a static check glyph.
 */
export function ModeTile({
  colors,
  label,
  selected,
  onPress,
  shape = groupShapeH(true, true),
}: {
  colors: MaterialColors;
  label: string;
  selected: boolean;
  onPress: () => void;
  shape?: RowShape;
}) {
  const icons = useIcons();
  const content = selected ? colors.onPrimary : colors.onSurfaceVariant;
  return (
    <Surface
      color={selected ? colors.primary : colors.surfaceContainerHigh}
      shape={shape}
      onClick={onPress}
      modifiers={[weight(1)]}
    >
      <Row
        modifiers={[
          fillMaxWidth(),
          padding(Spacing.two, Spacing.three, Spacing.two, Spacing.three),
        ]}
        horizontalArrangement={{ spacedBy: Spacing.one }}
        verticalAlignment="center"
      >
        <Box modifiers={[weight(1)]} contentAlignment="center">
          <Row verticalAlignment="center" horizontalArrangement={{ spacedBy: Spacing.one }}>
            {selected ? <Icon source={icons.check} size={20} tint={content} /> : null}
            <Text color={content} style={{ typography: 'labelLarge', fontWeight: '600' }}>
              {label}
            </Text>
          </Row>
        </Box>
      </Row>
    </Surface>
  );
}

/** Large 34sp screen title rendered in the body (Settings, Notifications) under a title-less header. */
export function LargeTitle({
  colors,
  children,
  onVisibleChange,
}: {
  colors: MaterialColors;
  children: string;
  /** Fires as the title scrolls out of / back into view (see `useCollapsingTitle`). It counts as
   *  visible while at least 40% of it shows. Keep it present or absent for a screen's lifetime. */
  onVisibleChange?: (visible: boolean) => void;
}) {
  return (
    <Box
      modifiers={[
        fillMaxWidth(),
        padding(Spacing.one, Spacing.one, Spacing.one, Spacing.two),
        ...(onVisibleChange
          ? [onVisibilityChanged(onVisibleChange, { minFractionVisible: 0.4 })]
          : []),
      ]}
    >
      <Text
        color={colors.onSurface}
        style={{ typography: 'headlineLarge', fontSize: 34, lineHeight: 40, fontWeight: '600' }}
      >
        {children}
      </Text>
    </Box>
  );
}

/** A titled section: primary {@link SectionLabel} above a {@link Group} of rows. */
export function Section({
  colors,
  label,
  children,
}: {
  colors: MaterialColors;
  label: string;
  children: ReactNode;
}) {
  return (
    <Column modifiers={[fillMaxWidth()]} verticalArrangement={{ spacedBy: Spacing.two }}>
      <SectionLabel colors={colors}>{label}</SectionLabel>
      <Group>{children}</Group>
    </Column>
  );
}

/** `#RRGGBBAA` palette colour with its alpha replaced (palette values always carry an alpha pair). */
export function withAlpha(color: string, alpha: number): string {
  const a = Math.round(Math.min(1, Math.max(0, alpha)) * 255)
    .toString(16)
    .padStart(2, '0')
    .toUpperCase();
  return `${color.slice(0, 7)}${a}`;
}
