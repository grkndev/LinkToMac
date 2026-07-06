import { useState, useImperativeHandle, forwardRef, createRef } from "react";
import {
  Host,
  AlertDialog as ComposeAlertDialog,
  TextButton,
  Text,
  Icon,
  Button,
} from "@expo/ui/jetpack-compose";
import { ImageSourcePropType } from "react-native";
import { useM3Colors } from "./m3";

interface AlertOptions {
  title: string;
  message: string;
  confirmLabel?: string;
  dismissLabel?: string;
  icon?: ImageSourcePropType;
  onConfirm?: () => void;
  onDismiss?: () => void;
}

export interface AlertRef {
  show: (options: AlertOptions) => void;
  hide: () => void;
}

// Global Referansımız
export const alertRef = createRef<AlertRef>();

// İstediğin gibi kullanabilmen için yardımcı obje
export const Alert = {
  show: (
    title: string,
    message: string,
    confirmLabel?: string,
    dismissLabel?: string,
    onConfirm?: () => void,
    onDismiss?: () => void,
    icon?: ImageSourcePropType,
  ) => {
    alertRef.current?.show({ title, message, confirmLabel, dismissLabel, onConfirm, onDismiss, icon });
  },
  hide: () => {
    alertRef.current?.hide();
  },
};

export const GlobalAlertDialog = forwardRef<AlertRef>((_, ref) => {
  const [visible, setVisible] = useState(false);
  const [options, setOptions] = useState<AlertOptions | null>(null);
  const colors = useM3Colors();

  useImperativeHandle(ref, () => ({
    show: (newOptions: AlertOptions) => {
      setOptions(newOptions);
      setVisible(true);
    },
    hide: () => {
      setVisible(false);
    },
  }));

  if (!visible || !options) return null;

  const handleConfirm = () => {
    options.onConfirm?.();
    setVisible(false);
  };

  const handleDismiss = () => {
    options.onDismiss?.();
    setVisible(false);
  };

  return (
    <Host matchContents>
      <ComposeAlertDialog onDismissRequest={handleDismiss}>
        {options.icon && (
          <ComposeAlertDialog.Icon>
            <Icon source={options.icon} />
          </ComposeAlertDialog.Icon>
        )}
        <ComposeAlertDialog.Title>
          <Text style={{ typography: "titleMedium" }}>{options.title}</Text>
        </ComposeAlertDialog.Title>
        <ComposeAlertDialog.Text>
          <Text style={{ typography: "bodyMedium" }}>{options.message}</Text>
        </ComposeAlertDialog.Text>
        {(options.onConfirm || options.confirmLabel) && (
          <ComposeAlertDialog.ConfirmButton>
            <Button
              onClick={handleConfirm}
              colors={{
                containerColor: colors.primary,
                contentColor: colors.onPrimary,
              }}
            >
              <Text style={{ typography: "labelLarge" }}>{options.confirmLabel || "OK"}</Text>
            </Button>
          </ComposeAlertDialog.ConfirmButton>
        )}
        {(options.onDismiss || options.dismissLabel) && (
          <ComposeAlertDialog.DismissButton>
            <TextButton
              onClick={handleDismiss}
              colors={{
                contentColor: colors.secondary,
              }}
            >
              <Text style={{ typography: "labelLarge" }}>{options.dismissLabel || "Cancel"}</Text>
            </TextButton>
          </ComposeAlertDialog.DismissButton>
        )}
      </ComposeAlertDialog>
    </Host>
  );
});
