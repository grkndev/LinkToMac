import {
  Box,
  Button,
  Column,
  Icon,
  ListItem,
  Row,
  Shape,
  Surface,
  Switch,
  type MaterialColors,
} from "@expo/ui/jetpack-compose";
import { Text } from "@/components/text";
import {
  alpha,
  fillMaxWidth,
  graphicsLayer,
  height,
  padding,
  size,
  weight,
} from "@expo/ui/jetpack-compose/modifiers";
import { EnterTransition, ExitTransition } from "@expo/ui/jetpack-compose";
import type { ReactNode } from "react";
import { Alert } from "@/components/AlertDialog";

import { useIcons, type IconSource } from "@/components/icons";
import {
  IconCircle,
  StatusDot,
  groupShape,
  groupShapeH,
  tonal,
  withAlpha,
  type Tone,
  type RowShape,
} from "@/components/m3";
import { AnimatedSurface, Reveal, usePulse } from "@/components/motion";
import { Spacing } from "@/constants/theme";
import { haptic } from "@/lib/haptics";

/**
 * The grouped-list row vocabulary shared by Home, Settings, About and Clipboard — one rounded
 * tonal card per row, each with a leading {@link IconCircle}. Every variant is a thin wrapper
 * over the {@link GroupRow} scaffold so all rows read as the same Material 3 design language.
 * Each row accepts an optional `shape` so a {@link Group} wrapper can clone position-aware
 * corner radii onto it.
 */

/** The shared row scaffold: tonal Surface + ListItem with a leading icon circle. */
export function GroupRow({
  colors,
  icon,
  leading,
  tone = "secondary",
  label,
  labelColor,
  supporting,
  supportingDot,
  supportingColor,
  trailing,
  chevron,
  footer,
  color,
  onClick,
  checked,
  onCheckedChange,
  shape = groupShape(true, true),
}: {
  colors: MaterialColors;
  /** Tinted glyph for the standard tonal {@link IconCircle}. Ignored when `leading` is set. */
  icon?: IconSource;
  /** Custom leading element replacing the IconCircle — e.g. a full-color app icon. */
  leading?: ReactNode;
  tone?: Tone;
  label: string;
  labelColor?: string;
  supporting?: string;
  /** A status dot drawn before the supporting line (e.g. Automatic capture's on/off). */
  supportingDot?: string;
  /** Supporting-line colour override (e.g. on-error-container inside an error card). */
  supportingColor?: string;
  trailing?: ReactNode;
  /** Trailing "go deeper" chevron (ignored when `trailing` is given). */
  chevron?: boolean;
  /** Extra content under the row inside the same card — e.g. an {@link InlineNotice}. */
  footer?: ReactNode;
  /** Card colour; defaults to surfaceContainer. `transparent` makes a flat list row. */
  color?: string;
  onClick?: () => void;
  /** Switch mode: the Surface itself toggles (with haptics) when tapped anywhere on the row. */
  checked?: boolean;
  onCheckedChange?: (value: boolean) => void;
  shape?: RowShape;
}) {
  const icons = useIcons();
  const t = tonal(colors, tone);
  const toggleable =
    checked !== undefined && onCheckedChange !== undefined
      ? {
          checked,
          onCheckedChange: (value: boolean) => {
            onCheckedChange(value);
            haptic();
          },
        }
      : { onClick };
  const container = color ?? colors.surfaceContainer;
  const end =
    trailing ??
    (chevron ? (
      <Icon source={icons.chevronRight} size={24} tint={colors.onSurfaceVariant} />
    ) : undefined);

  const row = (
    <Surface
      // With a footer the outer card owns the colour; the clickable row is just a ripple area.
      color={footer ? "transparent" : container}
      shape={shape}
      modifiers={[fillMaxWidth()]}
      {...toggleable}
    >
      <ListItem
        colors={{ containerColor: "transparent" }}
        modifiers={[fillMaxWidth()]}
      >
        {leading != null || icon != null ? (
          <ListItem.LeadingContent>
            {leading ?? (
              <IconCircle source={icon!} container={t.container} on={t.on} />
            )}
          </ListItem.LeadingContent>
        ) : null}
        <ListItem.HeadlineContent>
          <Text
            color={labelColor ?? colors.onSurface}
            style={{ typography: "bodyLarge", fontWeight: "500" }}
          >
            {label}
          </Text>
        </ListItem.HeadlineContent>
        {/* `!= null` (not truthiness): an empty-string supporting line still renders its slot,
            e.g. Home's Clipboard row while the history is loading. */}
        {supporting != null ? (
          <ListItem.SupportingContent>
            {supportingDot ? (
              <Row
                verticalAlignment="top"
                horizontalArrangement={{ spacedBy: Spacing.two }}
              >
                {/* Nudged down to the first line's centre (the hint can wrap to two). */}
                <Box modifiers={[padding(0, 7, 0, 0)]}>
                  <StatusDot color={supportingDot} />
                </Box>
                <Text
                  modifiers={[weight(1)]}
                  color={supportingColor ?? colors.onSurfaceVariant}
                  style={{ typography: "bodyMedium" }}
                >
                  {supporting}
                </Text>
              </Row>
            ) : (
              <Text
                color={supportingColor ?? colors.onSurfaceVariant}
                style={{ typography: "bodyMedium" }}
              >
                {supporting}
              </Text>
            )}
          </ListItem.SupportingContent>
        ) : null}
        {end ? <ListItem.TrailingContent>{end}</ListItem.TrailingContent> : null}
      </ListItem>
    </Surface>
  );

  if (!footer) return row;
  return (
    <Surface color={container} shape={shape} modifiers={[fillMaxWidth()]}>
      <Column modifiers={[fillMaxWidth()]}>
        {row}
        {footer}
      </Column>
    </Surface>
  );
}

