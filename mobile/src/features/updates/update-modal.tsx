import {
  Box,
  Column,
  Host,
  Icon,
  LinearProgressIndicator,
  ModalBottomSheet,
  Shape,
  Surface,
  type MaterialColors,
  type ModalBottomSheetRef,
} from "@expo/ui/jetpack-compose";
import { Text } from "@/components/text";
import {
  background,
  clip,
  fillMaxWidth,
  graphicsLayer,
  height,
  padding,
  paddingAll,
  Shapes,
  size,
  verticalScroll,
} from "@expo/ui/jetpack-compose/modifiers";
import { useRef } from "react";

import { useIcons } from "@/components/icons";
import { useHostTheme, useM3Colors } from "@/components/m3";
import { SmoothProgress } from "@/components/motion";
import { SheetButton, SheetText } from "@/components/sheet";
import { Spacing } from "@/constants/theme";
import type { NativeUpdate } from "./check";
import { useAppUpdate, type PendingUpdate } from "./use-app-update";

/** 20dp-radius rounded-square tile behind the sheet's icon (the design's update badge). */
const TILE = Shape.RoundedCorner({
  cornerRadii: { topStart: 20, topEnd: 20, bottomStart: 20, bottomEnd: 20 },
});

// Vertical scale of the progress bar. The M3 *expressive* LinearProgressIndicator draws at a
// fixed track thickness (~4dp) and ignores a height modifier, so to thin it we shrink the drawn
// layer vertically: 1 = native thickness, 0.5 ≈ half. Width (the indeterminate sweep) is untouched.
const PROGRESS_SCALE_Y = 0.5;

/**
 * The "new version available" prompt, shown over any screen when {@link useAppUpdate} has a
 * pending update — an M3 modal bottom sheet in the same language as the unpair ConfirmSheet
 * (tonal icon badge, centered headline + consequence line, house sheet buttons). The anchoring
 * Host is fixed-size (never `matchContents`): the sheet renders in its own window, and a
 * matchContents Host can NPE if it unmounts mid-measure.
 *
 * Shapes, one component:
 *  - **native** — a newer APK exists. The background updater usually has fetched it already, so
 *    the primary action is **Install** (opens the system installer, where the user confirms). If it
 *    hasn't (automatic download off, or it failed) the action is **Download**, which fetches it
 *    here and flips the sheet to a progress state; with no APK asset it falls back to the browser.
 *  - **ota** — a JS update exists; the primary action fetches it and restarts the app in place.
 *  - **updating** — an OTA fetch in flight (`applyingOta`) or a native APK download, with a
 *    progress bar and a "Continue in background" escape hatch; swipe/back/scrim dismissal is
 *    disabled so that hatch is the only way out.
 *
 * Every hook action ends in `setUpdate(null)`, which unmounts the sheet instantly — so each
 * button animates `hide()` first, then fires the action. "Update & restart" is the exception:
 * it keeps the sheet up and the content swaps to the updating state in place.
 */
export function UpdateModal() {
  const {
    update,
    applyingOta,
    applyOta,
    continueInBackground,
    startNativeUpdate,
    dismiss,
  } = useAppUpdate();
  const colors = useM3Colors();
  const hostTheme = useHostTheme();
  const sheetRef = useRef<ModalBottomSheetRef>(null);
  const downloadingNative = update?.kind === "native" && update.state === "downloading";
  // Either kind of in-flight fetch pins the sheet open (see the escape hatch above).
  const busy = applyingOta || downloadingNative;

  // Animate the sheet away, then fire the action (which unmounts it). The hide() is raced
  // against a timeout because Compose's sheetState.hide() SUSPENDS FOREVER while
  // sheetGesturesEnabled is false (the applyingOta state) — an un-raced await left
  // "Continue in background" dead and the sheet inescapable. Unmounting is what actually
  // removes the window, so timing out just skips the animation, never the action.
  const hideThen = async (action: () => void) => {
    await Promise.race([
      sheetRef.current?.hide() ?? Promise.resolve(),
      new Promise((resolve) => setTimeout(resolve, 600)),
    ]);
    action();
  };

  return (
    <Host style={{ width: 1, height: 1 }} {...hostTheme}>
      {update != null && (
        <ModalBottomSheet
          ref={sheetRef}
          onDismissRequest={() => {
            if (!busy) dismiss();
          }}
          containerColor={colors.surfaceContainerLow}
          // One dynamic snap point at full content height — the default partial snap cut the
          // release notes + Download button off mid-sheet.
          skipPartiallyExpanded
          // No handle while updating: the sheet can't be swiped away then, so don't offer the grip.
          showDragHandle={!busy}
          sheetGesturesEnabled={!busy}
          properties={{
            shouldDismissOnBackPress: !busy,
            shouldDismissOnClickOutside: !busy,
          }}
        >
          <Column
            horizontalAlignment="start"
            verticalArrangement={{ spacedBy: Spacing.three }}
            modifiers={[
              fillMaxWidth(),
              padding(Spacing.four, Spacing.two, Spacing.four, Spacing.five),
            ]}
          >
            {applyingOta ? (
              <ApplyingOta
                colors={colors}
                onContinueInBackground={() => hideThen(continueInBackground)}
              />
            ) : update.kind === "native" && update.state === "downloading" ? (
              <DownloadingNative
                colors={colors}
                version={update.version}
                progress={update.progress}
                onContinueInBackground={() => hideThen(continueInBackground)}
              />
            ) : (
              <UpdateAvailable
                colors={colors}
                update={update}
                onPrimary={
                  update.kind !== "native"
                    ? () => applyOta()
                    : // Download keeps the sheet up (it becomes the progress state); Install and the
                      // browser fallback hand off to something else, so the sheet leaves first.
                      update.state !== "ready" && update.downloadable
                      ? startNativeUpdate
                      : () => hideThen(startNativeUpdate)
                }
                onLater={() => hideThen(dismiss)}
              />
            )}
          </Column>
        </ModalBottomSheet>
      )}
    </Host>
  );
}

