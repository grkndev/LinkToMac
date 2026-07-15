import {
  Box,
  Checkbox,
  Column,
  Icon,
  Surface,
  Text,
  DockedSearchBar,
} from "@expo/ui/jetpack-compose";
import type { MaterialColors } from "@expo/ui/jetpack-compose";
import {
  clip,
  fillMaxWidth,
  padding,
  Shapes,
  size,
  weight,
} from "@expo/ui/jetpack-compose/modifiers";
import { memo, useDeferredValue, useState } from "react";

import { useIcons, type IconSource } from "@/components/icons";
import { GroupRow } from "@/components/rows";
import {
  ButtonGroup,
  GROUP_GAP,
  groupShape,
  groupShapeH,
  useM3Colors,
  type RowShape,
} from "@/components/m3";
import { M3Screen } from "@/components/m3-screen";
import { Spacing } from "@/constants/theme";
import { haptic } from "@/lib/haptics";
import type { NotifFilterMode } from "@/features/selfadb/client";
import { useNotificationAppFilter } from "@/features/selfadb/use-notification-app-filter";

/**
 * The per-app mirroring picker (Notifications ▸ Select apps). The checkmark on each row always
 * answers "will this app's notifications reach the Mac?" — in "All apps" (exclude) mode
 * unchecking blocks an app, in "Only selected" (include) mode checking allows one. The filter
 * is enforced natively by NotificationListener on every post, so changes apply immediately.
 *
 * Perf: the list is ~100 Compose rows in one unvirtualized Column, so it renders through
 * DEFERRED copies of mode/selection/search while the segmented button, hint and search field
 * update urgently — a mode flip lands on screen instantly and the row checkmarks catch up a
 * beat later instead of blocking the tap. Rows are memoized on primitive props (and the
 * hook's callbacks are identity-stable), so a single row toggle or a search keystroke only
 * re-renders the rows that actually changed.
 */
export default function NotificationAppsScreen() {
  const colors = useM3Colors();
  const icons = useIcons();
  const { apps, mode, setMode, include, exclude, toggleApp } =
    useNotificationAppFilter();
  const [query, setQuery] = useState("");

  // Deferred pair for the list. Both lag together (computed from the same urgent render),
  // so a row never sees mode "include" with the exclude set.
  const listMode = useDeferredValue(mode);
  const listSet = useDeferredValue(mode === "include" ? include : exclude);
  const listQuery = useDeferredValue(query);

  const pickMode = (m: NotifFilterMode) => {
    if (m !== mode) haptic();
    setMode(m);
  };

  const needle = listQuery.trim().toLowerCase();
  const shown = apps?.filter(
    (a) => !needle || a.label.toLowerCase().includes(needle),
  );

  return (
    <M3Screen paddingTop={Spacing.three} spacing={Spacing.three}>
      <ButtonGroup>
        <ModeTile
          colors={colors}
          label="All apps"
          selected={mode === "exclude"}
          onPress={() => pickMode("exclude")}
        />
        <ModeTile
          colors={colors}
          label="Only selected"
          selected={mode === "include"}
          onPress={() => pickMode("include")}
        />
      </ButtonGroup>
      <Text
        color={colors.onSurfaceVariant}
        style={{ typography: "bodyMedium" }}
      >
        {mode === "exclude"
          ? "Every app is mirrored to your Mac — uncheck the ones you want to keep off it."
          : "Nothing is mirrored to your Mac except the apps you check."}
      </Text>
      <DockedSearchBar onQueryChange={setQuery} modifiers={[fillMaxWidth()]}>
        <DockedSearchBar.Placeholder>
          <Text color={colors.onSurfaceVariant}>Search apps</Text>
        </DockedSearchBar.Placeholder>
        <DockedSearchBar.LeadingIcon>
<Icon source={icons.search} size={24} tint={colors.onSurfaceVariant} />
        </DockedSearchBar.LeadingIcon>
      </DockedSearchBar>
      {apps == null ? (
        <Text
          color={colors.onSurfaceVariant}
          style={{ typography: "bodyMedium" }}
        >
          Loading apps…
        </Text>
      ) : shown!.length === 0 ? (
        <Text
          color={colors.onSurfaceVariant}
          style={{ typography: "bodyMedium" }}
        >
          No apps match your search.
        </Text>
      ) : (
        <Column
          modifiers={[fillMaxWidth()]}
          verticalArrangement={{ spacedBy: GROUP_GAP }}
        >
          {shown!.map((app, i) => (
            <AppRow
              key={app.pkg}
              colors={colors}
              pkg={app.pkg}
              label={app.label}
              icon={app.icon}
              fallbackIcon={icons.notifications}
              mirrored={
                listMode === "include"
                  ? listSet.has(app.pkg)
                  : !listSet.has(app.pkg)
              }
              onToggle={toggleApp}
              shape={SHAPES[shapeKey(i, shown!.length)]}
            />
          ))}
        </Column>
      )}
    </M3Screen>
  );
}

