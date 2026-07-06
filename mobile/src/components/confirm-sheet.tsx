import { useRef } from "react";
import { Column, Host, ModalBottomSheet } from "@expo/ui/jetpack-compose";
import type { ModalBottomSheetRef } from "@expo/ui/jetpack-compose";
import { padding } from "@expo/ui/jetpack-compose/modifiers";
import * as Haptics from "expo-haptics";

import { Spacing } from "@/constants/theme";
import { useIcons } from "./icons";
import { ButtonGroup, useM3Colors } from "./m3";
import { SheetButton, SheetHeader } from "./sheet";

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
          // One dynamic snap point at content height (house sheet behavior — see update-modal).
          skipPartiallyExpanded
        >
          <Column
            horizontalAlignment="center"
            verticalArrangement={{ spacedBy: Spacing.three }}
            modifiers={[
              padding(Spacing.four, Spacing.two, Spacing.four, Spacing.five),
            ]}
          >
            <SheetHeader
              colors={colors}
              icon={icons.linkOff}
              tone="error"
              title={title}
              message={message}
            />
            <ButtonGroup>
              <SheetButton
                colors={colors}
                variant="tonal"
                label={cancelLabel}
                onClick={cancel}
                width={0.5}
              />
              <SheetButton
                colors={colors}
                variant="destructive"
                label={confirmLabel}
                onClick={confirm}
                width={1}
              />
            </ButtonGroup>
          </Column>
        </ModalBottomSheet>
      )}
    </Host>
  );
}
