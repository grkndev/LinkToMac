import {
  Box,
  Column,
  Icon,
  IconButton,
  OutlinedTextField,
  Row,
  Shape,
  Switch,
  useNativeState,
} from "@expo/ui/jetpack-compose";
import { Text } from "@/components/text";
import { fillMaxSize, fillMaxWidth, imePadding, padding, verticalScroll, weight, width } from "@expo/ui/jetpack-compose/modifiers";
import { useRouter } from "expo-router";
import { useState } from "react";
import { Alert } from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";

import { PrimaryButton } from "@/components/buttons";
import { useIcons } from "@/components/icons";
import { Group, useM3Colors } from "@/components/m3";
import { M3Host } from "@/components/m3-screen";
import { GroupRow } from "@/components/rows";
import { Spacing } from "@/constants/theme";
import { SANS } from "@/constants/typography";
import { usePairing } from "@/features/pairing/pairing-context";
import { blankServerConfig } from "@/features/connection/server-config";
import { haptic } from "@/lib/haptics";

/** 12dp outlined-field corners, per the design. */
/** Typed text inside the outlined fields — same face as the rest of the UI. */
const FIELD_TEXT = { fontFamily: SANS.regular, fontSize: 16 };

const FIELD_SHAPE = Shape.RoundedCorner({
  cornerRadii: { topStart: 12, topEnd: 12, bottomStart: 12, bottomEnd: 12 },
});

/**
 * Manual relay server configuration: host / port / password / TLS + the LAN-direct params. Seeds
 * from the saved ServerConfig (which a v2 QR scan can fill in for you) or the defaults, and
 * re-pushes the native relay connection on save. Native Compose text fields: each keeps its text
 * in a native state seeded once from the saved value, and mirrors it into React state for
 * validation on Save. `imePadding()` on the root Column lifts the pinned Save button above the
 * keyboard and shrinks the scroll area.
 */
