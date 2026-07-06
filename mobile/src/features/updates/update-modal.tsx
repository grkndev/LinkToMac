import {
  Column,
  Host,
  LinearProgressIndicator,
  ModalBottomSheet,
  Text,
  type MaterialColors,
  type ModalBottomSheetRef,
} from "@expo/ui/jetpack-compose";
import {
  background,
  clip,
  fillMaxWidth,
  graphicsLayer,
  height,
  padding,
  paddingAll,
  Shapes,
  verticalScroll,
} from "@expo/ui/jetpack-compose/modifiers";
import { useRef } from "react";

import { useIcons } from "@/components/icons";
import { IconCircle, tonal, useM3Colors } from "@/components/m3";
import { SheetButton, SheetText } from "@/components/sheet";
import { Spacing } from "@/constants/theme";
import { useAppUpdate, type PendingUpdate } from "./use-app-update";

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
 * Three shapes, one component:
 *  - **native** — a newer APK exists; the primary action opens the download (release notes shown).
 *  - **ota** — a JS update exists; the primary action fetches it and restarts the app in place.
 *  - **updating** — once the OTA fetch is in flight (`applyingOta`), the sheet switches to an
 *    "App is updating" state with an indeterminate progress bar and a "Continue in background"
 *    escape hatch; swipe/back/scrim dismissal is disabled so that hatch is the only way out.
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
    openDownload,
    dismiss,
  } = useAppUpdate();
  const colors = useM3Colors();
  const icons = useIcons();
  const tone = tonal(colors, "secondary");
  const sheetRef = useRef<ModalBottomSheetRef>(null);

  const hideThen = async (action: () => void) => {
    await sheetRef.current?.hide();
    action();
  };

  return (
    <Host style={{ width: 1, height: 1 }}>
      {update != null && (
        <ModalBottomSheet
          ref={sheetRef}
          onDismissRequest={() => {
            if (!applyingOta) dismiss();
          }}
          containerColor={colors.surfaceContainerLow}
          sheetGesturesEnabled={!applyingOta}
          properties={{
            shouldDismissOnBackPress: !applyingOta,
            shouldDismissOnClickOutside: !applyingOta,
          }}
        >
          <Column
            horizontalAlignment="center"
            verticalArrangement={{ spacedBy: Spacing.three }}
            modifiers={[
              padding(Spacing.four, Spacing.two, Spacing.four, Spacing.five),
            ]}
          >
            <IconCircle
              source={icons.update}
              container={tone.container}
              on={tone.on}
              diameter={56}
              iconSize={28}
            />

            {applyingOta ? (
              <ApplyingOta
                colors={colors}
                onContinueInBackground={() => hideThen(continueInBackground)}
              />
            ) : (
              <UpdateAvailable
                colors={colors}
                update={update}
                onPrimary={
                  update.kind === "native"
                    ? () => hideThen(openDownload)
                    : () => applyOta()
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
        variant="text"
        label="Continue in background"
        onClick={onContinueInBackground}
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
  return (
    <>
      <SheetText
        colors={colors}
        title={native ? "New version available" : "Update available"}
        message={
          native
            ? `Version ${native.version} is ready. Download the new app to update — your settings and pairing are kept.`
            : "A new update is ready. Download it and restart the app to apply it."
        }
      />

      {native?.notes ? (
        <Column
          modifiers={[
            fillMaxWidth(),
            height(150),
            clip(Shapes.RoundedCorner(16)),
            background(colors.surfaceContainer),
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
          label={native ? "Download" : "Update & Restart"}
          onClick={onPrimary}
          width={1}
        />
        <SheetButton
          colors={colors}
          variant="text"
          label="Later"
          onClick={onLater}
          fontSize={12}
        />
      </Column>
    </>
  );
}