/**
 * A tonal call-out card for a missing grant, nested under a row (pass as `footer`). `error` for
 * a blocked/denied permission, `tertiary` for an informational hand-off to system settings. The
 * action is the whole card (`onClick`) or an explicit pill button (`actionLabel`).
 */
export function InlineNotice({
  colors,
  tone = "error",
  icon,
  title,
  message,
  actionLabel,
  trailingIcon,
  onClick,
}: {
  colors: MaterialColors;
  tone?: "error" | "tertiary";
  icon: IconSource;
  title: string;
  message: string;
  actionLabel?: string;
  /** A small trailing glyph when the whole card is the action (e.g. open-in-new). */
  trailingIcon?: IconSource;
  onClick?: () => void;
}) {
  const t = tonal(colors, tone);
  const accent = tone === "error" ? colors.error : colors.onTertiaryContainer;
  const accentOn = tone === "error" ? colors.onError : colors.tertiaryContainer;
  return (
    <Box modifiers={[fillMaxWidth(), padding(Spacing.two, 0, Spacing.two, Spacing.two)]}>
      <Surface
        color={t.container}
        shape={NOTICE_SHAPE}
        onClick={actionLabel ? undefined : onClick}
        modifiers={[fillMaxWidth()]}
      >
        <Column
          modifiers={[fillMaxWidth(), padding(14, 14, 14, 12)]}
          verticalArrangement={{ spacedBy: 10 }}
        >
          <Row
            modifiers={[fillMaxWidth()]}
            horizontalArrangement={{ spacedBy: 12 }}
            verticalAlignment="center"
          >
            <Icon source={icon} size={20} tint={t.on} />
            <Column modifiers={[weight(1)]} verticalArrangement={{ spacedBy: 3 }}>
              <Text color={t.on} style={{ typography: "labelLarge", fontWeight: "600" }}>
                {title}
              </Text>
              <Text color={t.on} style={{ typography: "bodySmall" }}>
                {message}
              </Text>
            </Column>
            {trailingIcon ? <Icon source={trailingIcon} size={20} tint={t.on} /> : null}
          </Row>
          {actionLabel ? (
            <Row modifiers={[fillMaxWidth()]} horizontalArrangement="end">
              <Button
                onClick={onClick}
                colors={{ containerColor: accent, contentColor: accentOn }}
                contentPadding={{ top: 8, bottom: 8, start: 16, end: 16 }}
              >
                <Text style={{ fontWeight: "600", fontSize: 14 }}>{actionLabel}</Text>
              </Button>
            </Row>
          ) : null}
        </Column>
      </Surface>
    </Box>
  );
}

