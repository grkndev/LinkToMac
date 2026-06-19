import { MaterialIcons } from '@expo/vector-icons';
import {
  Modal,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  useColorScheme,
  View,
} from 'react-native';

import { useM3Colors } from '@/components/m3';
import { Spacing } from '@/constants/theme';
import { useAppUpdate } from './use-app-update';

/**
 * The "new version available" dialog, shown over any screen when {@link useAppUpdate} has a
 * pending update. Built from React Native primitives (a transparent `Modal` + a themed card)
 * rather than an `@expo/ui` Compose `Host`: the host crashes when it's unmounted mid-measure on a
 * short-lived surface like a dialog, and a modal is exactly that. Colors still come from the shared
 * Material 3 palette so it reads as the same design language as the Compose screens.
 *
 * Two shapes, one component:
 *  - **native** — a newer APK exists; the primary action opens the download (release notes shown).
 *  - **ota** — a JS update exists; the primary action fetches it and restarts the app in place.
 */
export function UpdateModal() {
  const { update, applyOta, openDownload, dismiss } = useAppUpdate();
  const colors = useM3Colors();
  const scheme = useColorScheme();

  const native = update?.kind === 'native' ? update : null;

  const title = native ? 'New version available' : 'Update available';
  const message = native
    ? `Version ${native.version} is ready. Download the new app to update — your settings and pairing are kept.`
    : 'A new update is ready. Download it and restart the app to apply it.';
  const primaryLabel = native ? 'Download' : 'Update & restart';
  const onPrimary = native ? openDownload : applyOta;

  return (
    <Modal
      visible={
        update != null
      }
      transparent
      animationType="fade"
      statusBarTranslucent
      onRequestClose={dismiss}
    >
      <View
        style={[
          styles.scrim,
          { backgroundColor: scheme === 'dark' ? '#000000A6' : '#00000080' },
        ]}
      >
        <View style={[styles.card, { backgroundColor: colors.surfaceContainerHigh }]}>
          <View style={[styles.iconCircle, { backgroundColor: colors.secondaryContainer }]}>
            <MaterialIcons
              name={native ? 'system-update' : 'cloud-download'}
              size={26}
              color={colors.onSecondaryContainer}
            />
          </View>

          <Text style={[styles.title, { color: colors.onSurface }]}>{title}</Text>
          <Text style={[styles.message, { color: colors.onSurfaceVariant }]}>{message}</Text>

          {native?.notes ? (
            <ScrollView
              style={[styles.notes, { backgroundColor: colors.surfaceContainer }]}
              contentContainerStyle={styles.notesContent}
            >
              <Text style={[styles.notesText, { color: colors.onSurfaceVariant }]}>
                {native.notes}
              </Text>
            </ScrollView>
          ) : null}

          <View style={styles.actions}>
            <Pressable
              onPress={dismiss}
              style={({ pressed }) => [styles.textButton, pressed && styles.pressed]}
            >
              <Text style={[styles.textButtonLabel, { color: colors.primary }]}>Later</Text>
            </Pressable>
            <Pressable
              onPress={onPrimary}
              style={({ pressed }) => [
                styles.filledButton,
                { backgroundColor: colors.primary },
                pressed && styles.pressed,
              ]}
            >
              <Text style={[styles.filledButtonLabel, { color: colors.onPrimary }]}>
                {primaryLabel}
              </Text>
            </Pressable>
          </View>
        </View>
      </View>
    </Modal>
  );
}

const styles = StyleSheet.create({
  scrim: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    padding: Spacing.four,
  },
  card: {
    width: '100%',
    maxWidth: 360,
    borderRadius: 28,
    padding: Spacing.four,
    alignItems: 'center',
    gap: Spacing.two,
  },
  iconCircle: {
    width: 56,
    height: 56,
    borderRadius: 28,
    alignItems: 'center',
    justifyContent: 'center',
    marginBottom: Spacing.one,
  },
  title: {
    fontSize: 22,
    fontWeight: '600',
    textAlign: 'center',
  },
  message: {
    fontSize: 14,
    lineHeight: 20,
    textAlign: 'center',
  },
  notes: {
    alignSelf: 'stretch',
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
    flexDirection: 'row',
    alignSelf: 'stretch',
    justifyContent: 'flex-end',
    alignItems: 'center',
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
    fontWeight: '600',
  },
  filledButton: {
    paddingVertical: Spacing.two + 2,
    paddingHorizontal: Spacing.four,
    borderRadius: 20,
  },
  filledButtonLabel: {
    fontSize: 14,
    fontWeight: '700',
  },
  pressed: {
    opacity: 0.7,
  },
});
