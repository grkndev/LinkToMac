import { Pressable, Text } from "react-native";

import { SANS } from "@/constants/typography";

/** Text action for a native navigation header (e.g. the Clipboard screen's "Clear"). */
export function HeaderTextButton({
  label,
  color,
  onPress,
}: {
  label: string;
  color: string;
  onPress: () => void;
}) {
  return (
    <Pressable hitSlop={8} onPress={onPress}>
      <Text style={{ color, fontSize: 15, fontFamily: SANS.medium }}>{label}</Text>
    </Pressable>
  );
}
