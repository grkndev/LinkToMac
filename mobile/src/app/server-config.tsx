import { useRouter } from "expo-router";
import { useState } from "react";
import {
  Alert,
  KeyboardAvoidingView,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Switch,
  Text,
  TextInput,
  View,
} from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";

import { useM3Colors } from "@/components/m3";
import { Spacing } from "@/constants/theme";
import { usePairing } from "@/features/relay/pairing-context";
import { blankServerConfig } from "@/features/relay/server-config";

/**
 * Manual relay server configuration: host / port / password / TLS. Seeds from the saved
 * ServerConfig (which a v2 QR scan can fill in for you) or the defaults, and re-pushes the
 * native relay connection on save. Plain RN form (not an @expo/ui Host) so it can host
 * controlled TextInputs. This screen is also the entry point the future LAN-direct mode reuses
 * (type a local IP, toggle TLS off, or pin a self-signed cert).
 */
export default function ServerConfigScreen() {
  const router = useRouter();
  const colors = useM3Colors();
  const insets = useSafeAreaInsets();
  const { server, setServer } = usePairing();

  const initial = server ?? blankServerConfig();
  const [host, setHost] = useState(initial.host);
  const [port, setPort] = useState(String(initial.port));
  const [token, setToken] = useState(initial.token);
  const [secure, setSecure] = useState(initial.secure);
  const [saving, setSaving] = useState(false);

  const onSave = async () => {
    const trimmedHost = host.trim();
    const portNum = Number(port.trim());
    if (!trimmedHost) {
      Alert.alert("Invalid server", "Enter the relay server address (IP or domain).");
      return;
    }
    if (!Number.isInteger(portNum) || portNum < 1 || portNum > 65535) {
      Alert.alert("Invalid port", "Enter a port between 1 and 65535.");
      return;
    }
    setSaving(true);
    try {
      await setServer({
        host: trimmedHost,
        port: portNum,
        secure,
        token: token.trim(),
        // Preserve a pinned cert (e.g. from a v2 QR) across manual edits.
        ...(server?.certFingerprint ? { certFingerprint: server.certFingerprint } : {}),
      });
      router.back();
    } finally {
      setSaving(false);
    }
  };

  return (
    <KeyboardAvoidingView
      style={[styles.root, { backgroundColor: colors.background }]}
      behavior={Platform.OS === "ios" ? "padding" : undefined}
    >
      <ScrollView
        contentContainerStyle={{ padding: Spacing.four, paddingBottom: insets.bottom + Spacing.five, gap: Spacing.four }}
        keyboardShouldPersistTaps="handled"
      >
        <Text style={[styles.intro, { color: colors.onSurfaceVariant }]}>
          Point the app at your relay server. The password must match the server's
          RELAY_AUTH_TOKEN. Use TLS (wss://) for any server reachable over the internet.
        </Text>

        <Field label="Server address" hint="Domain (for TLS) or IP" colors={colors}>
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

        <Field label="Password" hint="The server's RELAY_AUTH_TOKEN" colors={colors}>
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

        <View style={[styles.switchRow, { backgroundColor: colors.surfaceContainerHigh }]}>
          <View style={styles.switchText}>
            <Text style={[styles.switchLabel, { color: colors.onSurface }]}>Use TLS (wss://)</Text>
            <Text style={[styles.hint, { color: colors.onSurfaceVariant }]}>
              Encrypts the connection. Required over the internet; turn off only on a trusted LAN.
            </Text>
          </View>
          <Switch value={secure} onValueChange={setSecure} />
        </View>

        <Pressable
          onPress={onSave}
          disabled={saving}
          style={[styles.save, { backgroundColor: colors.primary, opacity: saving ? 0.6 : 1 }]}
        >
          <Text style={[styles.saveText, { color: colors.onPrimary }]}>Save</Text>
        </Pressable>
      </ScrollView>
    </KeyboardAvoidingView>
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
  save: {
    borderRadius: 999,
    paddingVertical: Spacing.three,
    alignItems: "center",
    marginTop: Spacing.two,
  },
  saveText: { fontSize: 16, fontWeight: "600" },
});
