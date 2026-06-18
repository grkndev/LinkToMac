import { Host, Switch } from "@expo/ui/jetpack-compose";
import * as Haptics from "expo-haptics";
import { useRouter } from "expo-router";
import { useState } from "react";
import { Alert, Pressable, StyleSheet, Text, TextInput, useColorScheme, View } from "react-native";
import { KeyboardAwareScrollView } from "react-native-keyboard-controller";
import { useSafeAreaInsets } from "react-native-safe-area-context";

import { SEED, useM3Colors } from "@/components/m3";
import { Spacing } from "@/constants/theme";
import { usePairing } from "@/features/relay/pairing-context";
import { blankServerConfig } from "@/features/relay/server-config";

/**
 * Manual relay server configuration: host / port / password / TLS. Seeds from the saved
 * ServerConfig (which a v2 QR scan can fill in for you) or the defaults, and re-pushes the
 * native relay connection on save. RN form (controlled TextInputs) with the native Jetpack
 * Compose Switch for the TLS toggle. This screen is also the entry point the future LAN-direct
 * mode reuses (type a local IP, toggle TLS off, or pin a self-signed cert).
 */
export default function ServerConfigScreen() {
  const router = useRouter();
  const colors = useM3Colors();
  const scheme = useColorScheme();
  const insets = useSafeAreaInsets();
  const { server, setServer } = usePairing();

  const initial = server ?? blankServerConfig();
  const [host, setHost] = useState(initial.host);
  const [port, setPort] = useState(String(initial.port));
  const [token, setToken] = useState(initial.token);
  const [secure, setSecure] = useState(initial.secure);
  const [lanEnabled, setLanEnabled] = useState(initial.lanEnabled ?? true);
  const [lanPort, setLanPort] = useState(String(initial.lanPort ?? 53124));
  const [lanHost, setLanHost] = useState(initial.lanHost ?? "");
  const [saving, setSaving] = useState(false);

  // Tapping anywhere on the row (or the switch) sets the same target value + haptic, matching
  // the Settings rows. Both call this with the new value, so a stray double-fire is idempotent.
  const onSecureChange = (next: boolean) => {
    setSecure(next);
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium).catch(() => {});
  };

  const onLanChange = (next: boolean) => {
    setLanEnabled(next);
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium).catch(() => {});
  };

  const onSave = async () => {
    const trimmedHost = host.trim();
    const portNum = Number(port.trim());
    const lanPortNum = Number(lanPort.trim());
    const trimmedLanHost = lanHost.trim();

    // At least one transport: a relay host, or LAN-direct enabled.
    if (!trimmedHost && !lanEnabled) {
      Alert.alert("Nothing to connect", "Enter a relay server address or enable LAN-direct.");
      return;
    }
    if (trimmedHost && (!Number.isInteger(portNum) || portNum < 1 || portNum > 65535)) {
      Alert.alert("Invalid port", "Enter a relay port between 1 and 65535.");
      return;
    }
    if (lanEnabled && (!Number.isInteger(lanPortNum) || lanPortNum < 1 || lanPortNum > 65535)) {
      Alert.alert("Invalid LAN port", "Enter a LAN port between 1 and 65535.");
      return;
    }
    setSaving(true);
    try {
      await setServer({
        host: trimmedHost,
        port: trimmedHost ? portNum : initial.port,
        secure,
        token: token.trim(),
        lanEnabled,
        ...(lanEnabled ? { lanPort: lanPortNum } : {}),
        ...(trimmedLanHost ? { lanHost: trimmedLanHost } : {}),
        // Preserve a pinned cert (e.g. from a QR) across manual edits.
        ...(server?.certFingerprint ? { certFingerprint: server.certFingerprint } : {}),
      });
      router.back();
    } finally {
      setSaving(false);
    }
  };

  return (
    <KeyboardAwareScrollView
      style={[styles.root, { backgroundColor: colors.background }]}
      contentContainerStyle={{ padding: Spacing.four, paddingBottom: insets.bottom + Spacing.five, gap: Spacing.four }}
      keyboardShouldPersistTaps="handled"
      // Park the focused input this many px above the keyboard (auto-scrolls on focus).
      bottomOffset={Spacing.three}
    >
        <Text style={[styles.intro, { color: colors.onSurfaceVariant }]}>
          On the same Wi-Fi the app connects straight to your Mac (LAN-direct, no relay). A relay
          server is only needed to sync while you're away — leave it blank for LAN-only. The
          password must match the server's password; use TLS (wss://) over the internet.
        </Text>

        <Field label="Server address" hint="Domain (for TLS) or IP — optional if LAN-direct is on" colors={colors}>
          <TextInput
            value={host}
            onChangeText={setHost}
            placeholder="relay.example.com"
            placeholderTextColor={colors.onSurfaceVariant}
            autoCapitalize="none"
            autoCorrect={false}
            keyboardType="url"
            style={[styles.input, { backgroundColor: colors.surfaceContainerHigh, color: colors.onSurface }]}
          />
        </Field>

        <Field label="Port" colors={colors}>
          <TextInput
            value={port}
            onChangeText={setPort}
            placeholder="8080"
            placeholderTextColor={colors.onSurfaceVariant}
            keyboardType="number-pad"
            style={[styles.input, { backgroundColor: colors.surfaceContainerHigh, color: colors.onSurface }]}
          />
        </Field>

        <Field label="Password" hint="The server's password" colors={colors}>
          <TextInput
            value={token}
            onChangeText={setToken}
            placeholder="shared relay password"
            placeholderTextColor={colors.onSurfaceVariant}
            autoCapitalize="none"
            autoCorrect={false}
            secureTextEntry
            style={[styles.input, { backgroundColor: colors.surfaceContainerHigh, color: colors.onSurface }]}
          />
        </Field>

        <Pressable
          onPress={() => onSecureChange(!secure)}
          style={({ pressed }) => [
            styles.switchRow,
            { backgroundColor: colors.surfaceContainerHigh, opacity: pressed ? 0.9 : 1 },
          ]}
        >
          <View style={styles.switchText}>
            <Text style={[styles.switchLabel, { color: colors.onSurface }]}>Use TLS (wss://)</Text>
            <Text style={[styles.hint, { color: colors.onSurfaceVariant }]}>
              Encrypts the connection. Required over the internet; turn off only on a trusted LAN.
            </Text>
          </View>
          <Host style={styles.switchHost} seedColor={SEED} colorScheme={scheme}>
            <Switch value={secure} onCheckedChange={onSecureChange} />
          </Host>
        </Pressable>

        <Pressable
          onPress={() => onLanChange(!lanEnabled)}
          style={({ pressed }) => [
            styles.switchRow,
            { backgroundColor: colors.surfaceContainerHigh, opacity: pressed ? 0.9 : 1 },
          ]}
        >
          <View style={styles.switchText}>
            <Text style={[styles.switchLabel, { color: colors.onSurface }]}>LAN-direct</Text>
            <Text style={[styles.hint, { color: colors.onSurfaceVariant }]}>
              Connect straight to the Mac on the same network (preferred over the relay). The Mac is
              found automatically; set a Mac IP below only if discovery is blocked.
            </Text>
          </View>
          <Host style={styles.switchHost} seedColor={SEED} colorScheme={scheme}>
            <Switch value={lanEnabled} onCheckedChange={onLanChange} />
          </Host>
        </Pressable>

        {lanEnabled ? (
          <>
            <Field label="LAN port" hint="Must match the Mac's LAN port (default 53124)" colors={colors}>
              <TextInput
                value={lanPort}
                onChangeText={setLanPort}
                placeholder="53124"
                placeholderTextColor={colors.onSurfaceVariant}
                keyboardType="number-pad"
                style={[styles.input, { backgroundColor: colors.surfaceContainerHigh, color: colors.onSurface }]}
              />
            </Field>

            <Field label="Mac IP (optional)" hint="Leave blank to auto-discover over the network" colors={colors}>
              <TextInput
                value={lanHost}
                onChangeText={setLanHost}
                placeholder="192.168.1.42"
                placeholderTextColor={colors.onSurfaceVariant}
                autoCapitalize="none"
                autoCorrect={false}
                keyboardType="numbers-and-punctuation"
                style={[styles.input, { backgroundColor: colors.surfaceContainerHigh, color: colors.onSurface }]}
              />
            </Field>
          </>
        ) : null}

        <Pressable
          onPress={onSave}
          disabled={saving}
          style={[styles.save, { backgroundColor: colors.primary, opacity: saving ? 0.6 : 1 }]}
        >
          <Text style={[styles.saveText, { color: colors.onPrimary }]}>Save</Text>
        </Pressable>
    </KeyboardAwareScrollView>
  );
}

