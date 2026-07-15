import {
  Column,
  Icon,
  ListItem,
  Surface,
  Switch,
  Text,
  type MaterialColors,
} from "@expo/ui/jetpack-compose";
import {
  alpha,
  fillMaxWidth,
  padding,
  weight,
} from "@expo/ui/jetpack-compose/modifiers";
import type { ReactNode } from "react";
import { Alert } from "@/components/AlertDialog";

import { type IconSource } from "@/components/icons";
import {
  IconCircle,
  groupShape,
  groupShapeH,
  tonal,
  type Tone,
  type RowShape,
} from "@/components/m3";
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
  trailing,
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
  trailing?: ReactNode;
  onClick?: () => void;
  /** Switch mode: the Surface itself toggles (with haptics) when tapped anywhere on the row. */
  checked?: boolean;
  onCheckedChange?: (value: boolean) => void;
  shape?: RowShape;
}) {
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
  return (
    <Surface
      color={colors.surfaceContainerHigh}
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
            <Text
              color={colors.onSurfaceVariant}
              style={{ typography: "bodyMedium" }}
            >
              {supporting}
            </Text>
          </ListItem.SupportingContent>
        ) : null}
        {trailing ? (
          <ListItem.TrailingContent>{trailing}</ListItem.TrailingContent>
        ) : null}
      </ListItem>
    </Surface>
  );
}

/** Rounded tonal card that toggles its switch when tapped anywhere on the row. */
export function SwitchRow({
  colors,
  icon,
  label,
  hint,
  value,
  onValueChange,
  shape,
}: {
  colors: MaterialColors;
  icon: IconSource;
  label: string;
  hint?: string;
  value: boolean;
  onValueChange: (value: boolean) => void;
  shape?: RowShape;
}) {
  return (
    <GroupRow
      colors={colors}
      icon={icon}
      label={label}
      supporting={hint}
      checked={value}
      onCheckedChange={onValueChange}
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
  label,
  hint,
  destructive,
  onPress,
  shape,
}: {
  colors: MaterialColors;
  icon: IconSource;
  label: string;
  hint?: string;
  destructive?: boolean;
  onPress: () => void;
  shape?: RowShape;
}) {
  return (
    <GroupRow
      colors={colors}
      icon={icon}
      tone={destructive ? "error" : "secondary"}
      label={label}
      labelColor={destructive ? colors.error : undefined}
      supporting={hint}
      onClick={onPress}
      shape={shape}
    />
  );
}

/** Rounded tonal card showing a read-only value on the trailing edge. */
export function InfoRow({
  colors,
  icon,
  label,
  value,
  shape,
}: {
  colors: MaterialColors;
  icon: IconSource;
  label: string;
  value: string;
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
          style={{ typography: "labelLarge", fontWeight: "600" }}
        >
          {value}
        </Text>
      }
    />
  );
}

/** Rounded tonal card with a supporting value line, optionally tappable (navigation). */
export function NavRow({
  colors,
  icon,
  label,
  value,
  onClick,
  shape,
}: {
  colors: MaterialColors;
  icon: IconSource;
  label: string;
  value: string;
  onClick?: () => void;
  shape?: RowShape;
}) {
  return (
    <GroupRow
      colors={colors}
      icon={icon}
      label={label}
      supporting={value}
      onClick={onClick}
      shape={shape}
    />
  );
}

/** Tonal grouped row for a received clip: the text, a relative timestamp, and a copy hint. */
export function ClipRow({
  colors,
  icon,
  trailingIcon,
  text,
  time,
  onPress,
  shape,
}: {
  colors: MaterialColors;
  icon: IconSource;
  trailingIcon: IconSource;
  text: string;
  time: string;
  onPress: () => void;
  shape?: RowShape;
}) {
  return (
    <GroupRow
      colors={colors}
      icon={icon}
      label={text}
      supporting={time}
      onClick={onPress}
      shape={shape}
      trailing={
        <Icon source={trailingIcon} size={20} tint={colors.onSurfaceVariant} />
      }
    />
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