const NOTICE_SHAPE = Shape.RoundedCorner({
  cornerRadii: { topStart: 18, topEnd: 18, bottomStart: 18, bottomEnd: 18 },
});

/** Rounded tonal card that toggles its switch when tapped anywhere on the row. */
export function SwitchRow({
  colors,
  icon,
  tone,
  label,
  hint,
  value,
  onValueChange,
  footer,
  shape,
}: {
  colors: MaterialColors;
  icon?: IconSource;
  tone?: Tone;
  label: string;
  hint?: string;
  value: boolean;
  onValueChange: (value: boolean) => void;
  footer?: ReactNode;
  shape?: RowShape;
}) {
  return (
    <GroupRow
      colors={colors}
      icon={icon}
      tone={tone}
      label={label}
      supporting={hint}
      checked={value}
      onCheckedChange={onValueChange}
      footer={footer}
      shape={shape}
      // Display-only: the toggleable Surface owns the change (with haptics). Wiring the
      // Switch too made a direct tap fire BOTH handlers — a latent double-toggle.
      trailing={<Switch value={value} />}
    />
  );
}

/** Rounded tonal card with a tappable ripple over the whole row. */
export function ActionRow({
  colors,
  icon,
  tone,
  label,
  labelColor,
  hint,
  destructive,
  onPress,
  shape,
  trailing,
  chevron,
  supportingDot,
}: {
  colors: MaterialColors;
  icon?: IconSource;
  tone?: Tone;
  label: string;
  labelColor?: string;
  hint?: string;
  destructive?: boolean;
  onPress: () => void;
  shape?: RowShape;
  trailing?: ReactNode;
  /** Shorthand for a trailing chevron. */
  chevron?: boolean;
  supportingDot?: string;
}) {
  return (
    <GroupRow
      colors={colors}
      icon={icon}
      tone={destructive ? "error" : tone}
      label={label}
      labelColor={destructive ? colors.error : labelColor}
      supporting={hint}
      supportingDot={supportingDot}
      onClick={onPress}
      shape={shape}
      trailing={trailing}
      chevron={chevron}
    />
  );
}

/** Rounded tonal card showing a read-only value on the trailing edge. */
export function InfoRow({
  colors,
  icon,
  label,
  value,
  mono,
  shape,
}: {
  colors: MaterialColors;
  icon?: IconSource;
  label: string;
  value: string;
  /** Monospace value (build numbers, ids). */
  mono?: boolean;
  shape?: RowShape;
}) {
  return (
    <GroupRow
      colors={colors}
      icon={icon}
      label={label}
      shape={shape}
      trailing={
        <Text
          color={colors.onSurfaceVariant}
          style={{
            typography: "labelLarge",
            fontWeight: "600",
            ...(mono ? { fontFamily: "monospace" } : {}),
          }}
        >
          {value}
        </Text>
      }
    />
  );
}

/** Rounded tonal card with a supporting value line and a chevron, optionally tappable. */
export function NavRow({
  colors,
  icon,
  tone,
  label,
  value,
  onClick,
  shape,
}: {
  colors: MaterialColors;
  icon: IconSource;
  tone?: Tone;
  label: string;
  value: string;
  onClick?: () => void;
  shape?: RowShape;
}) {
  return (
    <GroupRow
      colors={colors}
      icon={icon}
      tone={tone}
      label={label}
      supporting={value}
      onClick={onClick}
      chevron={onClick != null}
      shape={shape}
    />
  );
}