/** The in-flight OTA state: headline, indeterminate progress bar, background escape hatch. */
function ApplyingOta({
  colors,
  onContinueInBackground,
}: {
  colors: MaterialColors;
  onContinueInBackground: () => void;
}) {
  return (
    <>
      <SheetText
        colors={colors}
        title="App is updating"
        message="The app will restart automatically when it’s ready. You can continue using the app in the background."
      />

      <LinearProgressIndicator
        color={colors.primary}
        trackColor={colors.secondaryContainer}
        modifiers={[
          fillMaxWidth(),
          graphicsLayer({
            scaleY: PROGRESS_SCALE_Y,
            transformOriginY: 0.5,
          }),
        ]}
      />

      <SheetButton
        colors={colors}
        variant="tonal"
        label="Continue in background"
        onClick={onContinueInBackground}
        width={1}
      />
    </>
  );
}

/** A native APK download in flight: percentage, a determinate bar, and the background escape hatch. */
function DownloadingNative({
  colors,
  version,
  progress,
  onContinueInBackground,
}: {
  colors: MaterialColors;
  version: string;
  progress: number;
  onContinueInBackground: () => void;
}) {
  return (
    <>
      <SheetText
        colors={colors}
        title={`Downloading ${progress}%`}
        message={`Version ${version} is downloading. You'll get a notification when it's ready to install.`}
      />
      <SmoothProgress
        progress={progress / 100}
        color={colors.primary}
        trackColor={colors.secondaryContainer}
        thickness={6}
      />
      <SheetButton
        colors={colors}
        variant="tonal"
        label="Continue in background"
        onClick={onContinueInBackground}
        width={1}
      />
    </>
  );
}

/** The prompt state: headline, optional release notes, and the stacked action buttons. */
function UpdateAvailable({
  colors,
  update,
  onPrimary,
  onLater,
}: {
  colors: MaterialColors;
  update: PendingUpdate;
  onPrimary: () => void;
  onLater: () => void;
}) {
  const native = update.kind === "native" ? update : null;
  const icons = useIcons();
  return (
    <>
      <Surface color={colors.primaryContainer} shape={TILE} modifiers={[size(56, 56)]}>
        <Box contentAlignment="center" modifiers={[size(56, 56)]}>
          <Icon source={icons.systemUpdate} size={28} tint={colors.onPrimaryContainer} />
        </Box>
      </Surface>
      <SheetText
        colors={colors}
        title={native ? (native.state === "ready" ? "Update ready to install" : "New version available") : "Update available"}
        message={
          native
            ? nativeMessage(native)
            : "A new update is ready. Download it and restart the app to apply it."
        }
      />

      {native?.notes ? (
        <Column
          modifiers={[
            fillMaxWidth(),
            height(150),
            clip(Shapes.RoundedCorner(16)),
            background(colors.surfaceContainerHigh),
            verticalScroll(),
          ]}
        >
          <Column modifiers={[paddingAll(Spacing.three)]}>
            <Text
              color={colors.onSurfaceVariant}
              style={{ typography: "bodySmall" }}
            >
              {native.notes}
            </Text>
          </Column>
        </Column>
      ) : null}

      {/* Stacked actions: full-width filled primary, then "Later" as a small text (label)
          button beneath. Sized with fillMaxWidth, NOT weight() — weight is ignored on
          Button inside the sheet. */}
      <Column
        horizontalAlignment="center"
        verticalArrangement={{ spacedBy: 2 }}
        modifiers={[fillMaxWidth()]}
      >
        <SheetButton
          colors={colors}
          variant="filled"
          icon={native ? (native.state === "ready" ? icons.systemUpdate : icons.download) : undefined}
          label={native ? (native.state === "ready" ? "Install" : "Download") : "Update & restart"}
          onClick={onPrimary}
          width={1}
        />
        <SheetButton
          colors={colors}
          variant="text"
          label="Later"
          onClick={onLater}
          width={1}
        />
      </Column>
    </>
  );
}

/** The body text for a native update, by how far the background updater got. */
function nativeMessage(u: NativeUpdate): string {
  const kept = "your settings and pairing are kept";
  switch (u.state) {
    case "ready":
      return `Version ${u.version} is downloaded. Tap Install and confirm in the system dialog — ${kept}.`;
    case "failed":
      return `Version ${u.version} couldn't be downloaded automatically${u.error ? ` (${u.error})` : ""}. Download it again to update — ${kept}.`;
    default:
      return u.downloadable
        ? `Version ${u.version} is available. Download it here and install with one tap — ${kept}.`
        : `Version ${u.version} is available. Download the new app to update — ${kept}.`;
  }
}