/**
 * One segment of the mode selector — a connected tonal button in the {@link ButtonGroup}
 * language of Home's quick actions. Deliberately NOT an M3 SegmentedButton: its built-in
 * checkmark plays a scale-in animation that freezes mid-flight (visibly oversized) while the
 * deferred app-list flush hogs the UI thread. Here the selected state is a plain container
 * color flip, so there's nothing to stutter.
 */
function ModeTile({
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
  return (
    <Surface
      color={selected ? colors.secondaryContainer : colors.surfaceContainerHigh}
      shape={shape}
      onClick={onPress}
      modifiers={[weight(1)]}
    >
      <Box
        contentAlignment="center"
        modifiers={[
          fillMaxWidth(),
          padding(Spacing.two, Spacing.three, Spacing.two, Spacing.three),
        ]}
      >
        <Text
          color={
            selected ? colors.onSecondaryContainer : colors.onSurfaceVariant
          }
          style={{ typography: "labelLarge", fontWeight: "600" }}
        >
          {label}
        </Text>
      </Box>
    </Surface>
  );
}

// Precomputed module-level shapes: stable identities so a row's `shape` prop never breaks
// its memo (Group's cloneElement would mint a fresh object per row per render).
const SHAPES = {
  single: groupShape(true, true),
  first: groupShape(true, false),
  mid: groupShape(false, false),
  last: groupShape(false, true),
} as const;

function shapeKey(i: number, len: number): keyof typeof SHAPES {
  if (len === 1) return "single";
  if (i === 0) return "first";
  if (i === len - 1) return "last";
  return "mid";
}

/** One memoized app row: primitive props only, so mode flips / search keystrokes / other
 *  rows' toggles skip it entirely unless its own checkmark or group position changed. */
const AppRow = memo(function AppRow({
  colors,
  pkg,
  label,
  icon,
  fallbackIcon,
  mirrored,
  onToggle,
  shape,
}: {
  colors: MaterialColors;
  pkg: string;
  label: string;
  icon: string | null;
  fallbackIcon: IconSource;
  mirrored: boolean;
  onToggle: (pkg: string) => void;
  shape: RowShape;
}) {
  return (
    <GroupRow
      colors={colors}
      leading={icon ? <AppIcon uri={icon} /> : undefined}
      icon={icon ? undefined : fallbackIcon}
      label={label}
      checked={mirrored}
      onCheckedChange={() => onToggle(pkg)}
      trailing={<Checkbox value={mirrored} />}
      shape={shape}
    />
  );
});

/** Full-color launcher icon in the leading slot — clipped to a circle so the grid of rows
 *  reads like the tonal IconCircles elsewhere; tint={null} keeps the original colors. */
function AppIcon({ uri }: { uri: string }) {
  return (
    <Box
      contentAlignment="center"
      modifiers={[size(40, 40), clip(Shapes.Circle)]}
    >
      <Icon source={{ uri }} size={40} tint={null} />
    </Box>
  );
}