function Field({
  label,
  hint,
  colors,
  children,
}: {
  label: string;
  hint?: string;
  colors: ReturnType<typeof useM3Colors>;
  children: React.ReactNode;
}) {
  return (
    <View style={{ gap: Spacing.two }}>
      <Text style={[styles.label, { color: colors.onSurface }]}>{label}</Text>
      {children}
      {hint ? <Text style={[styles.hint, { color: colors.onSurfaceVariant }]}>{hint}</Text> : null}
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1 },
  intro: { fontSize: 14, lineHeight: 20 },
  label: { fontSize: 15, fontWeight: "600" },
  hint: { fontSize: 13, lineHeight: 18 },
  input: {
    borderRadius: 16,
    paddingHorizontal: Spacing.three,
    paddingVertical: Spacing.three,
    fontSize: 16,
  },
  switchRow: {
    flexDirection: "row",
    alignItems: "center",
    gap: Spacing.three,
    borderRadius: 20,
    padding: Spacing.three,
  },
  switchText: { flex: 1, gap: Spacing.one },
  switchLabel: { fontSize: 15, fontWeight: "600" },
  // Fixed-size Host for the native Jetpack Compose Switch (~52x32dp). Fixed (not matchContents)
  // to avoid the @expo/ui Host NPE when a short-lived screen unmounts mid-measure.
  switchHost: { width: 56, height: 36, backgroundColor: "transparent" },
  save: {
    borderRadius: 999,
    paddingVertical: Spacing.three,
    alignItems: "center",
    marginTop: Spacing.two,
  },
  saveText: { fontSize: 16, fontWeight: "600" },
});