/**
 * A received clip: the text (up to 3 lines), a relative timestamp and a trailing glyph. The newest
 * one (`latest`) is a primary-container card with a check badge; the rest are quiet surface rows
 * with a copy hint. Tapping any of them copies it back to this phone.
 */
export function ClipRow({
  colors,
  text,
  time,
  latest,
  mono,
  onPress,
  shape,
}: {
  colors: MaterialColors;
  text: string;
  time: string;
  latest?: boolean;
  /** Code/command-looking text: monospace. */
  mono?: boolean;
  onPress: () => void;
  shape?: RowShape;
}) {
  const icons = useIcons();
  const bg = latest ? colors.primaryContainer : colors.surfaceContainer;
  const on = latest ? colors.onPrimaryContainer : colors.onSurface;
  const sub = latest ? withAlpha(colors.onPrimaryContainer, 0.8) : colors.onSurfaceVariant;
  return (
    <Surface color={bg} shape={shape ?? groupShape(true, true)} onClick={onPress} modifiers={[fillMaxWidth()]}>
      <Row
        modifiers={[fillMaxWidth(), padding(16, 16, 16, 16)]}
        horizontalArrangement={{ spacedBy: 14 }}
        verticalAlignment="top"
      >
        <Column modifiers={[weight(1)]} verticalArrangement={{ spacedBy: 6 }}>
          <Text
            color={on}
            style={{
              typography: "bodyMedium",
              fontSize: mono ? 13 : 15,
              lineHeight: mono ? 20 : 21,
              fontWeight: latest ? "500" : "400",
              ...(mono ? { fontFamily: "monospace" } : {}),
            }}
            maxLines={3}
            overflow="ellipsis"
          >
            {text}
          </Text>
          <Text color={sub} style={{ typography: "labelMedium" }}>
            {latest ? `Latest · ${time}` : time}
          </Text>
        </Column>
        {latest ? (
          <IconCircle
            source={icons.check}
            container={colors.primary}
            on={colors.onPrimary}
            diameter={40}
            iconSize={20}
          />
        ) : (
          <Box modifiers={[size(40, 40)]} contentAlignment="center">
            <Icon source={icons.contentCopy} size={20} tint={colors.onSurfaceVariant} />
          </Box>
        )}
      </Row>
    </Surface>
  );
}

/**
 * Equal-width quick action for a {@link ButtonGroup}. Live when given an `onPress` and
 * `enabled`; otherwise dimmed — either a placeholder (no `onPress` → "Soon") or an action
 * that needs a connected Mac (`enabled={false}` → "Not connected").
 */
export function ActionTile({
  colors,
  icon,
  label,
  onPress,
  enabled = true,
  shape = groupShapeH(true, true),
}: {
  colors: MaterialColors;
  icon: IconSource;
  label: string;
  onPress?: () => void;
  enabled?: boolean;
  shape?: RowShape;
}) {
  const t = tonal(colors, "secondary");
  const active = onPress != null && enabled;
  const handleClick = active
    ? onPress
    : onPress != null
      ? () => Alert.show("Not connected", "Connect to your Mac first.", "OK")
      : () => Alert.show("Soon", "This feature is not available yet.", "OK");
  return (
    <Surface
      color={colors.surfaceContainerHigh}
      shape={shape}
      onClick={handleClick}
      modifiers={active ? [weight(1)] : [weight(1), alpha(0.5)]}
    >
      <Column
        modifiers={[
          fillMaxWidth(),
          padding(Spacing.two, Spacing.three, Spacing.two, Spacing.three),
        ]}
        horizontalAlignment="center"
        verticalArrangement={{ spacedBy: Spacing.two }}
      >
        <IconCircle source={icon} container={t.container} on={t.on} />
        <Text
          color={colors.onSurface}
          style={{
            typography: "labelLarge",
            fontWeight: "600",
            textAlign: "center",
          }}
        >
          {label}
        </Text>
      </Column>
    </Surface>
  );
}

