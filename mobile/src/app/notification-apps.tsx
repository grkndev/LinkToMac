import {
  Box,
  Checkbox,
  Column,
  Icon,
  DockedSearchBar,
  LazyColumn,
} from "@expo/ui/jetpack-compose";
import { Text } from "@/components/text";
import type { MaterialColors } from "@expo/ui/jetpack-compose";
import {
  clip,
  fillMaxSize,
  fillMaxWidth,
  imePadding,
  padding,
  Shapes,
  size,
  weight,
} from "@expo/ui/jetpack-compose/modifiers";
import { memo, useDeferredValue, useEffect, useState } from "react";
import { useSafeAreaInsets } from "react-native-safe-area-context";

import { useIcons, type IconSource } from "@/components/icons";
import { GroupRow } from "@/components/rows";
import { ButtonGroup, ModeTile, useM3Colors } from "@/components/m3";
import { M3Host } from "@/components/m3-screen";
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
 * Perf: the ~100 rows live in a LazyColumn under a fixed header, so only the rows on screen are
 * composed (a plain Column composed all of them in one frame: a 400+ ms stall on open). The list also
 * renders through DEFERRED copies of mode/selection/search while the segmented button, hint and search field
 * update urgently — a mode flip lands on screen instantly and the row checkmarks catch up a
 * beat later instead of blocking the tap. Rows are memoized on primitive props (and the
 * hook's callbacks are identity-stable), so a single row toggle or a search keystroke only
 * re-renders the rows that actually changed.
 */
/** First batch of rows (enough to fill the screen), then ROW_BATCH more every ROW_BATCH_MS. */
const INITIAL_ROWS = 12;
const ROW_BATCH = 16;
const ROW_BATCH_MS = 60;
/** The stack's fade transition takes ~300 ms; start the remaining rows after it. */
const AFTER_TRANSITION_MS = 400;

export default function NotificationAppsScreen() {
  const colors = useM3Colors();
  const icons = useIcons();
  const insets = useSafeAreaInsets();
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
  const matching = apps?.filter(
    (a) => !needle || a.label.toLowerCase().includes(needle),
  );

  // Progressive mount: a LazyColumn only defers COMPOSITION — React Native still creates the native
  // views for every child up front (~8 Expo views per row), which on open was a ~250 ms single-frame
  // stall for ~100 rows. So hand it the first batch now and the rest in small batches on later frames.
  const [limit, setLimit] = useState(INITIAL_ROWS);
  const total = matching?.length ?? 0;
  useEffect(() => {
    if (limit >= total) return;
    // The first extra batch waits for the screen transition to finish (so the animation only pays
    // for the initial rows); the rest follow back to back.
    const wait = limit === INITIAL_ROWS ? AFTER_TRANSITION_MS : ROW_BATCH_MS;
    const t = setTimeout(() => setLimit((l) => l + ROW_BATCH), wait);
    return () => clearTimeout(t);
  }, [limit, total]);
  const shown = matching?.slice(0, limit);

  return (
    <M3Host>
      <Column modifiers={[fillMaxSize(), imePadding()]}>
        {/* Fixed header: the list below scrolls under it (and is virtualized — see the Perf note). */}
        <Column
          modifiers={[fillMaxWidth(), padding(Spacing.three, Spacing.three, Spacing.three, 0)]}
          verticalArrangement={{ spacedBy: Spacing.three }}
        >
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
          <Text color={colors.onSurfaceVariant} style={{ typography: "bodyMedium" }}>
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
        </Column>

        {apps == null || total === 0 ? (
          <Box modifiers={[fillMaxWidth(), padding(Spacing.three, Spacing.three, Spacing.three, 0)]}>
            <Text color={colors.onSurfaceVariant} style={{ typography: "bodyMedium" }}>
              {apps == null ? "Loading apps…" : "No apps match your search."}
            </Text>
          </Box>
        ) : (
          // A LazyColumn composes only the rows on screen (the old plain Column composed all ~100 in
          // one frame — a 400+ ms stall on open). It needs a bounded height, hence weight(1) here
          // instead of the screen-wide verticalScroll.
          <Column modifiers={[fillMaxWidth(), weight(1)]}>
            <LazyColumn
              modifiers={[fillMaxSize()]}
              contentPadding={{
                start: Spacing.three,
                end: Spacing.three,
                top: Spacing.two,
                bottom: insets.bottom + Spacing.three,
              }}
            >
              {shown!.map((app) => (
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
                />
              ))}
            </LazyColumn>
          </Column>
        )}
      </Column>
    </M3Host>
  );
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
}: {
  colors: MaterialColors;
  pkg: string;
  label: string;
  icon: string | null;
  fallbackIcon: IconSource;
  mirrored: boolean;
  onToggle: (pkg: string) => void;
}) {
  return (
    <GroupRow
      colors={colors}
      leading={icon ? <AppIcon uri={icon} /> : undefined}
      icon={icon ? undefined : fallbackIcon}
      label={label}
      color="transparent"
      checked={mirrored}
      onCheckedChange={() => onToggle(pkg)}
      trailing={<Checkbox value={mirrored} />}
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
