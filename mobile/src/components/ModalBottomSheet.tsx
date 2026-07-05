import { useRef } from "react";
import {
  Host,
  ModalBottomSheet,
  Button,
  Column,
  Text,
} from "@expo/ui/jetpack-compose";
import type { ModalBottomSheetRef } from "@expo/ui/jetpack-compose";
import { fillMaxWidth, padding } from "@expo/ui/jetpack-compose/modifiers";
import * as Haptics from "expo-haptics";

import { Spacing } from "@/constants/theme";
import { useIcons } from "./icons";
import { ButtonGroup, IconCircle, tonal, useM3Colors } from "./m3";

/**
 * Controlled destructive-confirmation modal bottom sheet (M3): error-tonal link-off
 * badge, centered headline + consequence line, and the house connected ButtonGroup with
 * Cancel as the safe default. The parent owns visibility: every close path (cancel,
 * scrim, back) reports through `onDismiss`; a confirmed action additionally fires
 * `onConfirm` after the hide animation completes.
 */
export default function ConfirmSheet({
  visible,
  onDismiss,
  onConfirm,
  title,
  message,
  confirmLabel = "Confirm",
  cancelLabel = "Cancel",
}: {
  visible: boolean;
  onDismiss: () => void;
  onConfirm: () => void;
  title: string;
  message: string;
  confirmLabel?: string;
  cancelLabel?: string;
}) {
  const colors = useM3Colors();
  const icons = useIcons();
  const errorTone = tonal(colors, "error");
  const sheetRef = useRef<ModalBottomSheetRef>(null);

  const cancel = async () => {
    await sheetRef.current?.hide();
    onDismiss();
  };

  const confirm = async () => {
    Haptics.notificationAsync(Haptics.NotificationFeedbackType.Warning).catch(
      () => {},
    );
    await sheetRef.current?.hide();
    onDismiss();
    onConfirm();
  };

  return (
    // The sheet renders in its own window, so the Host only anchors it. Keep the Host
    // fixed-size: matchContents can NPE if the screen unmounts mid-measure.
    <Host style={{ width: 1, height: 1 }}>
      {visible && (
        <ModalBottomSheet
          ref={sheetRef}
          onDismissRequest={onDismiss}
          containerColor={colors.surfaceContainerLow}
        >
          <Column
            horizontalAlignment="center"
            verticalArrangement={{ spacedBy: Spacing.three }}
            modifiers={[
              padding(Spacing.four, Spacing.two, Spacing.four, Spacing.five),
            ]}
          >
            <IconCircle
              source={icons.linkOff}
              container={errorTone.container}
              on={errorTone.on}
              diameter={56}
              iconSize={28}
            />
            <Column
              horizontalAlignment="center"
              verticalArrangement={{ spacedBy: Spacing.two }}
            >
              <Text
                color={colors.onSurface}
                style={{
                  typography: "headlineSmall",
                  fontWeight: "bold",
                  textAlign: "center",
                }}
              >
                {title}
              </Text>
              <Text
                color={colors.onSurfaceVariant}
                style={{ typography: "bodyMedium", textAlign: "center" }}
              >
                {message}
              </Text>
            </Column>
            {/* Sized with fillMaxWidth fractions, NOT weight() — weight is ignored on
                Button inside the sheet and the pair falls apart into a stack. */}
            <ButtonGroup>
              <Button
                onClick={cancel}
                colors={{
                  containerColor: colors.secondaryContainer,
                  contentColor: colors.onSecondaryContainer,
                }}
                contentPadding={{ top: 14, bottom: 14 }}
                modifiers={[fillMaxWidth(0.5)]}
              >
                <Text style={{ fontWeight: "600" }}>{cancelLabel}</Text>
              </Button>
              <Button
                onClick={confirm}
                colors={{
                  containerColor: colors.error,
                  contentColor: colors.onError,
                }}
                contentPadding={{ top: 14, bottom: 14 }}
                modifiers={[fillMaxWidth(1)]}
              >
                <Text style={{ fontWeight: "600" }}>{confirmLabel}</Text>
              </Button>
            </ButtonGroup>
          </Column>
        </ModalBottomSheet>
      )}
    </Host>
  );
}
