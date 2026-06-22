import { MaterialIcons } from "@expo/vector-icons";
import { Host, LinearProgressIndicator } from "@expo/ui/jetpack-compose";
import { graphicsLayer } from "@expo/ui/jetpack-compose/modifiers";
import {
  Modal,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  useColorScheme,
  View,
} from "react-native";

import { SEED, useM3Colors } from "@/components/m3";
import { Spacing } from "@/constants/theme";
import { useAppUpdate } from "./use-app-update";

// Vertical scale of the progress bar. The M3 *expressive* LinearProgressIndicator draws at a
// fixed track thickness (~4dp) and ignores a height modifier, so to thin it we shrink the drawn
// layer vertically: 1 = native thickness, 0.5 ≈ half. Width (the indeterminate sweep) is untouched.
const PROGRESS_SCALE_Y = 0.5;

/**
 * The "new version available" dialog, shown over any screen when {@link useAppUpdate} has a
 * pending update. Built from React Native primitives (a transparent `Modal` + a themed card)
 * rather than an `@expo/ui` Compose `Host`: the host crashes when it's unmounted mid-measure on a
 * short-lived surface like a dialog, and a modal is exactly that. Colors still come from the shared
 * Material 3 palette so it reads as the same design language as the Compose screens.
 *
 * Three shapes, one component:
 *  - **native** — a newer APK exists; the primary action opens the download (release notes shown).
 *  - **ota** — a JS update exists; the primary action fetches it and restarts the app in place.
 *  - **updating** — once the OTA fetch is in flight (`applyingOta`), the card switches to an
 *    "App is updating" state with an indeterminate native progress bar and a "Continue in
 *    background" escape hatch. The progress bar is the one Compose element here; it lives in a
 *    *fixed-size* Host (never `matchContents`) so it can't trip the unmount-mid-measure crash.
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
  const scheme = useColorScheme();

  const native = update?.kind === "native" ? update : null;

  return (
    <Modal
      visible={
        update != null
      }
      transparent
      animationType="fade"
      statusBarTranslucent
      // While the OTA is downloading the back gesture can't dismiss the dialog;
      // "Continue in background" is the only way out.
      onRequestClose={() => {
        if (!applyingOta) dismiss();
      }}
    >
      <View
        style={[
          styles.scrim,
          { backgroundColor: scheme === "dark" ? "#000000A6" : "#00000080" },
        ]}
      >
        <View
          style={[
            styles.card,
            { backgroundColor: colors.surfaceContainerHigh },
          ]}
        >
          <View
            style={[
              styles.iconCircle,
              { backgroundColor: colors.secondaryContainer },
            ]}
          >
            <MaterialIcons
              name={native ? "system-update" : "cloud-download"}
              size={26}
              color={colors.onSecondaryContainer}
            />
          </View>

          {applyingOta ? (
            //applyingOta
            <>
              <Text style={[styles.title, { color: colors.onSurface }]}>
                App is updating
              </Text>
              <Text
                style={[styles.message, { color: colors.onSurfaceVariant }]}
              >
                The app will restart automatically when it’s ready. You can continue using the app in the background.
              </Text>

              <Host
                style={styles.progressHost}
                seedColor={SEED}
                colorScheme={scheme}
              >
                <LinearProgressIndicator
                  color={colors.primary}
                  trackColor={colors.secondaryContainer}
                  modifiers={[
                    graphicsLayer({
                      scaleY: PROGRESS_SCALE_Y,
                      transformOriginY: 0.5,
                    }),
                  ]}
                />
              </Host>

              <View style={styles.actions}>
                <Pressable
                  onPress={continueInBackground}
                  style={({ pressed }) => [
                    styles.textButton,
                    pressed && styles.pressed,
                  ]}
                >
                  <Text
                    style={[styles.textButtonLabel, { color: colors.primary }]}
                  >
                    Continue in background
                  </Text>
                </Pressable>
              </View>
            </>
          ) : (
            <>
              <Text style={[styles.title, { color: colors.onSurface }]}>
                {native ? "New version available" : "Update available"}
              </Text>
              <Text
                style={[styles.message, { color: colors.onSurfaceVariant }]}
              >
                {native
                  ? `Version ${native.version} is ready. Download the new app to update — your settings and pairing are kept.`
                  : "A new update is ready. Download it and restart the app to apply it."}
              </Text>

              {native?.notes ? (
                <ScrollView
                  style={[
                    styles.notes,
                    { backgroundColor: colors.surfaceContainer },
                  ]}
                  contentContainerStyle={styles.notesContent}
                >
                  <Text
                    style={[
                      styles.notesText,
                      { color: colors.onSurfaceVariant },
                    ]}
                  >
                    {native.notes}
                  </Text>
                </ScrollView>
              ) : null}

              <View style={styles.actions}>
                <Pressable
                  onPress={dismiss}
                  style={({ pressed }) => [
                    styles.textButton,
                    pressed && styles.pressed,
                  ]}
                >
                  <Text
                    style={[styles.textButtonLabel, { color: colors.primary }]}
                  >
                    Later
                  </Text>
                </Pressable>
                <Pressable
                  onPress={native ? openDownload : applyOta}
                  style={({ pressed }) => [
                    styles.filledButton,
                    { backgroundColor: colors.primary },
                    pressed && styles.pressed,
                  ]}
                >
                  <Text
                    style={[
                      styles.filledButtonLabel,
                      { color: colors.onPrimary },
                    ]}
                  >
                    {native ? "Download" : "Update & restart"}
                  </Text>
                </Pressable>
              </View>
            </>
          )}
        </View>
      </View>
    </Modal>
  );
}

const styles = StyleSheet.create({
  scrim: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
    padding: Spacing.four,
  },
  card: {
    width: "100%",
    maxWidth: 360,
    borderRadius: 28,
    padding: Spacing.four,
    alignItems: "center",
    gap: Spacing.two,
  },
  iconCircle: {
    width: 56,
    height: 56,
    borderRadius: 28,
    alignItems: "center",
    justifyContent: "center",
    marginBottom: Spacing.one,
  },
  title: {
    fontSize: 22,
    fontWeight: "600",
    textAlign: "center",
  },
  message: {
    fontSize: 14,
    lineHeight: 18,
    textAlign: "center",
  },
  // Fixed height (never matchContents) so the Compose Host can't NPE if it unmounts
  // mid-measure when the app reloads or the dialog is backgrounded.
  progressHost: {
    alignSelf: "stretch",
    height: 12,
    marginTop: Spacing.two,
    backgroundColor: "transparent",
  },
  notes: {
    alignSelf: "stretch",
    maxHeight: 160,
    borderRadius: 16,
    marginTop: Spacing.one,
  },
  notesContent: {
    padding: Spacing.three,
  },
  notesText: {
    fontSize: 13,
    lineHeight: 19,
  },
  actions: {
    flexDirection: "row",
    alignSelf: "stretch",
    justifyContent: "flex-end",
    alignItems: "center",
    gap: Spacing.two,
    marginTop: Spacing.three,
  },
  textButton: {
    paddingVertical: Spacing.two,
    paddingHorizontal: Spacing.three,
    borderRadius: 20,
  },
  textButtonLabel: {
    fontSize: 14,
    fontWeight: "600",
  },
  filledButton: {
    paddingVertical: Spacing.two + 2,
    paddingHorizontal: Spacing.four,
    borderRadius: 20,
    alignItems: "center",
    justifyContent: "center",
  },
  filledButtonLabel: {
    fontSize: 14,
    fontWeight: "700",
  },
  pressed: {
    opacity: 0.7,
  },
});