const TILE_SHAPE = Shape.RoundedCorner({
  cornerRadii: { topStart: 28, topEnd: 28, bottomStart: 28, bottomEnd: 28 },
});

/**
 * Home's tall (116dp) quick-action tile. `filled` = primary (the live action), `tonal` = surface.
 * Not available (offline, or a feature that isn't built) → dimmed; tapping explains why instead of
 * doing nothing. `badge` draws the small outlined "Soon" pill.
 */
export function QuickTile({
  colors,
  icon,
  label,
  variant = "tonal",
  onPress,
  enabled = true,
  badge,
  done = false,
}: {
  colors: MaterialColors;
  icon: IconSource;
  label: string;
  variant?: "filled" | "tonal";
  onPress?: () => void;
  enabled?: boolean;
  badge?: string;
  /** Swaps the icon for a check (the action just succeeded); the caller clears it after a beat. */
  done?: boolean;
}) {
  const icons = useIcons();
  const { pulse, scale } = usePulse();
  const active = onPress != null && enabled;
  const filled = variant === "filled";
  const container = !active && filled
    ? withAlpha(colors.onSurface, 0.1)
    : filled
      ? colors.primary
      : colors.surfaceContainer;
  const content = !active && filled
    ? withAlpha(colors.onSurface, 0.4)
    : filled
      ? colors.onPrimary
      : colors.onSurfaceVariant;
  const handleClick = active
    ? onPress
    : onPress != null
      ? () => Alert.show("Not connected", "Connect to your Mac first.", "OK")
      : () => Alert.show("Soon", "This feature is not available yet.", "OK");
  return (
    <AnimatedSurface
      color={container}
      shape={TILE_SHAPE}
      onClick={() => {
        if (active) pulse();
        handleClick?.();
      }}
      modifiers={[
        weight(1),
        height(116),
        graphicsLayer({ scaleX: scale, scaleY: scale }),
      ]}
    >
      <Column
        modifiers={[fillMaxWidth(), height(116), padding(18, 16, 18, 16)]}
        verticalArrangement="spaceBetween"
      >
        <Row modifiers={[fillMaxWidth()]} horizontalArrangement="spaceBetween" verticalAlignment="center">
          {/* Icon ⇄ check: two Reveals sharing one 28dp box, so the swap scales + fades in place. */}
          <Box contentAlignment="center" modifiers={[size(28, 28)]}>
            <Reveal
              visible={!done}
              enter={EnterTransition.scaleIn({ initialScale: 0.5 }).plus(EnterTransition.fadeIn())}
              exit={ExitTransition.scaleOut({ targetScale: 0.5 }).plus(ExitTransition.fadeOut())}
            >
              <Icon source={icon} size={28} tint={content} />
            </Reveal>
            <Reveal
              visible={done}
              enter={EnterTransition.scaleIn({ initialScale: 0.5 }).plus(EnterTransition.fadeIn())}
              exit={ExitTransition.scaleOut({ targetScale: 0.5 }).plus(ExitTransition.fadeOut())}
            >
              <Icon source={icons.check} size={28} tint={content} />
            </Reveal>
          </Box>
          {badge ? (
            <Surface color="transparent" shape={BADGE_SHAPE} border={{ width: 1, color: colors.outline }}>
              <Box modifiers={[padding(10, 4, 10, 4)]}>
                <Text color={content} style={{ typography: "labelMedium", fontWeight: "500" }}>
                  {badge}
                </Text>
              </Box>
            </Surface>
          ) : null}
        </Row>
        <Text color={content} style={{ typography: "titleMedium", fontWeight: "600" }}>
          {label}
        </Text>
      </Column>
    </AnimatedSurface>
  );
}

const BADGE_SHAPE = Shape.RoundedCorner({
  cornerRadii: { topStart: 10, topEnd: 10, bottomStart: 10, bottomEnd: 10 },
});