export default function ServerConfigScreen() {
  const router = useRouter();
  const colors = useM3Colors();
  const icons = useIcons();
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
  const [showToken, setShowToken] = useState(false);
  const [saving, setSaving] = useState(false);

  // Native text state, seeded once (a controlled value would fight the IME on every keystroke).
  const hostText = useNativeState(initial.host);
  const portText = useNativeState(String(initial.port));
  const tokenText = useNativeState(initial.token);
  const lanPortText = useNativeState(String(initial.lanPort ?? 53124));
  const lanHostText = useNativeState(initial.lanHost ?? "");

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
    } catch (e: any) {
      // A SecureStore/native reject used to vanish silently, leaving the screen stuck.
      Alert.alert('Save failed', e?.message ?? 'Could not save the server settings. Try again.');
    } finally {
      setSaving(false);
    }
  };

  return (
    <M3Host>
      <Column modifiers={[fillMaxSize(), imePadding()]}>
          <Column
            modifiers={[
              fillMaxWidth(),
              weight(1),
              verticalScroll(),
              padding(Spacing.three, Spacing.one, Spacing.three, Spacing.three),
            ]}
            verticalArrangement={{ spacedBy: 18 }}
          >
            <Box modifiers={[fillMaxWidth(), padding(Spacing.one, 0, Spacing.one, 0)]}>
              <Text color={colors.onSurfaceVariant} style={{ typography: "bodyMedium" }}>
                On the same Wi‑Fi your phone reaches your Mac directly over LAN. The relay is only used to
                sync when you’re away. Leave the address empty to use LAN only.
              </Text>
            </Box>

            <OutlinedTextField
              value={hostText}
              onValueChange={setHost}
              singleLine
              shape={FIELD_SHAPE}
                textStyle={FIELD_TEXT}
              modifiers={[fillMaxWidth()]}
              keyboardOptions={{ keyboardType: "uri", autoCorrectEnabled: false, capitalization: "none" }}
            >
              <OutlinedTextField.Label>
                <Text>Server address</Text>
              </OutlinedTextField.Label>
              <OutlinedTextField.Placeholder>
                <Text>relay.example.com</Text>
              </OutlinedTextField.Placeholder>
            </OutlinedTextField>

            <Row modifiers={[fillMaxWidth()]} horizontalArrangement={{ spacedBy: 10 }} verticalAlignment="top">
              <OutlinedTextField
                value={portText}
                onValueChange={setPort}
                singleLine
                shape={FIELD_SHAPE}
                textStyle={FIELD_TEXT}
                modifiers={[width(110)]}
                keyboardOptions={{ keyboardType: "number" }}
              >
                <OutlinedTextField.Label>
                  <Text>Port</Text>
                </OutlinedTextField.Label>
              </OutlinedTextField>

              <OutlinedTextField
                value={tokenText}
                onValueChange={setToken}
                singleLine
                shape={FIELD_SHAPE}
                textStyle={FIELD_TEXT}
                modifiers={[weight(1)]}
                visualTransformation={showToken ? "none" : "password"}
                keyboardOptions={{ keyboardType: "password", autoCorrectEnabled: false, capitalization: "none" }}
              >
                <OutlinedTextField.Label>
                  <Text>Password</Text>
                </OutlinedTextField.Label>
                <OutlinedTextField.TrailingIcon>
                  <IconButton onClick={() => setShowToken((v) => !v)}>
                    <Icon
                      source={showToken ? icons.visibilityOff : icons.visibility}
                      size={22}
                      tint={colors.onSurfaceVariant}
                    />
                  </IconButton>
                </OutlinedTextField.TrailingIcon>
              </OutlinedTextField>
            </Row>

            <Group>
              <GroupRow
                colors={colors}
                label="Use TLS (wss://)"
                supporting="Pinned certificate from QR is kept"
                checked={secure}
                onCheckedChange={setSecure}
                trailing={<Switch value={secure} />}
              />
              <GroupRow
                colors={colors}
                label="LAN-direct"
                supporting="Connect without the relay on the same network"
                checked={lanEnabled}
                onCheckedChange={setLanEnabled}
                trailing={<Switch value={lanEnabled} />}
              />
            </Group>

            {lanEnabled ? (
              <>
                <Row modifiers={[fillMaxWidth()]} horizontalArrangement={{ spacedBy: 10 }} verticalAlignment="top">
                  <OutlinedTextField
                    value={lanPortText}
                    onValueChange={setLanPort}
                    singleLine
                    shape={FIELD_SHAPE}
                textStyle={FIELD_TEXT}
                    modifiers={[width(110)]}
                    keyboardOptions={{ keyboardType: "number" }}
                  >
                    <OutlinedTextField.Label>
                      <Text>LAN port</Text>
                    </OutlinedTextField.Label>
                  </OutlinedTextField>

                  <OutlinedTextField
                    value={lanHostText}
                    onValueChange={setLanHost}
                    singleLine
                    shape={FIELD_SHAPE}
                textStyle={FIELD_TEXT}
                    modifiers={[weight(1)]}
                    keyboardOptions={{ keyboardType: "text", autoCorrectEnabled: false, capitalization: "none" }}
                  >
                    <OutlinedTextField.Label>
                      <Text>Mac IP (optional)</Text>
                    </OutlinedTextField.Label>
                    <OutlinedTextField.Placeholder>
                      <Text>Auto</Text>
                    </OutlinedTextField.Placeholder>
                    <OutlinedTextField.SupportingText>
                      <Text>Found via mDNS when empty</Text>
                    </OutlinedTextField.SupportingText>
                  </OutlinedTextField>
                </Row>
              </>
            ) : null}
          </Column>

          <Box modifiers={[fillMaxWidth(), padding(Spacing.three, Spacing.two, Spacing.three, insets.bottom + Spacing.three)]}>
            <PrimaryButton
              colors={colors}
              label="Save"
              busy={saving}
              onPress={() => {
                haptic();
                onSave();
              }}
            />
          </Box>
        </Column>
    </M3Host>
  );
}
