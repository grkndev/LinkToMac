import {
  ListItem,
  Surface,
  Switch,
  Text,
  type MaterialColors,
} from "@expo/ui/jetpack-compose";
import * as Haptics from "expo-haptics";
import { fillMaxWidth } from "@expo/ui/jetpack-compose/modifiers";

import { type IconSource } from "@/components/icons";
import { IconCircle, groupShape, tonal, type RowShape } from "@/components/m3";

/**
 * The grouped-list row vocabulary shared by Settings and About — one rounded tonal card per row,
 * each with a leading {@link IconCircle}. Kept here (instead of duplicated per screen) so both
 * screens read as the same Material 3 design language. Every row accepts an optional `shape` so a
 * {@link Group} wrapper can clone position-aware corner radii onto it.
 */

/** Rounded tonal card that toggles its switch when tapped anywhere on the row. */
export function SwitchRow({
  colors,
  icon,
  label,
  hint,
  value,
  onValueChange,
  shape = groupShape(true, true),
}: {
  colors: MaterialColors;
  icon: IconSource;
  label: string;
  hint?: string;
  value: boolean;
  onValueChange: (value: boolean) => void;
  shape?: RowShape;
}) {
  const t = tonal(colors, "secondary");
  return (
    <Surface
      color={colors.surfaceContainerHigh}
      shape={shape}
      modifiers={[fillMaxWidth()]}
      checked={value}
      onCheckedChange={(value) => {
        onValueChange(value);
        Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium).catch(() => {});
      }}
    >
      <ListItem
        colors={{ containerColor: "transparent" }}
        modifiers={[fillMaxWidth()]}
      >
        <ListItem.LeadingContent>
          <IconCircle source={icon} container={t.container} on={t.on} />
        </ListItem.LeadingContent>
        <ListItem.HeadlineContent>
          <Text
            color={colors.onSurface}
            style={{ typography: "bodyLarge", fontWeight: "500" }}
          >
            {label}
          </Text>
        </ListItem.HeadlineContent>
        {hint ? (
          <ListItem.SupportingContent>
            <Text
              color={colors.onSurfaceVariant}
              style={{ typography: "bodyMedium" }}
            >
              {hint}
            </Text>
          </ListItem.SupportingContent>
        ) : null}
        <ListItem.TrailingContent>
          <Switch value={value} onCheckedChange={onValueChange} />
        </ListItem.TrailingContent>
      </ListItem>
    </Surface>
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
  shape = groupShape(true, true),
}: {
  colors: MaterialColors;
  icon: IconSource;
  label: string;
  hint?: string;
  destructive?: boolean;
  onPress: () => void;
  shape?: RowShape;
}) {
  const t = tonal(colors, destructive ? "error" : "secondary");
  const labelColor = destructive ? colors.error : colors.onSurface;
  return (
    <Surface
      color={colors.surfaceContainerHigh}
      shape={shape}
      modifiers={[fillMaxWidth()]}
      onClick={onPress}
    >
      <ListItem
        colors={{ containerColor: "transparent" }}
        modifiers={[fillMaxWidth()]}
      >
        <ListItem.LeadingContent>
          <IconCircle source={icon} container={t.container} on={t.on} />
        </ListItem.LeadingContent>
        <ListItem.HeadlineContent>
          <Text
            color={labelColor}
            style={{ typography: "bodyLarge", fontWeight: "500" }}
          >
            {label}
          </Text>
        </ListItem.HeadlineContent>
        {hint ? (
          <ListItem.SupportingContent>
            <Text
              color={colors.onSurfaceVariant}
              style={{ typography: "bodyMedium" }}
            >
              {hint}
            </Text>
          </ListItem.SupportingContent>
        ) : null}
      </ListItem>
    </Surface>
  );
}

/** Rounded tonal card showing a read-only value on the trailing edge. */
export function InfoRow({
  colors,
  icon,
  label,
  value,
  shape = groupShape(true, true),
}: {
  colors: MaterialColors;
  icon: IconSource;
  label: string;
  value: string;
  shape?: RowShape;
}) {
  const t = tonal(colors, "secondary");
  return (
    <Surface
      color={colors.surfaceContainerHigh}
      shape={shape}
      modifiers={[fillMaxWidth()]}
    >
      <ListItem
        colors={{ containerColor: "transparent" }}
        modifiers={[fillMaxWidth()]}
      >
        <ListItem.LeadingContent>
          <IconCircle source={icon} container={t.container} on={t.on} />
        </ListItem.LeadingContent>
        <ListItem.HeadlineContent>
          <Text
            color={colors.onSurface}
            style={{ typography: "bodyLarge", fontWeight: "500" }}
          >
            {label}
          </Text>
        </ListItem.HeadlineContent>
        <ListItem.TrailingContent>
          <Text
            color={colors.onSurfaceVariant}
            style={{ typography: "labelLarge", fontWeight: "600" }}
          >
            {value}
          </Text>
        </ListItem.TrailingContent>
      </ListItem>
    </Surface>
  );
}
