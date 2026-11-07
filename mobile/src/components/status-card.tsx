import {
  Box,
  Column,
  Icon,
  Row,
  Shape,
  Surface,
  type MaterialColors,
} from "@expo/ui/jetpack-compose";
import { FitText } from "@/components/fit-text";
import { Text } from "@/components/text";
import {
  animateContentSize,
  fillMaxWidth,
  height,
  onGloballyPositioned,
  padding,
  size,
  weight,
} from "@expo/ui/jetpack-compose/modifiers";
import type { ReactNode } from "react";

import { useIcons, type IconSource } from "@/components/icons";
import { StatusDot, withAlpha } from "@/components/m3";
import { AnimatedSurface, Reveal, useBreathing, useLatched } from "@/components/motion";
import { Spacing } from "@/constants/theme";
import { setHeroBadge } from "@/features/boot/hero-badge";

const radius = (r: number) =>
  Shape.RoundedCorner({ cornerRadii: { topStart: r, topEnd: r, bottomStart: r, bottomEnd: r } });

const CARD = radius(32);
const MARK = radius(26);
const PILL = radius(16);

/** Segmented stat-tile corners: big on the group's outer edge, small where tiles touch. */
function tileShape(first: boolean, last: boolean) {
  const s = first ? 18 : 6;
  const e = last ? 18 : 6;
  return Shape.RoundedCorner({
    cornerRadii: { topStart: s, bottomStart: s, topEnd: e, bottomEnd: e },
  });
}

export type StatTileData = {
  key: string;
  icon: IconSource;
  value: string;
  label: string;
  /** Tertiary tint instead of the neutral overlay (a charging Mac). */
  accent?: boolean;
};

/**
 * Home's hero: the paired Mac, one live status pill and — while connected — a row of stat tiles
 * (transport, battery, distance) in place of the old four separate chips and rows. Connected is a
 * primary-container card; anything else drops to a quiet surface card with no stats, since a stat
 * from a Mac we can't hear from would be stale.
 */
export function StatusCard({
  colors,
  name,
  connected,
  statusLabel,
  statusColor,
  waiting = false,
  stats,
}: {
  colors: MaterialColors;
  name: string;
  connected: boolean;
  statusLabel: string;
  statusColor: string;
  /** Still (re)connecting: the status dot breathes instead of sitting solid. */
  waiting?: boolean;
  stats: StatTileData[];
}) {
  const icons = useIcons();
  const dotAlpha = useBreathing(waiting);
  const showStats = connected && stats.length > 0;
  // Keep the last tiles on screen while the row animates shut after a disconnect.
  const shownStats = useLatched(showStats ? stats : null) ?? [];
  const container = connected ? colors.primaryContainer : colors.surfaceContainer;
  const on = connected ? colors.onPrimaryContainer : colors.onSurface;
  const sub = connected ? withAlpha(colors.onPrimaryContainer, 0.8) : colors.onSurfaceVariant;

  return (
    <AnimatedSurface color={container} shape={CARD} modifiers={[fillMaxWidth()]}>
      <Column modifiers={[fillMaxWidth(), padding(20, 20, 20, 20), animateContentSize()]}>
        <Column modifiers={[fillMaxWidth()]} verticalArrangement={{ spacedBy: 20 }}>
          <Row
            modifiers={[fillMaxWidth()]}
            horizontalArrangement="spaceBetween"
            verticalAlignment="top"
          >
            <AnimatedSurface
              color={connected ? colors.primary : colors.surfaceContainerHighest}
              shape={MARK}
              // Reports where the badge sits so the Boot overlay can shrink the splash glyph into it.
              modifiers={[size(76, 76), onGloballyPositioned(setHeroBadge)]}
            >
              <Box contentAlignment="center" modifiers={[size(76, 76)]}>
                <Icon
                  source={connected ? icons.laptopActive : icons.laptop}
                  size={42}
                  tint={connected ? colors.onPrimary : colors.onSurfaceVariant}
                />
              </Box>
            </AnimatedSurface>
            <Surface color={colors.background} shape={PILL}>
              <Row
                modifiers={[height(32), padding(12, 0, 14, 0)]}
                horizontalArrangement={{ spacedBy: Spacing.two }}
                verticalAlignment="center"
              >
                <StatusDot color={statusColor} alpha={dotAlpha} />
                <Text color={colors.onSurface} style={{ typography: "labelLarge", fontWeight: "500" }}>
                  {statusLabel}
                </Text>
              </Row>
            </Surface>
          </Row>

          <Column verticalArrangement={{ spacedBy: Spacing.one }}>
            {/* One line when it fits (30sp → 22sp), a second line only below that. */}
            <FitText color={on} typography="headlineMedium" fontWeight="600" maxSize={30} minSize={22}>
              {name}
            </FitText>
            <Text color={sub} style={{ typography: "bodyMedium" }}>
              Paired Mac
            </Text>
        </Column>

        </Column>

        {/* Own Reveal (not a Column child with spacing) so a hidden row leaves no 20dp gap. */}
        <Reveal visible={showStats}>
          <Box modifiers={[fillMaxWidth(), padding(0, 20, 0, 0)]}>
            <Row modifiers={[fillMaxWidth()]} horizontalArrangement={{ spacedBy: 6 }}>
              {shownStats.map((s, i) => (
                <StatTile
                  key={s.key}
                  colors={colors}
                  data={s}
                  shape={tileShape(i === 0, i === shownStats.length - 1)}
                />
              ))}
            </Row>
          </Box>
        </Reveal>
      </Column>
    </AnimatedSurface>
  );
}

function StatTile({
  colors,
  data,
  shape,
}: {
  colors: MaterialColors;
  data: StatTileData;
  shape: ReturnType<typeof tileShape>;
}) {
  const bg = data.accent ? colors.tertiaryContainer : withAlpha(colors.onPrimaryContainer, 0.08);
  const on = data.accent ? colors.onTertiaryContainer : colors.onPrimaryContainer;
  const sub = data.accent ? colors.onTertiaryContainer : withAlpha(colors.onPrimaryContainer, 0.8);
  const body: ReactNode = (
    <Column modifiers={[fillMaxWidth(), padding(12, 12, 12, 12)]} verticalArrangement={{ spacedBy: 8 }}>
      <Icon source={data.icon} size={20} tint={on} />
      <Column verticalArrangement={{ spacedBy: 2 }}>
        <Text color={on} style={{ typography: "titleMedium", fontWeight: "600" }}>
          {data.value}
        </Text>
        <Text color={sub} style={{ typography: "labelMedium" }}>
          {data.label}
        </Text>
      </Column>
    </Column>
  );
  return (
    <Surface color={bg} shape={shape} modifiers={[weight(1)]}>
      {body}
    </Surface>
  );
}
